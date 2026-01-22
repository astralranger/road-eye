import cv2
import numpy as np
import base64
import uvicorn
import os
import socket
from datetime import datetime
from dotenv import load_dotenv

from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel
from supabase import create_client, Client
from ultralytics import YOLO

# --- CONFIGURATION ---
load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY") 
MODEL_PATH = "best.pt"
CONF_THRESHOLD = 0.45 # Increased threshold to reduce false positives
PORT = 5000

if not SUPABASE_URL or not SUPABASE_SECRET_KEY:
    print("❌ CREDENTIALS MISSING. Check .env")
    exit(1)

app = FastAPI()

# Init Resources
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SECRET_KEY)
print(f"🔄 Loading YOLO ({MODEL_PATH})...")
try:
    model = YOLO(MODEL_PATH)
    print("✅ Model Loaded.")
except Exception as e:
    print(f"❌ Model Error: {e}")
    exit(1)

class DetectionRequest(BaseModel):
    image: str       
    gps: dict        
    instance_ip: str 
    roughness: float 

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
        s.close()
    except: IP = "127.0.0.1"
    return IP

@app.get("/")
def health():
    return {"status": "active", "mode": "high_precision"}

@app.post("/detect")
async def detect_potholes(data: DetectionRequest, background_tasks: BackgroundTasks):
    try:
        # 1. Log Telemetry (Non-blocking DB insert for analysis)
        # We still save this for data science, but map won't render it
        log_entry = {
            "latitude": data.gps['lat'],
            "longitude": data.gps['lon'],
            "roughness": data.roughness,
            "session_id": data.instance_ip
        }
        background_tasks.add_task(supabase.table("road_logs").insert(log_entry).execute)

        # 2. Decode Image
        try:
            img_bytes = base64.b64decode(data.image)
            nparr = np.frombuffer(img_bytes, np.uint8)
            frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
            if frame is None: raise ValueError("Decode Fail")
        except:
            return {"status": "error", "msg": "Bad Image"}

        # 3. Inference
        results = model(frame, verbose=False, conf=CONF_THRESHOLD)
        
        if len(results[0].boxes) == 0:
            return {"status": "clear"}

        # 4. Pothole Detected
        plotted_frame = results[0].plot()
        
        # Optimize Image: Resize slightly if huge, Compress Quality 70
        _, buffer = cv2.imencode('.jpg', plotted_frame, [int(cv2.IMWRITE_JPEG_QUALITY), 70])
        file_bytes = buffer.tobytes()

        filename = f"ph_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.jpg"
        
        # Upload
        supabase.storage.from_("pothole-images").upload(
            path=filename,
            file=file_bytes,
            file_options={"content-type": "image/jpeg"}
        )
        final_url = supabase.storage.from_("pothole-images").get_public_url(filename)

        # Log Detection
        db_data = {
            "latitude": data.gps['lat'],
            "longitude": data.gps['lon'],
            "image_url": final_url,
            "pc_node_id": data.instance_ip,
            "severity": "High"
        }
        # Insert critical data immediately
        supabase.table("detections").insert(db_data).execute()

        print(f"🚨 POTHOLE: {data.gps['lat']}, {data.gps['lon']}")
        return {"status": "detected", "url": final_url}

    except Exception as e:
        print(f"Server Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    ip = get_local_ip()
    print(f"🚀 HIGH PERF SERVER | http://{ip}:{PORT}")
    uvicorn.run(app, host="0.0.0.0", port=PORT)