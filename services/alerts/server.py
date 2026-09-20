import os
import cv2
import socket
import base64
import numpy as np
import torch
import math
import smtplib
from email.message import EmailMessage
from datetime import datetime
from dotenv import load_dotenv
from PIL import Image

import uvicorn
from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel
from supabase import create_client, Client
from scipy.spatial.distance import cosine

# =====================================================================
# --- 1. PYTORCH INTERCEPTOR (Prevents Version Crashes) ---
# =====================================================================
original_load = torch.load
def safe_load(*args, **kwargs):
    kwargs['weights_only'] = False
    return original_load(*args, **kwargs)
torch.load = safe_load

original_load_state_dict = torch.nn.Module.load_state_dict
def dynamic_resize_load_state_dict(self, state_dict, strict=True, assign=False):
    my_state = self.state_dict()
    for k, v in list(state_dict.items()):
        if k in my_state:
            target_shape = my_state[k].shape
            if v.shape != target_shape:
                if 'position_embeddings' in k and len(v.shape) == 3 and len(target_shape) == 3:
                    cls_tok, pos_tok = v[:, 0:1, :], v[:, 1:, :]
                    grid_old = int(math.sqrt(pos_tok.shape[1]))
                    grid_new = int(math.sqrt(target_shape[1] - 1))
                    if grid_old**2 == pos_tok.shape[1] and grid_new**2 == (target_shape[1]-1):
                        pos_tok_2d = pos_tok.reshape(1, grid_old, grid_old, -1).permute(0, 3, 1, 2)
                        new_pos_tok_2d = torch.nn.functional.interpolate(pos_tok_2d.float(), size=(grid_new, grid_new), mode='bicubic', align_corners=False)
                        state_dict[k] = torch.cat((cls_tok, new_pos_tok_2d.permute(0, 2, 3, 1).reshape(1, target_shape[1]-1, -1).to(v.dtype)), dim=1)
                        continue
                if len(v.shape) == 4 and len(target_shape) == 4 and v.shape[:2] == target_shape[:2]:
                    state_dict[k] = torch.nn.functional.interpolate(v.float(), size=target_shape[2:], mode='bicubic', align_corners=False).to(v.dtype)
                    continue
                del state_dict[k]
    return original_load_state_dict(self, state_dict, strict=False, assign=assign)

torch.nn.Module.load_state_dict = dynamic_resize_load_state_dict

# --- AI IMPORTS ---
import supervision as sv
from transformers import SegformerImageProcessor, SegformerForSemanticSegmentation
from rfdetr import RFDETRLarge
from feature_extractor import FeatureExtractor

# =====================================================================
# --- 2. CONFIGURATION ---
# =====================================================================
load_dotenv()

# Feature Toggles
ENABLE_EMAIL_SERVICE = False  # <--- SET TO TRUE TO ENABLE PMC EMAILS

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY") 

# Email Configuration
SMTP_HOST = os.getenv("SMTP_HOST")
SMTP_PORT = int(os.getenv("SMTP_PORT", 587))
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASS = os.getenv("SMTP_PASS")
PMC_EMAIL = os.getenv("PMC_EMAIL")

CHECKPOINT_PATH = r"C:\The Sketchbook\SEM VI\PBL\Tethered\best_saved_model\checkpoint_best_ema.pth"

CONF_THRESHOLD = 0.4
IMG_SIZE = 640
PORT = 5000

# Deduplication Thresholds
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

# =====================================================================
# --- 3. LOAD MODELS ---
# =====================================================================
print("🔄 Loading AI Models...")

processor = SegformerImageProcessor.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024")
seg_model = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024").to(DEVICE)
seg_model.eval()

det_model = RFDETRLarge(num_classes=1, pretrain_weights=CHECKPOINT_PATH, resolution=IMG_SIZE)
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

# =====================================================================
# --- 4. EMAIL & ANTI-SPAM LOGIC ---
# =====================================================================
def handle_pothole_email(detection_id, lat, lon, image_url, severity, user_email):
    if not ENABLE_EMAIL_SERVICE:
        return
    if not all([SMTP_HOST, SMTP_USER, SMTP_PASS, PMC_EMAIL]):
        print("⚠️ Email aborted: Missing SMTP credentials.")
        return

    # 1. Anti-Spam Check: Did we email about this area in the last 48 hrs?
    try:
        recent_complaints = supabase.rpc("check_recent_complaint", {
            "lat": lat, "lng": lon
        }).execute().data

        if recent_complaints and len(recent_complaints) > 0:
            print(f"🛑 Email Suppressed: A complaint for location ({lat:.4f}, {lon:.4f}) was already sent recently.")
            return
    except Exception as e:
        print(f"⚠️ Failed to check recent complaints: {e}")
        return

    # 2. Prepare & Send Email
    description = f"A {severity.lower()} severity pothole has been detected by the autonomous Road Sense Pro AI system, verified by citizen {user_email}."
    
    msg = EmailMessage()
    msg["From"] = SMTP_USER
    msg["To"] = PMC_EMAIL
    msg["Subject"] = f"🚨 Urgent: {severity} Pothole Detected in Pune"
    msg.set_content(f"""Respected Sir/Madam,

An automated pothole complaint has been registered on the Road Sense Pro network.

📝 Description:
{description}

📍 Location (Google Maps):
https://maps.google.com/?q={lat},{lon}

⚠ Severity Level:
{severity.upper()}

🖼 Image Evidence:
{image_url if image_url else "None attached"}

This report was autonomously generated and verified by AI. Requesting prompt remediation to ensure road safety.

Regards,
Road Eye Automated System
""")

    email_sent = False
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.send_message(msg)
        print(f"✅ EMAIL SENT TO PMC for Detection ID: {detection_id}")
        email_sent = True
    except Exception as e:
        print(f"⚠️ Email Sending Failed: {e}")

    # 3. Log the action to database (Starts the 48-hour cooldown)
    if email_sent:
        try:
            supabase.table("pothole_complaints").insert({
                "detection_id": detection_id,
                "latitude": lat,
                "longitude": lon,
                "severity": severity,
                "image_url": image_url,
                "source": "ai",
                "message": description,
                "emailed": True,
                "emailed_at": datetime.now().isoformat()
            }).execute()
        except Exception as e:
            print(f"⚠️ Failed to log complaint in DB: {e}")

# =====================================================================
# --- 5. AI HELPERS ---
# =====================================================================
def get_road_mask(image: Image.Image):
    inputs = processor(images=image, return_tensors="pt").to(DEVICE)
    with torch.no_grad(): outputs = seg_model(**inputs)
    logits = torch.nn.functional.interpolate(outputs.logits, size=image.size[::-1], mode="bilinear", align_corners=False)
    road_mask = (logits.argmax(dim=1).squeeze().cpu().numpy() == 0).astype(np.uint8)
    return cv2.dilate(road_mask, np.ones((15, 15), np.uint8), iterations=1)

def filter_detections_by_road(detections, road_mask, threshold=0.4):
    if len(detections) == 0: return detections
    keep =[]
    for box in detections.xyxy:
        x1, y1, x2, y2 = map(int, box)
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(road_mask.shape[1], x2), min(road_mask.shape[0], y2)
        box_area = (x2 - x1) * (y2 - y1)
        if box_area == 0:
            keep.append(False); continue
        keep.append((np.sum(road_mask[y1:y2, x1:x2]) / box_area) >= threshold)
    return detections[np.array(keep)]

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('10.255.255.255', 1)); ip = s.getsockname()[0]; s.close(); return ip
    except: return "127.0.0.1"

# =====================================================================
# --- 6. API ENDPOINT ---
# =====================================================================
@app.post("/detect")
async def process_request(data: DetectionRequest, background_tasks: BackgroundTasks):
    try:
        # A. Telemetry
        telemetry = {"latitude": data.gps['lat'], "longitude": data.gps['lon'], "roughness": data.roughness, "session_id": data.instance_ip, "user_id": data.user_id, "user_email": data.user_email}
        background_tasks.add_task(supabase.table("road_logs").insert(telemetry).execute)

        # B. Decoding
        img_bytes = base64.b64decode(data.image)
        cv_img = cv2.imdecode(np.frombuffer(img_bytes, np.uint8), cv2.IMREAD_COLOR)
        if cv_img is None: return {"status": "error", "msg": "Invalid Image"}

        pil_image = Image.fromarray(cv2.cvtColor(cv_img, cv2.COLOR_BGR2RGB))
        image_area = cv_img.shape[0] * cv_img.shape[1]

        # C. Inference
        road_mask = get_road_mask(pil_image)
        raw_detections = det_model.predict(pil_image.resize((IMG_SIZE, IMG_SIZE)), threshold=CONF_THRESHOLD)
        
        if len(raw_detections) > 0:
            raw_detections.xyxy[:, [0, 2]] *= (cv_img.shape[1] / IMG_SIZE)
            raw_detections.xyxy[:, [1, 3]] *= (cv_img.shape[0] / IMG_SIZE)
            
        hits = filter_detections_by_road(raw_detections, road_mask, threshold=0.3)

        if len(hits) == 0: return {"status": "clear"}

        # D. Annotation & Severity
        scene = cv_img.copy()
        new_dets =[]
        for box, conf in zip(hits.xyxy, hits.confidence):
            x1, y1, x2, y2 = map(int, box)
            x1, y1, x2, y2 = max(0,x1), max(0,y1), min(cv_img.shape[1],x2), min(cv_img.shape[0],y2)
            crop = cv_img[y1:y2, x1:x2]
            if crop.size == 0: continue
            
            gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
            edges = cv2.Canny(gray, 50, 150)
            score = (0.6 * ((x2-x1)*(y2-y1)/image_area)) + (0.4 * (np.sum(edges>0)/edges.size))
            
            if score < 0.3: lab, col = "Minor", (0, 255, 0)
            elif score < 0.6: lab, col = "Moderate", (0, 255, 255)
            else: lab, col = "Severe", (0, 0, 255)
            
            overlay = scene.copy()
            cv2.rectangle(overlay, (x1, y1), (x2, y2), col, -1)
            scene = cv2.addWeighted(overlay, 0.35, scene, 0.65, 0)
            scene[y1:y2, x1:x2][edges > 0] =[255, 255, 255]
            cv2.rectangle(scene, (x1, y1-25), (x2, y1), col, -1)
            cv2.putText(scene, f"{lab} ({conf:.2f})", (x1+5, y1-7), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,0,0), 1)
            
            new_dets.append({"severity": lab, "embedding": resnet_extractor.get_embedding(crop)})

        # E. Upload Evidence
        _, b = cv2.imencode('.jpg', scene,[int(cv2.IMWRITE_JPEG_QUALITY), 75])
        fname = f"ph_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.jpg"
        supabase.storage.from_("pothole-images").upload(fname, b.tobytes(), {"content-type": "image/jpeg"})
        url = supabase.storage.from_("pothole-images").get_public_url(fname)

        # F. Deduplication & DB Entry
        lat, lon, head = data.gps['lat'], data.gps['lon'], data.gps.get('heading', 0.0)
        candidates = supabase.rpc("find_candidates", {"search_lat": lat, "search_lon": lon, "radius_m": SPATIAL_RADIUS_METERS}).execute().data

        for det in new_dets:
            match_id = None
            if candidates:
                for cand in candidates:
                    a_diff = abs(cand['heading'] - head)
                    if a_diff > 180: a_diff = 360 - a_diff
                    if a_diff > HEADING_TOLERANCE_DEGREES: continue
                    sim = 1 - cosine(det["embedding"], np.array(eval(cand['embedding'])))
                    if sim > VISUAL_SIMILARITY_THRESHOLD: match_id = cand['id']; break
            
            if match_id:
                # Merge Duplicate
                supabase.table("detections").update({"report_count": cand['report_count'] + 1, "last_seen": datetime.now().isoformat(), "image_url": url}).eq("id", match_id).execute()
            else:
                # Insert New
                result = supabase.table("detections").insert({
                    "latitude": lat, "longitude": lon, "heading": head, "image_url": url, 
                    "severity": det["severity"], "user_id": data.user_id, "user_email": data.user_email, 
                    "embedding": str(det["embedding"]), "report_count": 1, "last_seen": datetime.now().isoformat()
                }).execute()
                
                # Fetch ID of newly inserted detection
                new_det_id = result.data[0]['id']

                # TRIGGER EMAIL IN BACKGROUND (Only for NEW potholes)
                if ENABLE_EMAIL_SERVICE:
                    background_tasks.add_task(handle_pothole_email, new_det_id, lat, lon, url, det["severity"], data.user_email)

        print(f"🚨 Pothole Logged (User: {data.user_email})")
        return {"status": "detected", "url": url}

    except Exception as e:
        print(f"❌ Server Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    local_ip = get_local_ip()
    print("\n" + "="*60)
    print(f"🚀 ROAD SENSE PRO AI NODE | http://{local_ip}:{PORT}")
    print(f"📧 PMC Email Reporting    | {'🟢 ENABLED' if ENABLE_EMAIL_SERVICE else '🔴 DISABLED'}")
    print("="*60 + "\n")
    uvicorn.run(app, host="0.0.0.0", port=PORT)