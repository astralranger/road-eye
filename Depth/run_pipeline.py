"""
Command-Line Interface (CLI) for the 3D Road & Pothole Geometric Reconstruction Pipeline.
Usage:
    python run_pipeline.py --video "path/to/dashcam.mp4" --h_cam 1.35 --output_dir "outputs"
    python run_pipeline.py --demo
"""

import argparse
import os
import sys
import cv2
import numpy as np

# Ensure Depth package is importable
current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from config import PipelineConfig, CameraConfig, DepthModelConfig, SplatConfig, FusionConfig
from pipeline import RoadReconstructionPipeline


def generate_synthetic_demo_video(output_video_path: str, num_frames: int = 40) -> str:
    """
    Generates a realistic synthetic road dashcam test video with asphalt texture,
    lane markings, and a progressive pothole cavity for zero-setup pipeline validation.
    """
    print(f"[Demo] Synthesizing test dashcam video at '{output_video_path}' ({num_frames} frames)...")
    os.makedirs(os.path.dirname(os.path.abspath(output_video_path)), exist_ok=True)

    w, h = 640, 480
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    out = cv2.VideoWriter(output_video_path, fourcc, 20.0, (w, h))

    np.random.seed(42)
    for f_idx in range(num_frames):
        # Base sky and road gradient
        frame = np.zeros((h, w, 3), dtype=np.uint8)
        frame[:180, :] = [180, 150, 100]  # Sky (BGR)

        # Asphalt road surface with fine noise
        road_noise = np.random.randint(45, 65, size=(h - 180, w, 3), dtype=np.uint8)
        frame[180:, :] = road_noise

        # Perspective road lane markers
        vp_x, vp_y = w // 2, 180
        cv2.line(frame, (vp_x, vp_y), (40, h), (255, 255, 255), 4, cv2.LINE_AA)
        cv2.line(frame, (vp_x, vp_y), (w - 40, h), (255, 255, 255), 4, cv2.LINE_AA)

        # Center dashed yellow line (moving towards camera)
        dash_offset = (f_idx * 15) % 80
        for y_dash in range(190 + dash_offset, h, 60):
            t = (y_dash - vp_y) / (h - vp_y)
            cx = int(vp_x)
            cv2.line(frame, (cx, y_dash), (cx, min(h, y_dash + 25)), (0, 220, 255), max(2, int(t * 6)), cv2.LINE_AA)

        # Introduce a pothole cavity appearing and getting closer
        # Appears around frame 10, closest around frame 30
        if 8 <= f_idx <= 35:
            prog = (f_idx - 8) / 27.0
            p_y = int(240 + prog * 160)
            p_x = int(w // 2 - 40 + prog * 20)
            p_radius_x = int(12 + prog * 28)
            p_radius_y = int(6 + prog * 16)

            # Dark cavity texture with irregular edges
            cv2.ellipse(frame, (p_x, p_y), (p_radius_x, p_radius_y), 0, 0, 360, (20, 20, 25), -1, cv2.LINE_AA)
            cv2.ellipse(frame, (p_x + 2, p_y + 2), (p_radius_x - 3, p_radius_y - 2), 0, 0, 360, (10, 10, 15), -1, cv2.LINE_AA)
            # Rim highlight
            cv2.ellipse(frame, (p_x, p_y), (p_radius_x + 2, p_radius_y + 1), 0, 0, 180, (70, 70, 75), 1, cv2.LINE_AA)

        out.write(frame)

    out.release()
    print(f"[Demo] Synthetic video created: {output_video_path}")
    return output_video_path


def main():
    parser = argparse.ArgumentParser(
        description="Production 3D Road & Pothole Geometric Reconstruction Pipeline"
    )
    parser.add_argument(
        "--video",
        type=str,
        default=None,
        help="Path to input dashcam .mp4 video file"
    )
    parser.add_argument(
        "--h_cam",
        type=float,
        default=1.35,
        help="Physical mounting height of camera above flat road surface in meters (default: 1.35)"
    )
    parser.add_argument(
        "--output_dir",
        type=str,
        default="reconstruction_outputs",
        help="Directory to save 3DGS PLY and Three.js HTML viewer files (default: 'reconstruction_outputs')"
    )
    parser.add_argument(
        "--max_frames",
        type=int,
        default=None,
        help="Maximum keyframes to process (default: all)"
    )
    parser.add_argument(
        "--keyframe_step",
        type=int,
        default=2,
        help="Process 1 out of every N video frames (default: 2)"
    )
    parser.add_argument(
        "--rfdetr_weights",
        type=str,
        default=None,
        help="Path to frozen RF-DETR checkpoint (.pth)"
    )
    parser.add_argument(
        "--ascii_ply",
        action="store_true",
        help="Export PLY in ASCII format instead of default fast Binary format"
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cuda",
        choices=["cuda", "cpu"],
        help="Inference device for Depth Anything V2 (default: 'cuda')"
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate and run test on synthetic dashcam video"
    )

    args = parser.parse_args()

    # Determine video file
    video_path = args.video
    if args.demo or not video_path:
        demo_dir = os.path.join(args.output_dir, "demo")
        demo_video = os.path.join(demo_dir, "synthetic_dashcam.mp4")
        video_path = generate_synthetic_demo_video(demo_video, num_frames=35)

    # Initialize configuration
    cfg = PipelineConfig()
    cfg.camera.camera_height_m = args.h_cam
    cfg.output_dir = args.output_dir
    cfg.depth.device = args.device
    cfg.fusion.keyframe_step = args.keyframe_step
    cfg.ply_binary_format = not args.ascii_ply

    # Execute pipeline
    pipeline = RoadReconstructionPipeline(
        config=cfg,
        rfdetr_checkpoint=args.rfdetr_weights
    )

    results = pipeline.process_video(
        video_path=video_path,
        max_frames=args.max_frames,
        keyframe_step=args.keyframe_step
    )

    print("\n" + "="*70)
    print("[SUMMARY] EXECUTION COMPLETED:")
    print(f"  * Video: {results['video_path']}")
    print(f"  * Keyframes Processed: {results['frames_processed']}")
    print(f"  * Verified Potholes: {results['telemetry']['num_cavities']}")
    print(f"  * Max Depth: {results['telemetry']['max_depth_cm']:.2f} cm")
    print(f"  * Total Volume: {results['telemetry']['volume_liters']:.2f} Liters")
    print(f"  * Severity: {results['telemetry']['severity']}")
    print(f"  * 3DGS PLY: {results['ply_path']}")
    print(f"  * WebGL Viewer: {results['html_path']}")
    print("="*70 + "\n")


if __name__ == "__main__":
    main()
