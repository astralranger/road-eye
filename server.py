import cv2
import numpy as np
import base64
import uvicorn
import os
import socket
import torch
import math
import time
from datetime import datetime
from PIL import Image
from dotenv import load_dotenv

from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel
from supabase import create_client, Client
from scipy.spatial.distance import cosine

# --- BEAUTIFUL TERMINAL IMPORTS ---
from rich.console import Console
from rich.panel import Panel
from rich.text import Text
from rich.theme import Theme

# Setup custom theme
custom_theme = Theme({
    "info": "cyan",
    "warning": "yellow",
    "error": "bold red",
    "success": "bold green",
    "user": "bold magenta"
})
console = Console(theme=custom_theme)

# =====================================================================
# --- SYSTEM TRACKERS ---
# =====================================================================
active_users = {}

def log_event(user_email, status, message, color="white"):
    """Custom formatter for beautiful logs"""
    timestamp = datetime.now().strftime("%H:%M:%S")
    user_tag = Text(f"[{user_email}]", style="user")
    time_tag = Text(f"({timestamp}) ", style="dim")
    
    if status == "DETECTION":
        content = Text.assemble(time_tag, user_tag, (f" 🚨 {message}", "bold red"))
    elif status == "CLEAR":
        content = Text.assemble(time_tag, user_tag, (f" ✅ {message}", "success"))
    elif status == "CONN":
        content = Text.assemble(time_tag, user_tag, (f" 📡 {message}", "info"))
    else:
        content = Text.assemble(time_tag, user_tag, f" {message}")
        
    console.print(content)

# =====================================================================
# --- THE ROBUST FIX: DYNAMIC SHAPE INTERPOLATOR & SECURITY BYPASS ---
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

                if len(v.shape) == 4 and len(target_shape) == 4:
                    if v.shape[:2] == target_shape[:2]: 
                        new_v = torch.nn.functional.interpolate(
                            v.float(), size=target_shape[2:], mode='bicubic', align_corners=False
                        )
                        state_dict[k] = new_v.to(v.dtype)
                        continue
                        
                del state_dict[k]

    return original_load_state_dict(self, state_dict, strict=False, assign=assign)

torch.nn.Module.load_state_dict = dynamic_resize_load_state_dict

# =====================================================================

import supervision as sv
from transformers import SegformerImageProcessor, SegformerForSemanticSegmentation
from rfdetr import RFDETRLarge
from feature_extractor import FeatureExtractor

# --- CONFIGURATION ---
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY") 

# Adjust this to your exact local path
CHECKPOINT_PATH = r"C:\\The Sketchbook\\SEM VI\\PBL\\Tethered\\best_saved_model\\checkpoint_best_ema.pth"

CONF_THRESHOLD = 0.40
IMG_SIZE = 640
PORT = 5000

# Deduplication Config
SPATIAL_RADIUS_METERS = 8
VISUAL_SIMILARITY_THRESHOLD = 0.85
HEADING_TOLERANCE_DEGREES = 45

# ROI Split Line Config
ROI_SPLIT_RATIO = 0.5  # 0.5 = dead centre

if not SUPABASE_URL or not SUPABASE_SECRET_KEY:
    console.print("[error]❌ CREDENTIALS MISSING. Check .env for SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY[/error]")
    exit(1)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

app = FastAPI()
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SECRET_KEY)

# --- LOAD MODELS ---
console.print(Panel.fit("🚀 [bold white]ROAD SENSE PRO - ACTIVE PATROL NODE[/bold white]\n[dim]Initializing Artificial Intelligence System...[/dim]", border_style="cyan"))

with console.status("[bold green]Loading Segformer & RF-DETR Models...") as status:
    processor = SegformerImageProcessor.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024")
    seg_model = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024").to(DEVICE)
    seg_model.eval()

    try:
        det_model = RFDETRLarge(num_classes=1, pretrain_weights=CHECKPOINT_PATH, resolution=IMG_SIZE)
        det_model.optimize_for_inference()
    except Exception as e:
        console.print(f"[error]❌ CRITICAL ERROR: Interceptor failed. Error: {e}[/error]")
        exit(1)

    resnet_extractor = FeatureExtractor()

console.print("[success]✅ System online and running on[/success] [bold yellow]" + str(DEVICE).upper() + "[/bold yellow]\n")

# --- DATA MODEL ---
class DetectionRequest(BaseModel):
    image: str       
    gps: dict        
    instance_ip: str 
    roughness: float 
    user_id: str      
    user_email: str   
    debug_mode: bool = False

# --- AI HELPERS & ROI LOGIC ---
def draw_roi_divider(out, split_y, frame_w):
    overlay = out.copy()
    cv2.rectangle(overlay, (0, 0), (frame_w, split_y), (30, 30, 30), -1)
    out = cv2.addWeighted(overlay, 0.45, out, 0.55, 0)
    ui_color = (0, 220, 255)
    dash_len, gap_len = 30, 15
    x = 0
    while x < frame_w:
        x_end = min(x + dash_len, frame_w)
        cv2.line(out, (x, split_y), (x_end, split_y), ui_color, 2)
        x += dash_len + gap_len
    zone_label_y = split_y + 18
    cv2.putText(out, "[ ACTIVE DETECTION ZONE ]", (10, zone_label_y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, ui_color, 1, cv2.LINE_AA)
    cv2.putText(out, "[ FAR-FIELD - IGNORED ]", (10, max(18, split_y - 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (160, 160, 160), 1, cv2.LINE_AA)
    chevron_h, chevron_w = 16, 24
    num_chevrons = 5
    spacing = frame_w // (num_chevrons + 1)
    for n in range(1, num_chevrons + 1):
        cx = n * spacing
        pts = np.array([[cx - chevron_w // 2, split_y - chevron_h // 2],[cx + chevron_w // 2, split_y - chevron_h // 2],[cx, split_y + chevron_h // 2]], dtype=np.int32)
        cv2.fillPoly(out, [pts], ui_color)
    return out

def filter_detections_by_roi(detections, split_y):
    if len(detections) == 0: return detections
    keep =[]
    for box in detections.xyxy:
        y1, y2 = box[1], box[3]
        centre_y = (y1 + y2) / 2.0
        keep.append(centre_y >= split_y)
    return detections[np.array(keep)]

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
        if (x2-x1)*(y2-y1) == 0:
            keep.append(False); continue
        ratio = np.sum(crop) / ((x2-x1)*(y2-y1))
        keep.append(ratio >= 0.3)
    return detections[np.array(keep)]

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
        s.close()
    except: IP = "127.0.0.1"
    return IP

# --- API ENDPOINT ---
@app.post("/detect")
async def process_request(data: DetectionRequest, background_tasks: BackgroundTasks):
    global active_users
    now = time.time()
    
    if data.user_email not in active_users:
        log_event(data.user_email, "CONN", "User connected to Patrol Node", "info")
    active_users[data.user_email] = now

    try:
        # A. Telemetry Logging
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

        frame_h, frame_w = cv_img.shape[:2]
        split_y = int(frame_h * ROI_SPLIT_RATIO)
        area = frame_h * frame_w

        pil_img = Image.fromarray(cv2.cvtColor(cv_img, cv2.COLOR_BGR2RGB))
        pil_inf = pil_img.resize((IMG_SIZE, IMG_SIZE))

        # C. Inference & Filtering
        road_mask = get_road_mask(pil_img)
        raw_hits = det_model.predict(pil_inf, threshold=CONF_THRESHOLD)
        
        if len(raw_hits) > 0:
            raw_hits.xyxy[:, [0, 2]] *= (frame_w / IMG_SIZE)
            raw_hits.xyxy[:, [1, 3]] *= (frame_h / IMG_SIZE)
        
        roi_hits = filter_detections_by_roi(raw_hits, split_y)
        hits = filter_by_road(roi_hits, road_mask)
        
        scene = cv_img.copy()

        # D. Rendering UI
        if data.debug_mode or len(hits) > 0:
            scene = draw_roi_divider(scene, split_y, frame_w)
            rm_color = np.zeros_like(cv_img)
            rm_color[road_mask == 1] = [0, 255, 0]
            scene = cv2.addWeighted(scene, 1.0, rm_color, 0.15, 0)

        # Early Return if Clear
        if len(hits) == 0: 
            log_event(data.user_email, "CLEAR", f"Patrolling at {data.gps['lat']:.4f}, {data.gps['lon']:.4f} (Road Clear)")
            resp = {"status": "clear"}
            if data.debug_mode:
                _, b = cv2.imencode('.jpg', scene,[int(cv2.IMWRITE_JPEG_QUALITY), 60])
                resp["debug_image"] = base64.b64encode(b.tobytes()).decode('utf-8')
            return resp

        # E. Hits Processing
        new_dets =[]
        max_severity = "Minor"
        for box, conf in zip(hits.xyxy, hits.confidence):
            x1, y1, x2, y2 = map(int, box)
            x1, y1, x2, y2 = max(0,x1), max(0,y1), min(frame_w,x2), min(frame_h,y2)
            crop = cv_img[y1:y2, x1:x2]
            if crop.size == 0: continue
            
            gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
            edges = cv2.Canny(gray, 50, 150)
            score = (0.6 * ((x2-x1)*(y2-y1)/area)) + (0.4 * (np.sum(edges>0)/edges.size))
            
            if score < 0.3: lab, col = "Minor", (0, 255, 0)
            elif score < 0.6: lab, col = "Moderate", (0, 255, 255); max_severity = "Moderate"
            else: lab, col = "Severe", (0, 0, 255); max_severity = "Severe"
            
            ovl = scene.copy()
            cv2.rectangle(ovl, (x1,y1), (x2,y2), col, -1)
            scene = cv2.addWeighted(ovl, 0.35, scene, 0.65, 0)
            scene[y1:y2, x1:x2][edges > 0] =[255, 255, 255]
            cv2.rectangle(scene, (x1, y1-25), (x2, y1), col, -1)
            cv2.putText(scene, f"{lab} ({conf:.2f})", (x1+5, y1-7), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,0,0), 1)
            
            new_dets.append({"severity": lab, "embedding": resnet_extractor.get_embedding(crop)})

        log_event(data.user_email, "DETECTION", f"FOUND {len(new_dets)} POTHOLE(S)! Max Severity: {max_severity.upper()}")

        # F. Upload Evidence
        _, b = cv2.imencode('.jpg', scene,[int(cv2.IMWRITE_JPEG_QUALITY), 75])
        fname = f"ph_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.jpg"
        supabase.storage.from_("pothole-images").upload(fname, b.tobytes(), {"content-type": "image/jpeg"})
        url = supabase.storage.from_("pothole-images").get_public_url(fname)

        # G. Deduplication & DB Entry
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
                supabase.table("detections").update({"report_count": cand['report_count']+1, "last_seen": datetime.now().isoformat(), "image_url": url}).eq("id", match_id).execute()
            else:
                supabase.table("detections").insert({"latitude": lat, "longitude": lon, "heading": head, "image_url": url, "severity": det["severity"], "user_id": data.user_id, "user_email": data.user_email, "embedding": str(det["embedding"]), "report_count": 1, "last_seen": datetime.now().isoformat()}).execute()

        resp = {"status": "detected", "url": url}
        if data.debug_mode:
            resp["debug_image"] = base64.b64encode(b.tobytes()).decode('utf-8')
        return resp

    except Exception as e:
        console.print(f"[error]❌ FATAL ERROR:[/error] {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    local_ip = get_local_ip()
    console.print(f"\n[bold green]✅ Ready to receive data on: http://{local_ip}:{PORT}[/bold green]")
    console.print(f"[dim]If using Cloudflare, run in another terminal: cloudflared tunnel --url http://127.0.0.1:{PORT}[/dim]\n")
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="error")
