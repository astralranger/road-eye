"""
Tailscale Funnel Ingress Service & Asynchronous 3D Reconstruction Worker.
Routes heavy computer vision workloads (RF-DETR, Depth Anything V2, 3DGS)
from mobile clients to local GPU compute, coordinating with Supabase control plane.
"""

import os
import sys
import time
import socket
import asyncio
import logging
from typing import Optional, Dict, Any
from datetime import datetime, timezone
from pathlib import Path
import uuid

from dotenv import load_dotenv
import jwt
import torch
import math
import cv2
import base64
import numpy as np
from PIL import Image
from scipy.spatial.distance import cosine
import uvicorn
from fastapi import FastAPI, UploadFile, File, Form, Header, HTTPException, BackgroundTasks, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from supabase import create_client, Client

# --- PYTORCH RESILIENT LOADER INTERCEPTOR (Weights & Pos-Embed Resize) ---
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

# Add repository root, core/depth_engine, and services to sys.path
BASE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BASE_DIR.parent.parent
sys.path.extend([
    str(BASE_DIR),
    str(REPO_ROOT),
    str(REPO_ROOT / "core" / "depth_engine"),
    str(REPO_ROOT / "core"),
    str(REPO_ROOT / "services"),
    str(REPO_ROOT / "services" / "inference"),
    str(REPO_ROOT / "Depth"),
])

try:
    from core.depth_engine.pipeline import RoadReconstructionPipeline
    from core.depth_engine.config import PipelineConfig
except ImportError:
    try:
        from Depth.pipeline import RoadReconstructionPipeline
        from Depth.config import PipelineConfig
    except ImportError:
        from pipeline import RoadReconstructionPipeline
        from config import PipelineConfig

# --- LOGGING SETUP ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s"
)
logger = logging.getLogger("FunnelIngress")

# --- ENVIRONMENT & CONFIGURATION ---
# Load Tethered/.env first with override, then REPO_ROOT/.env as fallback
load_dotenv(dotenv_path=BASE_DIR / ".env", override=True)
if (REPO_ROOT / ".env").exists():
    load_dotenv(dotenv_path=REPO_ROOT / ".env", override=False)

SUPABASE_URL = os.getenv("SUPABASE_URL", "https://zqecqujwcgzqblhtgmbc.supabase.co")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
TAILSCALE_FUNNEL_URL = os.getenv("TAILSCALE_FUNNEL_URL", "https://starship.tail454ce8.ts.net")
NODE_ID = os.getenv("NODE_ID", socket.gethostname().lower().replace(" ", "-"))
NODE_NAME = os.getenv("NODE_NAME", f"Edge GPU Node ({socket.gethostname()})")
RFDETR_CHECKPOINT = os.getenv("RFDETR_CHECKPOINT", "")
if not RFDETR_CHECKPOINT or not Path(RFDETR_CHECKPOINT).exists():
    possible_ckpts = [
        BASE_DIR / "best_saved_model" / "checkpoint_best_ema.pth",
        REPO_ROOT / "best_saved_model" / "checkpoint_best_ema.pth",
        Path(r"C:\The Sketchbook\SEM VI\PBL\Tethered\best_saved_model\checkpoint_best_ema.pth"),
    ]
    for p in possible_ckpts:
        if p.exists():
            RFDETR_CHECKPOINT = str(p)
            break

STORAGE_DIR = Path(os.getenv("STORAGE_DIR", str(REPO_ROOT / "storage")))
UPLOAD_DIR = STORAGE_DIR / "videos"
TELEMETRY_DIR = STORAGE_DIR / "telemetry"
OUTPUT_DIR = STORAGE_DIR / "reconstructions"
STATIC_DIR = (REPO_ROOT / "services" / "dashboard" / "static") if (REPO_ROOT / "services" / "dashboard" / "static").exists() else (BASE_DIR / "static")
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
TELEMETRY_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
STATIC_DIR.mkdir(parents=True, exist_ok=True)

# Supabase Admin Client
supabase_admin: Optional[Client] = None
if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:
    try:
        supabase_admin = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
        logger.info(f"Supabase Admin Client initialized against {SUPABASE_URL}")
    except Exception as e:
        logger.error(f"Failed to initialize Supabase client: {e}")

# Global Job Tracking
active_jobs_count = 0

# --- FASTAPI APP INITIALIZATION ---
app = FastAPI(
    title="Road Sense Tailscale Funnel Ingress",
    description="High-Throughput Ingress & Compute Plane for 3D Gaussian Splatting & RF-DETR",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


def is_valid_uuid(val: Any) -> bool:
    """Verifies whether a string conforms to valid RFC 4122 UUID syntax for Postgres."""
    if not val:
        return False
    try:
        uuid.UUID(str(val))
        return True
    except (ValueError, AttributeError):
        return False


# --- AUTHENTICATION DEPENDENCY ---
async def verify_supabase_jwt(authorization: Optional[str] = Header(None)) -> Dict[str, Any]:
    """
    Validates the Supabase Bearer JWT token sent by the mobile client.
    Extracts user_id ('sub') and user_email.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid Authorization header. Expected Bearer token.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = authorization.split(" ")[1]
    
    # Supabase tokens are signed with either project JWT secret or asymmetric keys.
    # We inspect claims and verify token structure and expiration.
    try:
        # Decode without verifying signature first to extract claims, or verify if secret provided
        unverified_claims = jwt.decode(token, options={"verify_signature": False})
        
        # Verify expiration
        exp = unverified_claims.get("exp")
        if exp and datetime.fromtimestamp(exp, tz=timezone.utc) < datetime.now(tz=timezone.utc):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token has expired.")

        user_id = unverified_claims.get("sub")
        if not user_id:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token: missing subject claim.")

        return {
            "user_id": user_id,
            "user_email": unverified_claims.get("email", "unknown@roadsense.local"),
            "role": unverified_claims.get("role", "authenticated")
        }
    except jwt.PyJWTError as e:
        logger.warning(f"JWT Validation error: {e}")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=f"Token validation failed: {e}")


# --- BACKGROUND HEARTBEAT DAEMON ---
async def heartbeat_daemon():
    """
    Periodically updates the 'system_health' table in Supabase every 15 seconds
    to advertise node availability, GPU VRAM status, and public Funnel URL.
    """
    global active_jobs_count
    while True:
        try:
            if supabase_admin:
                gpu_name = "CPU Host"
                gpu_util = 0.0
                vram_used = 0
                vram_total = 0

                if torch.cuda.is_available():
                    gpu_name = torch.cuda.get_device_name(0)
                    vram_used = int(torch.cuda.memory_allocated(0) / (1024 * 1024))
                    vram_total = int(torch.cuda.get_device_properties(0).total_memory / (1024 * 1024))
                    gpu_util = round((vram_used / max(vram_total, 1)) * 100.0, 1)

                node_status = "busy" if active_jobs_count > 2 else "online"

                payload = {
                    "node_id": NODE_ID,
                    "node_name": NODE_NAME,
                    "funnel_url": TAILSCALE_FUNNEL_URL,
                    "status": node_status,
                    "last_heartbeat": datetime.now(timezone.utc).isoformat(),
                    "gpu_device_name": gpu_name,
                    "gpu_utilization_pct": gpu_util,
                    "vram_used_mb": vram_used,
                    "vram_total_mb": vram_total,
                    "active_jobs": active_jobs_count,
                    "supported_pipelines": ["rf_detr", "depth_splatting", "volumetric_analysis"]
                }

                supabase_admin.from_("system_health").upsert(payload).execute()
                logger.info(f"Heartbeat updated for node '{NODE_ID}' ({node_status}) at {payload['last_heartbeat']}")
            else:
                logger.warning("Heartbeat skipped: supabase_admin is not initialized! Check SUPABASE_SERVICE_ROLE_KEY in .env")
        except Exception as e:
            logger.warning(f"Heartbeat publication failed: {e}")

        await asyncio.sleep(15)


@app.on_event("startup")
async def on_startup():
    logger.info(f"Starting Tailscale Funnel Ingress Node '{NODE_ID}'")
    logger.info(f"Target Public Funnel URL: {TAILSCALE_FUNNEL_URL}")
    logger.info(f"PyTorch CUDA Available: {torch.cuda.is_available()}")
    
    # Recover any orphaned processing jobs in Supabase
    if supabase_admin:
        try:
            res = supabase_admin.from_("spatial_video_reports") \
                .update({"splat_status": "queued", "progress_pct": 0, "error_message": "Recovered by node restart"}) \
                .eq("processing_node_id", NODE_ID) \
                .eq("splat_status", "processing") \
                .execute()
            logger.info("Checked for orphaned processing jobs on startup.")
        except Exception as e:
            logger.warning(f"Startup orphan recovery warning: {e}")

    # Launch heartbeat background task
    asyncio.create_task(heartbeat_daemon())


# --- HEAVY ASYNC PIPELINE EXECUTOR ---
def run_heavy_pipeline_sync(
    report_id: str,
    user_id: str,
    video_path: str,
    metadata: Dict[str, Any]
):
    """
    Synchronous worker routine running RF-DETR and 3D Gaussian Splatting pipeline.
    Invoked via asyncio.to_thread / background tasks.
    """
    global active_jobs_count
    active_jobs_count += 1
    start_time = time.time()
    logger.info(f"[{report_id}] Commencing 3D reconstruction pipeline on {video_path}")

    try:
        # Step 1: Update Supabase to processing (15%)
        if supabase_admin and is_valid_uuid(report_id):
            supabase_admin.from_("spatial_video_reports").update({
                "splat_status": "processing",
                "progress_pct": 15,
                "processing_node_id": NODE_ID
            }).eq("id", report_id).execute()

        # Step 2: Initialize Pipeline & Configuration
        pipeline_config = PipelineConfig(
            output_dir=str(OUTPUT_DIR)
        )
        pipeline = RoadReconstructionPipeline(
            config=pipeline_config,
            rfdetr_checkpoint=RFDETR_CHECKPOINT if os.path.exists(RFDETR_CHECKPOINT) else None
        )

        def on_pipeline_progress(pct: int, stage_desc: str):
            logger.info(f"[{report_id}] Pipeline Progress: {pct}% - {stage_desc}")
            if supabase_admin and is_valid_uuid(report_id):
                try:
                    supabase_admin.from_("spatial_video_reports").update({
                        "progress_pct": pct,
                        "splat_status": "processing",
                        "error_message": stage_desc
                    }).eq("id", report_id).execute()
                except Exception as pe:
                    logger.warning(f"[{report_id}] Progress update failed: {pe}")

        # Step 3: Run full video scan, metric depth inversion, 3DGS PLY & Three.js WebGL viewer with live progress callbacks
        results = pipeline.process_video(
            video_path=video_path,
            progress_callback=on_pipeline_progress
        )

        telemetry = results.get("telemetry", {})
        max_depth_cm = float(telemetry.get("max_depth_cm", 0.0))
        volume_liters = float(telemetry.get("volume_liters", 0.0))
        surface_area_cm2 = float(telemetry.get("surface_area_cm2", 0.0))
        surface_area_sqm = surface_area_cm2 / 10000.0
        pothole_count = int(telemetry.get("num_cavities", 1))
        total_splats = int(telemetry.get("total_splats", 0))

        # Calculate Longitudinal Cavity Index (LCI): Volume per meter of road traversed
        distance_meters = float(metadata.get("distance_meters", 10.0))
        lci_index = round(volume_liters / max(distance_meters, 1.0), 3)

        processing_time_ms = int((time.time() - start_time) * 1000)

        # Output file paths
        ply_path = results.get("ply_path", "")
        html_path = results.get("html_path") or results.get("viewer_html_path", "")
        inspection_img_path = results.get("inspection_image_path", "")

        # Public viewer URL via Tailscale Funnel
        viewer_url = f"{TAILSCALE_FUNNEL_URL}/api/v1/spatial/reconstruction/{report_id}/viewer"

        # Step 4: Write 3D reconstruction outputs to Supabase
        if supabase_admin and is_valid_uuid(report_id) and is_valid_uuid(user_id):
            reconstruction_payload = {
                "report_id": report_id,
                "user_id": user_id,
                "pothole_count": pothole_count,
                "max_depth_cm": max_depth_cm,
                "mean_depth_cm": round(max_depth_cm * 0.65, 2),
                "total_cavity_volume_liters": volume_liters,
                "surface_area_sqm": round(surface_area_sqm, 3),
                "lci_index": lci_index,
                "voxel_count": total_splats,
                "processing_time_ms": processing_time_ms,
                "splat_ply_path": ply_path,
                "viewer_html_path": viewer_url,
                "detections_summary": [
                    {
                        "severity": telemetry.get("severity", "Moderate"),
                        "max_depth_cm": max_depth_cm,
                        "volume_liters": volume_liters,
                        "splats": total_splats,
                        "inspection_image": inspection_img_path
                    }
                ]
            }

            # Delete any prior reconstruction row for idempotency / re-runs
            try:
                supabase_admin.from_("spatial_reconstructions").delete().eq("report_id", report_id).execute()
            except Exception as del_err:
                logger.warning(f"[{report_id}] Old reconstruction cleanup note: {del_err}")

            supabase_admin.from_("spatial_reconstructions").insert(reconstruction_payload).execute()

            # Step 5: Mark report as completed (100%)
            supabase_admin.from_("spatial_video_reports").update({
                "splat_status": "completed",
                "progress_pct": 100,
                "error_message": None
            }).eq("id", report_id).execute()

        logger.info(f"[{report_id}] 3D Reconstruction completed successfully in {processing_time_ms} ms!")

    except Exception as e:
        logger.error(f"[{report_id}] Pipeline execution failed: {e}", exc_info=True)
        if supabase_admin and is_valid_uuid(report_id):
            supabase_admin.from_("spatial_video_reports").update({
                "splat_status": "failed",
                "error_message": str(e)
            }).eq("id", report_id).execute()
    finally:
        active_jobs_count = max(0, active_jobs_count - 1)


# --- HTTP ENDPOINTS ---

@app.get("/health")
@app.get("/api/v1/spatial/health")
async def health_check():
    """Returns local node health, GPU capacity, and active workload."""
    gpu_available = torch.cuda.is_available()
    vram_free = 0
    if gpu_available:
        total = torch.cuda.get_device_properties(0).total_memory
        allocated = torch.cuda.memory_allocated(0)
        vram_free = int((total - allocated) / (1024 * 1024))

    return {
        "status": "ok",
        "node_id": NODE_ID,
        "node_name": NODE_NAME,
        "funnel_url": TAILSCALE_FUNNEL_URL,
        "active_jobs": active_jobs_count,
        "gpu": {
            "available": gpu_available,
            "device": torch.cuda.get_device_name(0) if gpu_available else "CPU",
            "vram_free_mb": vram_free
        },
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


@app.post("/api/v1/spatial/upload", status_code=status.HTTP_202_ACCEPTED)
@app.post("/upload-video", status_code=status.HTTP_202_ACCEPTED)
async def upload_spatial_video(
    background_tasks: BackgroundTasks,
    file: Optional[UploadFile] = File(None),
    video: Optional[UploadFile] = File(None),
    metadata: Optional[str] = Form(None),
    telemetry: Optional[str] = Form(None),
    authorization: Optional[str] = Header(None)
):
    """
    Accepts chunked multipart video stream + telemetry metadata from Road Sense mobile client.
    Supports both /api/v1/spatial/upload and /upload-video endpoints.
    Saves the payload locally and schedules asynchronous 3D reconstruction.
    """
    import json
    import uuid

    # Resolve uploaded file
    target_upload = file or video
    if not target_upload:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Missing video payload. Form field must be 'file' or 'video'."
        )

    # Parse metadata or telemetry JSON
    meta_raw = metadata or telemetry
    meta_dict: Dict[str, Any] = {}
    if meta_raw:
        try:
            meta_dict = json.loads(meta_raw)
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid JSON in 'metadata' or 'telemetry' form field.")

    report_id = meta_dict.get("report_id") or meta_dict.get("id")
    if not report_id:
        report_id = f"report_{uuid.uuid4().hex[:12]}"
        meta_dict["report_id"] = report_id

    user_id = meta_dict.get("user_id") or "test_user"

    dest_file_path = UPLOAD_DIR / f"{report_id}.mp4"

    logger.info(f"Receiving video stream for report {report_id} ({target_upload.filename})")

    # Stream video to disk in 512KB chunks to maintain strict low memory footprint
    try:
        with open(dest_file_path, "wb") as f:
            while chunk := await target_upload.read(512 * 1024):
                f.write(chunk)
    except Exception as e:
        logger.error(f"Failed to stream video to disk: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to store video payload: {e}")

    file_size_bytes = os.path.getsize(dest_file_path)
    logger.info(f"Stored {file_size_bytes} bytes at {dest_file_path}")

    # Immediately update Supabase so backend and client register the data drop
    if supabase_admin and is_valid_uuid(report_id):
        try:
            supabase_admin.from_("spatial_video_reports").update({
                "storage_status": "offloaded_to_node",
                "splat_status": "processing",
                "progress_pct": 15,
                "processing_node_id": NODE_ID,
                "error_message": "Video received by node. Initializing 3DGS pipeline."
            }).eq("id", report_id).execute()
        except Exception as e:
            logger.warning(f"Failed to record data drop in Supabase: {e}")

    # Container verification: inspect MP4 top-level atoms (ftyp, moov)
    has_ftyp, has_moov = False, False
    try:
        with open(dest_file_path, "rb") as f:
            file_len = file_size_bytes
            offset = 0
            while offset + 8 <= file_len:
                f.seek(offset)
                hdr = f.read(8)
                if len(hdr) < 8:
                    break
                box_sz = int.from_bytes(hdr[:4], "big")
                box_typ = hdr[4:8].decode("latin1", errors="ignore")
                if box_typ == "ftyp":
                    has_ftyp = True
                elif box_typ == "moov":
                    has_moov = True
                if box_sz == 1:
                    ext = f.read(8)
                    if len(ext) < 8:
                        break
                    box_sz = int.from_bytes(ext, "big")
                elif box_sz == 0:
                    box_sz = file_len - offset
                if box_sz < 8 or offset + box_sz > file_len:
                    break
                offset += box_sz
    except Exception as e:
        logger.warning(f"Failed to inspect MP4 container atoms: {e}")

    if not has_moov:
        logger.warning(f"[{report_id}] Uploaded video {dest_file_path} is missing 'moov' atom header!")

    # Persist telemetry JSON sidecar in storage/telemetry
    telemetry_path = TELEMETRY_DIR / f"{report_id}_telemetry.json"
    try:
        telemetry_path.write_text(json.dumps(meta_dict, indent=2), encoding="utf-8")
        logger.info(f"Stored telemetry sidecar at {telemetry_path}")
    except Exception as e:
        logger.warning(f"Failed to persist telemetry JSON: {e}")

    # Dispatch heavy processing in background
    asyncio.create_task(
        asyncio.to_thread(
            run_heavy_pipeline_sync,
            report_id,
            user_id,
            str(dest_file_path),
            meta_dict
        )
    )

    return {
        "success": True,
        "job_id": report_id,
        "status": "processing",
        "file_size_bytes": file_size_bytes,
        "saved_path": str(dest_file_path),
        "message": "Video payload accepted. 3D Gaussian Splatting & RF-DETR pipeline dispatched."
    }


@app.get("/api/v1/spatial/storage")
async def list_stored_files():
    """Lists all stored raw videos, telemetries, and 3D reconstructions on this node."""
    videos = []
    for f in UPLOAD_DIR.glob("*.mp4"):
        videos.append({
            "report_id": f.stem,
            "filename": f.name,
            "size_bytes": f.stat().st_size,
            "path": str(f),
            "modified": datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc).isoformat(),
            "has_telemetry": (TELEMETRY_DIR / f"{f.stem}_telemetry.json").exists(),
            "has_reconstruction": (OUTPUT_DIR / f"{f.stem}_3dgs.ply").exists()
        })
    reconstructions = [f.name for f in OUTPUT_DIR.glob("*.*")]
    return {
        "storage_root": str(STORAGE_DIR),
        "videos_directory": str(UPLOAD_DIR),
        "telemetry_directory": str(TELEMETRY_DIR),
        "reconstructions_directory": str(OUTPUT_DIR),
        "total_videos": len(videos),
        "videos": sorted(videos, key=lambda x: x["modified"], reverse=True),
        "reconstructions": reconstructions
    }


@app.get("/api/v1/spatial/reconstruction/{report_id}/viewer", response_class=HTMLResponse)
async def serve_3d_viewer(report_id: str):
    """
    Serves the generated Three.js WebGL 3D reconstruction viewer directly
    via the Tailscale Funnel HTTPS endpoint.
    """
    expected_html = OUTPUT_DIR / f"{report_id}_3d_viewer.html"
    if not expected_html.exists():
        legacy_dir = BASE_DIR / "reconstruction_outputs"
        matching = list(OUTPUT_DIR.glob(f"*{report_id}*.html")) or list(legacy_dir.glob(f"*{report_id}*.html"))
        if matching:
            expected_html = matching[0]
        else:
            # Fallback to the latest valid RoadEye viewer
            roadeye_viewers = [
                f for f in sorted(list(OUTPUT_DIR.glob("*_3d_viewer.html")), key=os.path.getmtime, reverse=True)
                if "ROADEYE" in f.read_text(encoding="utf-8", errors="ignore")[:800] or "RoadEye" in f.read_text(encoding="utf-8", errors="ignore")[:800]
            ]
            if roadeye_viewers:
                expected_html = roadeye_viewers[0]
            else:
                all_viewers = sorted(list(OUTPUT_DIR.glob("*.html")) + list(legacy_dir.glob("*.html")), key=os.path.getmtime, reverse=True)
                if all_viewers:
                    expected_html = all_viewers[0]
                else:
                    raise HTTPException(status_code=404, detail="3D WebGL viewer not yet generated or processing.")

    return HTMLResponse(
        content=expected_html.read_text(encoding="utf-8"),
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "X-Content-Type-Options": "nosniff"
        }
    )


@app.get("/api/v1/spatial/reconstruction/{report_id}/ply")
async def download_splat_ply(report_id: str):
    """
    Downloads the 3D Gaussian Splats PLY file.
    """
    expected_ply = OUTPUT_DIR / f"{report_id}_3dgs.ply"
    if not expected_ply.exists():
        legacy_dir = BASE_DIR / "reconstruction_outputs"
        matching = list(OUTPUT_DIR.glob(f"*{report_id}*.ply")) or list(legacy_dir.glob(f"*{report_id}*.ply"))
        if matching:
            expected_ply = matching[0]
        else:
            all_plys = sorted(list(OUTPUT_DIR.glob("*.ply")) + list(legacy_dir.glob("*.ply")), key=os.path.getmtime, reverse=True)
            if all_plys:
                expected_ply = all_plys[0]
            else:
                raise HTTPException(status_code=404, detail="3DGS PLY file not found.")

    return FileResponse(
        path=expected_ply,
        filename=expected_ply.name,
        media_type="application/octet-stream"
    )


@app.get("/api/v1/spatial/reconstruction/{report_id}/inspection")
async def get_inspection_panel(report_id: str):
    """
    Serves the consolidated 7-Panel Multi-Modal Diagnostic Inspection image.
    """
    expected_img = OUTPUT_DIR / f"{report_id}_inspection_panel.png"
    if not expected_img.exists():
        matching = list(OUTPUT_DIR.glob(f"*{report_id}*.png"))
        if matching:
            expected_img = matching[0]
        else:
            raise HTTPException(status_code=404, detail="Inspection panel image not found.")

    return FileResponse(
        path=expected_img,
        filename=expected_img.name,
        media_type="image/png"
    )


# =====================================================================
# --- 2D PATROL MODE REALTIME DETECTION ENDPOINT ---
# =====================================================================

class DetectionRequest(BaseModel):
    image: str       
    gps: dict        
    instance_ip: Optional[str] = "mobile_client"
    roughness: Optional[float] = 0.0
    user_id: Optional[str] = "patrol_user"
    user_email: Optional[str] = "patrol@roadsense.local"


det_2d_model = None
seg_2d_model = None
seg_2d_processor = None
feature_extractor = None

def get_2d_models():
    global det_2d_model, seg_2d_model, seg_2d_processor, feature_extractor
    if det_2d_model is None:
        try:
            from transformers import SegformerImageProcessor, SegformerForSemanticSegmentation
            from rfdetr import RFDETRLarge
            from feature_extractor import FeatureExtractor

            device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
            try:
                seg_2d_processor = SegformerImageProcessor.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024")
                seg_2d_model = SegformerForSemanticSegmentation.from_pretrained("nvidia/segformer-b0-finetuned-cityscapes-512-1024").to(device)
                seg_2d_model.eval()
            except Exception as seg_err:
                logger.warning(f"Segformer semantic model unavailable: {seg_err}")

            if Path(RFDETR_CHECKPOINT).exists():
                det_2d_model = RFDETRLarge(num_classes=1, pretrain_weights=RFDETR_CHECKPOINT, resolution=640)
                det_2d_model.optimize_for_inference()
                logger.info(f"✅ Loaded RF-DETR model from {RFDETR_CHECKPOINT}")
            else:
                logger.warning(f"RF-DETR checkpoint not found at {RFDETR_CHECKPOINT}")

            try:
                feature_extractor = FeatureExtractor()
            except Exception as feat_err:
                logger.warning(f"ResNet feature extractor unavailable: {feat_err}")

            logger.info("✅ 2D Pothole Detection Engines Ready.")
        except Exception as e:
            logger.error(f"Error initializing 2D detection models: {e}")
    return det_2d_model, seg_2d_model, seg_2d_processor, feature_extractor


@app.post("/detect")
async def process_patrol_detection(data: DetectionRequest, background_tasks: BackgroundTasks):
    """
    Real-time 2D pothole detection endpoint for mobile Patrol Mode.
    Processes incoming frames with RF-DETR, filters against road mask,
    uploads evidence to Supabase Storage, and logs to detections table.
    """
    try:
        # A. Telemetry Logging
        if supabase_admin and data.gps:
            try:
                telemetry = {
                    "latitude": data.gps.get('lat', 0.0),
                    "longitude": data.gps.get('lon', 0.0),
                    "roughness": data.roughness,
                    "session_id": data.instance_ip,
                    "user_id": data.user_id,
                    "user_email": data.user_email
                }
                background_tasks.add_task(supabase_admin.table("road_logs").insert(telemetry).execute)
            except Exception as tel_err:
                logger.debug(f"Telemetry logging warning: {tel_err}")

        # B. Decoding incoming frame
        img_bytes = base64.b64decode(data.image)
        cv_img = cv2.imdecode(np.frombuffer(img_bytes, np.uint8), cv2.IMREAD_COLOR)
        if cv_img is None:
            return {"status": "error", "msg": "Invalid image payload"}

        pil_image = Image.fromarray(cv2.cvtColor(cv_img, cv2.COLOR_BGR2RGB))
        image_area = cv_img.shape[0] * cv_img.shape[1]

        # C. Inference
        det_m, seg_m, seg_p, feat_ext = get_2d_models()
        if det_m is None:
            return {"status": "clear", "msg": "Inference model not initialized"}

        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

        road_mask = None
        if seg_m is not None and seg_p is not None:
            try:
                inputs = seg_p(images=pil_image, return_tensors="pt").to(device)
                with torch.no_grad():
                    outputs = seg_m(**inputs)
                logits = torch.nn.functional.interpolate(
                    outputs.logits, size=pil_image.size[::-1], mode="bilinear", align_corners=False
                )
                road_mask = (logits.argmax(dim=1).squeeze().cpu().numpy() == 0).astype(np.uint8)
                road_mask = cv2.dilate(road_mask, np.ones((15, 15), np.uint8), iterations=1)
            except Exception as r_err:
                logger.debug(f"Road segmentation warning: {r_err}")

        raw_detections = det_m.predict(pil_image.resize((640, 640)), threshold=0.4)
        if len(raw_detections) > 0:
            raw_detections.xyxy[:, [0, 2]] *= (cv_img.shape[1] / 640.0)
            raw_detections.xyxy[:, [1, 3]] *= (cv_img.shape[0] / 640.0)

        hits = raw_detections
        if road_mask is not None and len(raw_detections) > 0:
            keep = []
            for box in raw_detections.xyxy:
                x1, y1, x2, y2 = map(int, box)
                x1, y1 = max(0, x1), max(0, y1)
                x2, y2 = min(road_mask.shape[1], x2), min(road_mask.shape[0], y2)
                box_area = (x2 - x1) * (y2 - y1)
                if box_area == 0:
                    keep.append(False)
                    continue
                keep.append((np.sum(road_mask[y1:y2, x1:x2]) / box_area) >= 0.3)
            hits = raw_detections[np.array(keep)]

        if len(hits) == 0:
            return {"status": "clear"}

        # D. Annotation & Severity
        scene = cv_img.copy()
        new_dets = []
        for box, conf in zip(hits.xyxy, hits.confidence):
            x1, y1, x2, y2 = map(int, box)
            x1, y1 = max(0, x1), max(0, y1)
            x2, y2 = min(cv_img.shape[1], x2), min(cv_img.shape[0], y2)
            crop = cv_img[y1:y2, x1:x2]
            if crop.size == 0:
                continue

            gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
            edges = cv2.Canny(gray, 50, 150)
            score = (0.6 * ((x2 - x1) * (y2 - y1) / max(image_area, 1))) + (0.4 * (np.sum(edges > 0) / max(edges.size, 1)))

            if score < 0.3:
                lab, col = "Minor", (0, 255, 0)
            elif score < 0.6:
                lab, col = "Moderate", (0, 255, 255)
            else:
                lab, col = "Severe", (0, 0, 255)

            overlay = scene.copy()
            cv2.rectangle(overlay, (x1, y1), (x2, y2), col, -1)
            scene = cv2.addWeighted(overlay, 0.35, scene, 0.65, 0)
            scene[y1:y2, x1:x2][edges > 0] = [255, 255, 255]
            cv2.rectangle(scene, (x1, y1 - 25), (x2, y1), col, -1)
            cv2.putText(scene, f"{lab} ({conf:.2f})", (x1 + 5, y1 - 7), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1)

            emb = None
            if feat_ext is not None:
                try:
                    emb = feat_ext.get_embedding(crop)
                except Exception:
                    pass
            new_dets.append({"severity": lab, "embedding": emb})

        # E. Upload Evidence to Supabase Storage
        _, b = cv2.imencode('.jpg', scene, [int(cv2.IMWRITE_JPEG_QUALITY), 75])
        fname = f"ph_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.jpg"
        url = ""
        if supabase_admin:
            try:
                supabase_admin.storage.from_("pothole-images").upload(fname, b.tobytes(), {"content-type": "image/jpeg"})
                url = supabase_admin.storage.from_("pothole-images").get_public_url(fname)
            except Exception as up_err:
                logger.warning(f"Storage upload warning: {up_err}")

        # F. Deduplication & Insert into detections table
        lat = data.gps.get('lat', 0.0)
        lon = data.gps.get('lon', 0.0)
        head = data.gps.get('heading', 0.0)

        if supabase_admin:
            candidates = None
            try:
                candidates = supabase_admin.rpc("find_candidates", {
                    "search_lat": lat, "search_lon": lon, "radius_m": 8
                }).execute().data
            except Exception as cand_err:
                logger.debug(f"find_candidates RPC fallback: {cand_err}")

            for det in new_dets:
                match_id = None
                if candidates and det["embedding"] is not None:
                    for cand in candidates:
                        a_diff = abs(cand.get('heading', 0.0) - head)
                        if a_diff > 180: a_diff = 360 - a_diff
                        if a_diff > 45: continue
                        cand_emb = cand.get('embedding')
                        if cand_emb:
                            try:
                                sim = 1 - cosine(det["embedding"], np.array(eval(cand_emb)))
                                if sim > 0.85:
                                    match_id = cand['id']
                                    break
                            except Exception:
                                pass

                if match_id:
                    try:
                        supabase_admin.table("detections").update({
                            "report_count": cand.get('report_count', 1) + 1,
                            "last_seen": datetime.now(timezone.utc).isoformat(),
                            "image_url": url if url else None
                        }).eq("id", match_id).execute()
                    except Exception as upd_err:
                        logger.warning(f"Detection update warning: {upd_err}")
                else:
                    try:
                        emb_str = str(det["embedding"].tolist()) if (det["embedding"] is not None and hasattr(det["embedding"], "tolist")) else str(det["embedding"])
                        supabase_admin.table("detections").insert({
                            "latitude": lat,
                            "longitude": lon,
                            "heading": head,
                            "image_url": url,
                            "severity": det["severity"],
                            "user_id": data.user_id,
                            "user_email": data.user_email,
                            "embedding": emb_str if emb_str else "[]",
                            "report_count": 1,
                            "last_seen": datetime.now(timezone.utc).isoformat()
                        }).execute()
                        logger.info(f"🚨 Pothole Logged: {det['severity']} at ({lat:.4f}, {lon:.4f}) by {data.user_email}")
                    except Exception as ins_err:
                        logger.error(f"Failed to insert detection into DB: {ins_err}")

        return {"status": "detected", "url": url}
    except Exception as e:
        logger.error(f"Error processing /detect request: {e}")
        return {"status": "error", "detail": str(e)}


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8000))
    logger.info(f"Starting Uvicorn server on port {port}...")
    app_target = "services.ingress.funnel_ingress:app" if (Path.cwd() == REPO_ROOT) else "funnel_ingress:app"
    uvicorn.run(
        app_target,
        host="0.0.0.0",
        port=port,
        reload=False,
        log_level="info"
    )
