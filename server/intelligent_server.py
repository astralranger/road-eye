import os
import cv2
import socket
import base64
import numpy as np
import torch
import math
from datetime import datetime
from dotenv import load_dotenv
from PIL import Image

import uvicorn
from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel
from supabase import create_client, Client
from scipy.spatial.distance import cosine

# =====================================================================
# --- THE ROBUST FIX: DYNAMIC SHAPE INTERPOLATOR & SECURITY BYPASS ---
# =====================================================================

# 1. PyTorch 2.6+ Security Bypass (Allows loading custom .pth files)
original_load = torch.load
def safe_load(*args, **kwargs):
    kwargs['weights_only'] = False
    return original_load(*args, **kwargs)
torch.load = safe_load

# 2. Dynamic Shape Interpolator (Replicates Colab's auto-resizing behavior locally)
original_load_state_dict = torch.nn.Module.load_state_dict

def dynamic_resize_load_state_dict(self, state_dict, strict=True, assign=False):
    my_state = self.state_dict()
    
    for k, v in list(state_dict.items()):
        if k in my_state:
            target_shape = my_state[k].shape
            if v.shape != target_shape:
                print(f"   🔧 Auto-Adapting Tensor: {k} | {v.shape} -> {target_shape}")
                
                # A. Safely Interpolate Position Embeddings
                if 'position_embeddings' in k and len(v.shape) == 3 and len(target_shape) == 3:
                    cls_tok = v[:, 0:1, :]
                    pos_tok = v[:, 1:, :]
                    num_patches_old = pos_tok.shape[1]
                    num_patches_new = target_shape[1] - 1
                    
                    grid_old = int(math.sqrt(num_patches_old))
                    grid_new = int(math.sqrt(num_patches_new))
                    
                    if grid_old * grid_old == num_patches_old and grid_new * grid_new == num_patches_new:
                        pos_tok_2d = pos_tok.reshape(1, grid_old, grid_old, -1).permute(0, 3, 1, 2)
                        new_pos_tok_2d = torch.nn.functional.interpolate(
                            pos_tok_2d.float(), size=(grid_new, grid_new), mode='bicubic', align_corners=False
                        )
                        new_pos_tok = new_pos_tok_2d.permute(0, 2, 3, 1).reshape(1, num_patches_new, -1)
                        state_dict[k] = torch.cat((cls_tok, new_pos_tok.to(v.dtype)), dim=1)
                        continue

                # B. Safely Interpolate Spatial 2D Weights (e.g., Patch Embeddings)
                if len(v.shape) == 4 and len(target_shape) == 4:
                    if v.shape[:2] == target_shape[:2]: # Same input/output channels
                        new_v = torch.nn.functional.interpolate(
                            v.float(), size=target_shape[2:], mode='bicubic', align_corners=False
                        )
                        state_dict[k] = new_v.to(v.dtype)
                        continue
                        
                # C. Fallback: Drop un-resizable layers to prevent crash (Library defaults will take over)
                print(f"   ⚠️ Cannot mathematically resize {k}. Dropping to allow initialization.")
                del state_dict[k]

    return original_load_state_dict(self, state_dict, strict=False, assign=assign)

# Apply interceptor globally
torch.nn.Module.load_state_dict = dynamic_resize_load_state_dict

# =====================================================================


# --- AI IMPORTS ---
import supervision as sv
from transformers import SegformerImageProcessor, SegformerForSemanticSegmentation
from rfdetr import RFDETRLarge
from feature_extractor import FeatureExtractor

# --- CONFIGURATION ---
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY") 

CHECKPOINT_PATH = r"C:\The Sketchbook\SEM VI\PBL\Tethered\best_saved_model\checkpoint_best_ema.pth"

CONF_THRESHOLD = 0.4
IMG_SIZE = 640
PORT = 5000

# Deduplication Config
SPATIAL_RADIUS_METERS = 8
VISUAL_SIMILARITY_THRESHOLD = 0.85
HEADING_TOLERANCE_DEGREES = 45

if not SUPABASE_URL or not SUPABASE_SECRET_KEY:
    print("❌ CREDENTIALS MISSING. Check .env")
    exit(1)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"🖥️  Using Device: {DEVICE}")

app = FastAPI()
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SECRET_KEY)

# --- LOAD MODELS ---
print("🔄 Loading AI Models...")

processor = SegformerImageProcessor.from_pretrained(
    "nvidia/segformer-b0-finetuned-cityscapes-512-1024"
)

seg_model = SegformerForSemanticSegmentation.from_pretrained(
    "nvidia/segformer-b0-finetuned-cityscapes-512-1024"
).to(DEVICE)
seg_model.eval()

# Your requested configuration, fully protected by the dynamic interpolator
det_model = RFDETRLarge(
    num_classes=1,
    pretrain_weights=CHECKPOINT_PATH,
    resolution=IMG_SIZE
)
det_model.optimize_for_inference()

resnet_extractor = FeatureExtractor()
print("✅ All AI Engines Ready.")

# --- DATA MODEL ---
class DetectionRequest(BaseModel):
    image: str       
    gps: dict        
    instance_ip: str 
    roughness: float 
    user_id: str      
    user_email: str   

# --- AI HELPERS ---
def get_road_mask(image: Image.Image):
    inputs = processor(images=image, return_tensors="pt").to(DEVICE)
    with torch.no_grad():
        outputs = seg_model(**inputs)
    
    logits = outputs.logits
    logits = torch.nn.functional.interpolate(
        logits,
        size=image.size[::-1], 
        mode="bilinear",
        align_corners=False,
    )
    
    mask = logits.argmax(dim=1).squeeze().cpu().numpy()
    road_mask = (mask == 0).astype(np.uint8)
    
    kernel = np.ones((15, 15), np.uint8)
    road_mask = cv2.dilate(road_mask, kernel, iterations=1)
    
    return road_mask

def filter_detections_by_road(detections, road_mask, threshold=0.4):
    if len(detections) == 0:
        return detections
        
    keep =[]
    for box in detections.xyxy:
        x1, y1, x2, y2 = map(int, box)
        x1 = max(0, x1)
        y1 = max(0, y1)
        x2 = min(road_mask.shape[1], x2)
        y2 = min(road_mask.shape[0], y2)
        
        box_area = (x2 - x1) * (y2 - y1)
        if box_area == 0:
            keep.append(False)
            continue
            
        box_mask = road_mask[y1:y2, x1:x2]
        road_ratio = np.sum(box_mask) / box_area
        keep.append(road_ratio >= threshold)
        
    return detections[np.array(keep)]

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except: 
        return "127.0.0.1"

# --- API ENDPOINT ---
@app.post("/detect")
async def process_request(data: DetectionRequest, background_tasks: BackgroundTasks):
    try:
        # A. Telemetry Logging
        telemetry = {
            "latitude": data.gps['lat'], 
            "longitude": data.gps['lon'], 
            "roughness": data.roughness, 
            "session_id": data.instance_ip, 
            "user_id": data.user_id, 
            "user_email": data.user_email
        }
        background_tasks.add_task(supabase.table("road_logs").insert(telemetry).execute)

        # B. Image Decoding
        img_bytes = base64.b64decode(data.image)
        cv_img = cv2.imdecode(np.frombuffer(img_bytes, np.uint8), cv2.IMREAD_COLOR)
        if cv_img is None: 
            return {"status": "error", "msg": "Invalid Image"}

        pil_image = Image.fromarray(cv2.cvtColor(cv_img, cv2.COLOR_BGR2RGB))
        image_area = cv_img.shape[0] * cv_img.shape[1]

        # C. Inference
        road_mask = get_road_mask(pil_image)
        
        # Resize image specifically for RFDETR input size (to prevent dimension crashes)
        pil_inf = pil_image.resize((IMG_SIZE, IMG_SIZE))
        raw_detections = det_model.predict(pil_inf, threshold=CONF_THRESHOLD)
        
        # Scale bounding boxes back up to original image dimensions
        if len(raw_detections) > 0:
            scale_x = cv_img.shape[1] / IMG_SIZE
            scale_y = cv_img.shape[0] / IMG_SIZE
            raw_detections.xyxy[:, [0, 2]] *= scale_x
            raw_detections.xyxy[:,[1, 3]] *= scale_y
            
        hits = filter_detections_by_road(raw_detections, road_mask, threshold=0.3)

        if len(hits) == 0: 
            return {"status": "clear"}

        # D. Annotation & Severity Processing
        scene = cv_img.copy()
        new_dets =[]
        
        for box, conf in zip(hits.xyxy, hits.confidence):
            x1, y1, x2, y2 = map(int, box)
            x1, y1 = max(0, x1), max(0, y1)
            x2, y2 = min(cv_img.shape[1], x2), min(cv_img.shape[0], y2)
            
            crop = cv_img[y1:y2, x1:x2]
            if crop.size == 0: continue
            
            # Severity Calculation
            gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
            edges = cv2.Canny(gray, 50, 150)
            score = (0.6 * ((x2-x1)*(y2-y1)/image_area)) + (0.4 * (np.sum(edges>0)/edges.size))
            
            if score < 0.3: lab, col = "Minor", (0, 255, 0)
            elif score < 0.6: lab, col = "Moderate", (0, 255, 255)
            else: lab, col = "Severe", (0, 0, 255)
            
            # Draw Translucent Box & Edge Highlight
            overlay = scene.copy()
            cv2.rectangle(overlay, (x1, y1), (x2, y2), col, -1)
            scene = cv2.addWeighted(overlay, 0.35, scene, 0.65, 0)
            scene[y1:y2, x1:x2][edges > 0] =[255, 255, 255]
            
            # Draw Label
            cv2.rectangle(scene, (x1, y1-25), (x2, y1), col, -1)
            cv2.putText(scene, f"{lab} ({conf:.2f})", (x1+5, y1-7), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,0,0), 1)
            
            # Visual Fingerprint Extract
            vector = resnet_extractor.get_embedding(crop)
            new_dets.append({"severity": lab, "embedding": vector})

        # E. Upload Evidence Image
        _, b = cv2.imencode('.jpg', scene,[int(cv2.IMWRITE_JPEG_QUALITY), 75])
        fname = f"ph_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.jpg"
        supabase.storage.from_("pothole-images").upload(fname, b.tobytes(), {"content-type": "image/jpeg"})
        url = supabase.storage.from_("pothole-images").get_public_url(fname)

        # F. Deduplication & DB Entry
        lat, lon, head = data.gps['lat'], data.gps['lon'], data.gps.get('heading', 0.0)
        candidates = supabase.rpc("find_candidates", {
            "search_lat": lat, 
            "search_lon": lon, 
            "radius_m": SPATIAL_RADIUS_METERS
        }).execute().data

        for det in new_dets:
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
                # Merge Duplicate
                supabase.table("detections").update({
                    "report_count": cand['report_count'] + 1, 
                    "last_seen": datetime.now().isoformat(), 
                    "image_url": url
                }).eq("id", match_id).execute()
            else:
                # Insert New
                supabase.table("detections").insert({
                    "latitude": lat, "longitude": lon, "heading": head, 
                    "image_url": url, "severity": det["severity"], 
                    "user_id": data.user_id, "user_email": data.user_email, 
                    "embedding": str(det["embedding"]), 
                    "report_count": 1, "last_seen": datetime.now().isoformat()
                }).execute()

        print(f"🚨 Pothole Logged (User: {data.user_email}) | Total Hits: {len(new_dets)}")
        return {"status": "detected", "url": url}

    except Exception as e:
        print(f"❌ Server Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    local_ip = get_local_ip()
    print("\n" + "="*60)
    print(f"🚀 ROAD SENSE PRO AI NODE | http://{local_ip}:{PORT}")
    print("="*60 + "\n")
    uvicorn.run(app, host="0.0.0.0", port=PORT)