import cv2
import numpy as np
import base64
import uvicorn
import os
import socket
import torch
import math
from datetime import datetime
from dotenv import load_dotenv
from PIL import Image

from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel
from supabase import create_client, Client

# --- 1. SECURITY BYPASS FOR PYTORCH 2.6+ ---
# Required to safely load custom .pth files containing Python objects
original_load = torch.load
def safe_load(*args, **kwargs):
    kwargs['weights_only'] = False
    return original_load(*args, **kwargs)
torch.load = safe_load

# --- AI IMPORTS ---
import supervision as sv
from transformers import SegformerImageProcessor, SegformerForSemanticSegmentation
from rfdetr import RFDETRLarge
from feature_extractor import FeatureExtractor
from scipy.spatial.distance import cosine

# --- 2. CONFIGURATION ---
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY") 

# TARGET MODEL PATH
CHECKPOINT_PATH = r"C:\The Sketchbook\SEM VI\PBL\Tethered\best_saved_model\rf-detr-large-2026.pth"

CONF_THRESHOLD = 0.40
IMG_SIZE = 640
PORT = 5000

# Deduplication Thresholds
SPATIAL_RADIUS_METERS = 8
VISUAL_SIMILARITY_THRESHOLD = 0.85
HEADING_TOLERANCE_DEGREES = 45

if not SUPABASE_URL or not SUPABASE_SECRET_KEY:
    print("❌ CREDENTIALS MISSING. Check .env for SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY")
    exit(1)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"🖥️  Using Device: {DEVICE}")

app = FastAPI()
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SECRET_KEY)

# --- 3. ROBUST MODEL LOADER (With Auto-Patching) ---
print("🔄 Loading AI Models...")

# A. Segformer (Road Segmentation)
processor = SegformerImageProcessor.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024")
seg_model = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024").to(DEVICE)
seg_model.eval()

# B. RF-DETR Patcher (In case checkpoint matrix sizes are wrong)
def patch_checkpoint_for_640(checkpoint_path):
    patched_path = "patched_rfdetr_640.pth"
    if os.path.exists(patched_path):
        print(f"✅ Found previously patched checkpoint at {patched_path}")
        return patched_path

    print("🔧 Patching Checkpoint weights to match 640x640 (14x14 patches)...")
    ckpt = torch.load(checkpoint_path, map_location='cpu')
    state_dict = ckpt['model'] if 'model' in ckpt else ckpt
    
    # 1. Patch Embeddings
    key_patch = 'backbone.0.encoder.encoder.embeddings.patch_embeddings.projection.weight'
    if key_patch in state_dict:
        old_w = state_dict[key_patch]
        if old_w.shape[-1] != 14:
            print(f"   -> Resizing patch_embeddings from {old_w.shape} to[384, 3, 14, 14]")
            new_w = torch.nn.functional.interpolate(
                old_w.float(), size=(14, 14), mode='bicubic', align_corners=False
            )
            state_dict[key_patch] = new_w.to(old_w.dtype)
            
    # 2. Position Embeddings
    key_pos = 'backbone.0.encoder.encoder.embeddings.position_embeddings'
    if key_pos in state_dict:
        old_pos = state_dict[key_pos]
        if old_pos.shape[1] != 1937:
            print(f"   -> Resizing position_embeddings from {old_pos.shape} to [1, 1937, 384]")
            num_patches_old = old_pos.shape[1] - 1
            grid_old = int(math.sqrt(num_patches_old))
            grid_tgt = 44 # 1936 patches
            
            cls_tok = old_pos[:, 0:1, :]
            pos_tok = old_pos[:, 1:, :]
            pos_tok = pos_tok.reshape(1, grid_old, grid_old, -1).permute(0, 3, 1, 2)
            pos_tok = torch.nn.functional.interpolate(
                pos_tok.float(), size=(grid_tgt, grid_tgt), mode='bicubic', align_corners=False
            )
            pos_tok = pos_tok.permute(0, 2, 3, 1).reshape(1, 1936, -1)
            state_dict[key_pos] = torch.cat((cls_tok, pos_tok), dim=1).to(old_pos.dtype)
            
    if 'model' in ckpt: ckpt['model'] = state_dict
    else: ckpt = state_dict
        
    torch.save(ckpt, patched_path)
    print(f"✅ Saved patched checkpoint to {patched_path}")
    return patched_path

# Load RF-DETR directly, use patcher if it crashes
try:
    print(f"🔄 Attempting direct load of {os.path.basename(CHECKPOINT_PATH)}...")
    det_model = RFDETRLarge(num_classes=1, pretrain_weights=CHECKPOINT_PATH, resolution=IMG_SIZE)
except Exception as e:
    print(f"⚠️ Direct load failed. Running mathematical patcher...")
    patched_path = patch_checkpoint_for_640(CHECKPOINT_PATH)
    det_model = RFDETRLarge(num_classes=1, pretrain_weights=patched_path, resolution=IMG_SIZE)
    
det_model.optimize_for_inference()
print("✅ RF-DETR Model Loaded Successfully!")

# C. ResNet50 (Visual Deduplication)
resnet_extractor = FeatureExtractor()

print("✅ All AI Engines Operational.")

# --- 4. DATA MODEL ---
class DetectionRequest(BaseModel):
    image: str       
    gps: dict        
    instance_ip: str 
    roughness: float 
    user_id: str      
    user_email: str   
    debug_mode: bool = False

# --- 5. AI LOGIC HELPERS ---
def get_road_mask(image: Image.Image):
    inputs = processor(images=image, return_tensors="pt").to(DEVICE)
    with torch.no_grad():
        outputs = seg_model(**inputs)
    logits = torch.nn.functional.interpolate(outputs.logits, size=image.size[::-1], mode="bilinear", align_corners=False)
    mask = logits.argmax(dim=1).squeeze().cpu().numpy()
    road_mask = (mask == 0).astype(np.uint8)
    return cv2.dilate(road_mask, np.ones((15, 15), np.uint8), iterations=1)

def filter_by_road(detections, road_mask):
    if len(detections) == 0: return detections
    keep =[]
    for box in detections.xyxy:
        x1, y1, x2, y2 = map(int, box)
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(road_mask.shape[1], x2), min(road_mask.shape[0], y2)
        crop = road_mask[y1:y2, x1:x2]
        ratio = np.sum(crop) / ((x2-x1)*(y2-y1)) if (x2-x1)*(y2-y1) > 0 else 0
        keep.append(ratio >= 0.3)
    return detections[np.array(keep)]

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except: return "127.0.0.1"

# --- 6. API ENDPOINT ---
@app.post("/detect")
async def process_request(data: DetectionRequest, background_tasks: BackgroundTasks):
    try:
        # A. Telemetry
        telemetry = {
            "latitude": data.gps['lat'], "longitude": data.gps['lon'],
            "roughness": data.roughness, "session_id": data.instance_ip,
            "user_id": data.user_id, "user_email": data.user_email
        }
        background_tasks.add_task(supabase.table("road_logs").insert(telemetry).execute)

        # B. Decoding
        img_bytes = base64.b64decode(data.image)
        cv_img = cv2.imdecode(np.frombuffer(img_bytes, np.uint8), cv2.IMREAD_COLOR)
        if cv_img is None: return {"status": "error", "msg": "Invalid Image"}

        # === FIX: TYPO FIXED HERE (pil_image) ===
        pil_image = Image.fromarray(cv2.cvtColor(cv_img, cv2.COLOR_BGR2RGB))
        area = cv_img.shape[0] * cv_img.shape[1]

        # C. Inference
        road_mask = get_road_mask(pil_image)
        raw_hits = det_model.predict(pil_image, threshold=CONF_THRESHOLD)
        hits = filter_by_road(raw_hits, road_mask)

        # Build Annotated Scene (Used for Debug Mode & Cloud Storage)
        scene = cv_img.copy()
        
        # If Debug mode is ON or we found a pothole, draw the road mask
        if data.debug_mode or len(hits) > 0:
            rm_color = np.zeros_like(cv_img)
            rm_color[road_mask == 1] = [0, 255, 0]
            scene = cv2.addWeighted(scene, 1.0, rm_color, 0.15, 0)

        # Clear Road Scenario
        if len(hits) == 0: 
            resp = {"status": "clear"}
            if data.debug_mode:
                # Return the road mask view to the app
                _, buf = cv2.imencode('.jpg', scene, [int(cv2.IMWRITE_JPEG_QUALITY), 60])
                resp["debug_image"] = base64.b64encode(buf.tobytes()).decode('utf-8')
            return resp

        # D. Processing Hits
        new_detections =[]
        for box, conf in zip(hits.xyxy, hits.confidence):
            x1, y1, x2, y2 = map(int, box)
            x1, y1, x2, y2 = max(0,x1), max(0,y1), min(cv_img.shape[1],x2), min(cv_img.shape[0],y2)
            
            crop = cv_img[y1:y2, x1:x2]
            if crop.size == 0: continue

            # Severity Logic
            gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
            edges = cv2.Canny(gray, 50, 150)
            score = (0.6 * ((x2-x1)*(y2-y1)/area)) + (0.4 * (np.sum(edges>0)/edges.size))
            
            if score < 0.3: label, col = "Minor", (0, 255, 0)
            elif score < 0.6: label, col = "Moderate", (0, 255, 255)
            else: label, col = "Severe", (0, 0, 255)

            # FX Overlay
            overlay = scene.copy()
            cv2.rectangle(overlay, (x1,y1), (x2,y2), col, -1)
            scene = cv2.addWeighted(overlay, 0.35, scene, 0.65, 0)
            scene[y1:y2, x1:x2][edges > 0] =[255, 255, 255] 
            
            txt = f"{label} ({conf:.2f})"
            cv2.rectangle(scene, (x1, y1-25), (x2, y1), col, -1)
            cv2.putText(scene, txt, (x1+5, y1-7), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,0,0), 1)

            vector = resnet_extractor.get_embedding(crop)
            new_detections.append({"severity": label, "embedding": vector})

        # E. Upload Evidence
        _, buf = cv2.imencode('.jpg', scene,[int(cv2.IMWRITE_JPEG_QUALITY), 75])
        file_bytes = buf.tobytes()
        fname = f"ph_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.jpg"
        
        supabase.storage.from_("pothole-images").upload(fname, file_bytes, {"content-type": "image/jpeg"})
        url = supabase.storage.from_("pothole-images").get_public_url(fname)

        # F. Deduplication & DB Entry
        lat, lon, head = data.gps['lat'], data.gps['lon'], data.gps.get('heading', 0.0)
        candidates = supabase.rpc("find_candidates", {"search_lat": lat, "search_lon": lon, "radius_m": SPATIAL_RADIUS_METERS}).execute().data

        for det in new_detections:
            match_id = None
            if candidates:
                for cand in candidates:
                    a_diff = abs(cand['heading'] - head)
                    if a_diff > 180: a_diff = 360 - a_diff
                    if a_diff > HEADING_TOLERANCE_DEGREES: continue
                    
                    sim = 1 - cosine(det["embedding"], np.array(eval(cand['embedding'])))
                    if sim > VISUAL_SIMILARITY_THRESHOLD:
                        match_id = cand['id']
                        break
            
            if match_id:
                supabase.table("detections").update({"report_count": cand['report_count']+1, "last_seen": datetime.now().isoformat(), "image_url": url}).eq("id", match_id).execute()
            else:
                supabase.table("detections").insert({
                    "latitude": lat, "longitude": lon, "heading": head, "image_url": url, 
                    "severity": det["severity"], "user_id": data.user_id, "user_email": data.user_email,
                    "embedding": str(det["embedding"]), "report_count": 1, "last_seen": datetime.now().isoformat()
                }).execute()

        print(f"🚨 Pothole Logged (User: {data.user_email})")
        
        resp = {"status": "detected", "url": url}
        if data.debug_mode:
            # Also return the image in the response if debug is on
            resp["debug_image"] = base64.b64encode(file_bytes).decode('utf-8')
            
        return resp

    except Exception as e:
        print(f"❌ Server Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    local_ip = get_local_ip()
    print("\n" + "="*60)
    print(f"🚀 ROAD SENSE PRO AI NODE | http://{local_ip}:{PORT}")
    print(f"📂 Model: {os.path.basename(CHECKPOINT_PATH)}")
    print("="*60 + "\n")
    uvicorn.run(app, host="0.0.0.0", port=PORT)
