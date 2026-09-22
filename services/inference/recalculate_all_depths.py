"""
Batch Recalculation & Overwrite Script for Road Sense Pro.
Recalculates 3D depth, ground plane RANSAC baselines, cavity volumetric profiles,
3D Gaussian Splats, Three.js WebGL viewers, and 7-panel diagnostic inspection images
for all raw videos in Tethered/storage/videos/.
Updates Supabase spatial_reconstructions and spatial_video_reports accordingly.
"""

import os
import sys
import time
import json
import glob
from pathlib import Path
from typing import Dict, Any, Optional

# Ensure repository root and depth modules are in Python path
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.extend([
    str(SCRIPT_DIR),
    str(REPO_ROOT),
    str(REPO_ROOT / "core" / "depth_engine"),
    str(REPO_ROOT / "core"),
    str(REPO_ROOT / "Depth"),
])

from dotenv import load_dotenv
from supabase import create_client

try:
    from core.depth_engine.config import PipelineConfig
    from core.depth_engine.pipeline import RoadReconstructionPipeline
except ImportError:
    try:
        from Depth.config import PipelineConfig
        from Depth.pipeline import RoadReconstructionPipeline
    except ImportError:
        from config import PipelineConfig
        from pipeline import RoadReconstructionPipeline

load_dotenv(REPO_ROOT / ".env")

SUPABASE_URL = os.getenv("SUPABASE_URL", "https://zqecqujwcgzqblhtgmbc.supabase.co")
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
TAILSCALE_FUNNEL_URL = os.getenv("TAILSCALE_FUNNEL_URL", "https://starship.tail454ce8.ts.net")
STORAGE_DIR = Path(os.getenv("STORAGE_DIR", str(REPO_ROOT / "storage")))
VIDEOS_DIR = STORAGE_DIR / "videos"
TELEMETRY_DIR = STORAGE_DIR / "telemetry"
OUTPUT_DIR = STORAGE_DIR / "reconstructions"

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

def main():
    print("=" * 80)
    print("   ROADEYE — BATCH 3D DEPTH & RECONSTRUCTION RECALCULATION")
    print("=" * 80)

    # Initialize Supabase Client
    supabase = None
    if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:
        try:
            supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
            print(f"[Supabase] Connected to {SUPABASE_URL}")
        except Exception as e:
            print(f"[Supabase] Warning: Could not connect to Supabase: {e}")

    # Discover all videos
    video_files = sorted(list(VIDEOS_DIR.glob("*.mp4")))
    print(f"[Storage] Found {len(video_files)} videos in {VIDEOS_DIR}\n")

    if not video_files:
        print("[Error] No .mp4 videos found in storage/videos!")
        return

    # Initialize Pipeline ONCE to reuse loaded models in VRAM
    print("[Pipeline] Initializing Depth Anything V2 + RF-DETR + Geometry Profiler...")
    t_init = time.time()
    config = PipelineConfig(output_dir=str(OUTPUT_DIR))
    pipeline = RoadReconstructionPipeline(config=config)
    print(f"[Pipeline] Master pipeline ready in {time.time() - t_init:.2f}s!\n")

    summary_results = []
    total_batch_start = time.time()

    for idx, vpath in enumerate(video_files, 1):
        report_id = vpath.stem
        file_size_mb = vpath.stat().st_size / (1024 * 1024)
        print("\n" + "#" * 80)
        print(f"[{idx}/{len(video_files)}] PROCESSING VIDEO: {vpath.name} ({file_size_mb:.2f} MB)")
        print(f"Report ID: {report_id}")
        print("#" * 80)

        # Retrieve DB report metadata if available
        user_id = None
        distance_meters = 10.0
        if supabase:
            try:
                rep_res = supabase.from_("spatial_video_reports").select("*").eq("id", report_id).execute()
                if rep_res.data:
                    rep_data = rep_res.data[0]
                    user_id = rep_data.get("user_id")
                    distance_meters = float(rep_data.get("distance_meters") or 10.0)
                    # Mark report as processing in Supabase
                    supabase.from_("spatial_video_reports").update({
                        "splat_status": "processing",
                        "progress_pct": 20
                    }).eq("id", report_id).execute()
            except Exception as e:
                print(f"[DB] Notice: Could not read/update report status: {e}")

        # Fallback to sidecar telemetry if present
        sidecar_file = TELEMETRY_DIR / f"{report_id}_telemetry.json"
        if sidecar_file.exists():
            try:
                sidecar_data = json.loads(sidecar_file.read_text(encoding="utf-8"))
                if not user_id and sidecar_data.get("user_id"):
                    user_id = sidecar_data.get("user_id")
                if distance_meters == 10.0 and sidecar_data.get("distance_meters"):
                    distance_meters = float(sidecar_data.get("distance_meters"))
            except Exception:
                pass

        if not user_id:
            user_id = "99933619-aec0-4e48-9e33-33be9f417509"

        t_video_start = time.time()
        try:
            # Execute full reconstruction and metric depth calculation (keyframe_step=3 for optimal performance & resolution)
            results = pipeline.process_video(str(vpath), keyframe_step=3)
            proc_duration_s = time.time() - t_video_start

            telemetry = results.get("telemetry", {})
            max_depth_cm = float(telemetry.get("max_depth_cm", 0.0))
            volume_liters = float(telemetry.get("volume_liters", 0.0))
            surface_area_cm2 = float(telemetry.get("surface_area_cm2", 0.0))
            surface_area_sqm = surface_area_cm2 / 10000.0
            pothole_count = int(telemetry.get("num_cavities", 1))
            total_splats = int(telemetry.get("total_splats", 0))
            lci_index = round(volume_liters / max(distance_meters, 1.0), 3)

            ply_path = results.get("ply_path", "")
            html_path = results.get("html_path", "")
            inspection_img_path = results.get("inspection_image_path", "")
            viewer_url = f"{TAILSCALE_FUNNEL_URL}/api/v1/spatial/reconstruction/{report_id}/viewer"

            # Update Supabase spatial_reconstructions
            if supabase:
                try:
                    # Clean up any existing records for this report_id to avoid duplicates
                    supabase.from_("spatial_reconstructions").delete().eq("report_id", report_id).execute()

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
                        "processing_time_ms": int(proc_duration_s * 1000),
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
                    supabase.from_("spatial_reconstructions").insert(reconstruction_payload).execute()

                    # Mark spatial_video_reports as completed (100%)
                    supabase.from_("spatial_video_reports").update({
                        "splat_status": "completed",
                        "progress_pct": 100,
                        "error_message": None
                    }).eq("id", report_id).execute()
                    print(f"[Supabase] Successfully synchronized report {report_id} to database!")
                except Exception as db_err:
                    print(f"[Supabase] Error writing reconstruction to DB: {db_err}")

            summary_results.append({
                "report_id": report_id,
                "video": vpath.name,
                "status": "SUCCESS",
                "max_depth_cm": max_depth_cm,
                "volume_liters": volume_liters,
                "surface_area_cm2": surface_area_cm2,
                "severity": telemetry.get("severity", "Nominal"),
                "total_splats": total_splats,
                "processing_time_s": round(proc_duration_s, 1),
                "ply_exists": os.path.exists(ply_path),
                "html_exists": os.path.exists(html_path),
                "inspection_exists": os.path.exists(inspection_img_path)
            })

        except Exception as err:
            print(f"[ERROR] Failed processing video {vpath.name}: {err}")
            if supabase:
                try:
                    supabase.from_("spatial_video_reports").update({
                        "splat_status": "failed",
                        "error_message": str(err)
                    }).eq("id", report_id).execute()
                except Exception:
                    pass
            summary_results.append({
                "report_id": report_id,
                "video": vpath.name,
                "status": "FAILED",
                "error": str(err)
            })

    total_batch_time = time.time() - total_batch_start
    print("\n" + "=" * 80)
    print(f"BATCH RECALCULATION COMPLETE in {total_batch_time:.2f} seconds ({total_batch_time/60.0:.2f} minutes)!")
    print("=" * 80)
    print(f"{'Video File':<42} | {'Depth (cm)':<10} | {'Volume (L)':<10} | {'Splats':<8} | {'Time (s)':<8} | {'Status'}")
    print("-" * 95)
    for res in summary_results:
        if res.get("status") == "SUCCESS":
            print(f"{res['video']:<42} | {res['max_depth_cm']:<10.2f} | {res['volume_liters']:<10.2f} | {res['total_splats']:<8} | {res['processing_time_s']:<8.1f} | SUCCESS")
        else:
            print(f"{res['video']:<42} | {'FAILED':<10} | {'-':<10} | {'-':<8} | {'-':<8} | {res.get('error', 'Error')}")
    print("=" * 80 + "\n")

    # Save summary report JSON
    summary_path = OUTPUT_DIR / "recalculation_batch_summary.json"
    summary_path.write_text(json.dumps(summary_results, indent=2), encoding="utf-8")
    print(f"[Summary] Saved batch summary JSON to: {summary_path}")

if __name__ == "__main__":
    main()
