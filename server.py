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

from email_service import send_pothole_email

# ================= CONFIG =================
load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY")

MODEL_PATH = "best.pt"
CONF_THRESHOLD = 0.45
PORT = 5000

if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
    raise RuntimeError("Supabase credentials missing")

# ================= APP =================
app = FastAPI()
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

print("🔄 Loading YOLO model...")
model = YOLO(MODEL_PATH)
print("✅ YOLO loaded")

# ================= MODELS =================
class DetectionRequest(BaseModel):
    image: str
    gps: dict
    instance_ip: str
    roughness: float

# ================= HELPERS =================
def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"

def insert_road_log(data):
    supabase.table("road_logs").insert(data).execute()

# ================= ROUTES =================
@app.get("/")
def health():
    return {"status": "active", "service": "road-eye"}

@app.post("/detect")
async def detect_potholes(
    data: DetectionRequest,
    background_tasks: BackgroundTasks
):
    try:
        # 1️⃣ Save telemetry (background)
        background_tasks.add_task(
            insert_road_log,
            {
                "latitude": data.gps["lat"],
                "longitude": data.gps["lon"],
                "roughness": data.roughness,
                "session_id": data.instance_ip
            }
        )

        # 2️⃣ Decode image
        frame = cv2.imdecode(
            np.frombuffer(base64.b64decode(data.image), np.uint8),
            cv2.IMREAD_COLOR
        )
        if frame is None:
            return {"status": "error", "msg": "Invalid image"}

        # 3️⃣ YOLO inference
        results = model(frame, conf=CONF_THRESHOLD, verbose=False)
        if len(results[0].boxes) == 0:
            return {"status": "clear"}

        # 4️⃣ Annotate + compress
        annotated = results[0].plot()
        _, buffer = cv2.imencode(
            ".jpg",
            annotated,
            [int(cv2.IMWRITE_JPEG_QUALITY), 70]
        )

        filename = f"ph_{datetime.utcnow().strftime('%Y%m%d_%H%M%S_%f')}.jpg"

        # 5️⃣ Upload image to Supabase
        supabase.storage.from_("pothole-images").upload(
            filename,
            buffer.tobytes(),
            {"content-type": "image/jpeg"}
        )
        image_url = supabase.storage.from_("pothole-images").get_public_url(filename)

        # 6️⃣ Insert detection
        confidence = float(results[0].boxes.conf[0])
        det = supabase.table("detections").insert({
            "latitude": data.gps["lat"],
            "longitude": data.gps["lon"],
            "image_url": image_url,
            "pc_node_id": data.instance_ip,
            "severity": "High",
            "confidence": confidence
        }).execute()

        detection_id = det.data[0]["id"]

        # 7️⃣ Duplicate complaint check
        recent = supabase.rpc(
            "check_recent_complaint",
            {
                "lat": data.gps["lat"],
                "lng": data.gps["lon"]
            }
        ).execute()

        # 8️⃣ Insert complaint + EMAIL AUTO SEND
        if not recent.data:
            supabase.table("pothole_complaints").insert({
                "detection_id": detection_id,
                "latitude": data.gps["lat"],
                "longitude": data.gps["lon"],
                "severity": "High",
                "image_url": image_url,
                "emailed": True
            }).execute()

            background_tasks.add_task(
                send_pothole_email,
                data.gps["lat"],
                data.gps["lon"],
                image_url,
                "High"
            )

            print("📧 Email sent")

        print(f"🚨 POTHOLE @ {data.gps['lat']}, {data.gps['lon']}")

        return {
            "status": "detected",
            "image_url": image_url,
            "emailed": not bool(recent.data)
        }

    except Exception as e:
        print("❌ Error:", e)
        raise HTTPException(status_code=500, detail=str(e))

# ================= RUN =================
if __name__ == "__main__":
    ip = get_local_ip()
    print(f"🚀 Server running at http://{ip}:{PORT}")
    uvicorn.run(app, host="0.0.0.0", port=PORT)
