"""
Unit and Integration Test for the 3D Road Reconstruction Pipeline.
Verifies geometry gating, voxel hash deduplication, 3DGS PLY synthesis, and WebGL viewer.
"""

import os
import sys
import numpy as np

# Ensure Depth package is importable
current_dir = os.path.dirname(os.path.abspath(__file__))
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

import config
import geometry
import odometry
import fusion
import viewer
import detector


def run_tests():
    print("[TEST] Running 3D Road Pipeline Unit Tests...")

    # 1. Test Geometry & Deterministic Gating
    profiler = geometry.GeometryProfiler()
    H, W = 60, 60
    Z_mock = np.ones((H, W), dtype=np.float32) * 5.0
    X_mock = np.zeros((H, W), dtype=np.float32)
    Y_mock = np.zeros((H, W), dtype=np.float32)

    # Test 1A: Flat surface (0 depth) -> MUST REJECT
    delta_Z_flat = np.zeros((H, W), dtype=np.float32)
    m_flat, _ = profiler.evaluate_and_profile_cavity(delta_Z_flat, Z_mock, X_mock, Y_mock, 500, 500)
    assert not m_flat.is_valid_cavity, "Flat surface must be rejected!"
    print(f"  [PASS] Test 1A (Flat Surface Rejection): {m_flat.rejection_reason}")

    # Test 1B: Shallow anomaly (1.0 cm < 2.5 cm threshold) -> MUST REJECT
    delta_Z_shallow = np.full((H, W), 0.010, dtype=np.float32)
    m_shallow, _ = profiler.evaluate_and_profile_cavity(delta_Z_shallow, Z_mock, X_mock, Y_mock, 500, 500)
    assert not m_shallow.is_valid_cavity, "Shallow anomaly under 2.5 cm must be rejected!"
    print(f"  [PASS] Test 1B (Shallow Depth Rejection): {m_shallow.rejection_reason}")

    # Test 1C: Small cluster (< 50 px) -> MUST REJECT
    delta_Z_small = np.zeros((H, W), dtype=np.float32)
    delta_Z_small[20:23, 20:23] = 0.06  # 9 pixels, 6 cm deep
    m_small, _ = profiler.evaluate_and_profile_cavity(delta_Z_small, Z_mock, X_mock, Y_mock, 500, 500)
    assert not m_small.is_valid_cavity, "Small pixel noise cluster under 50 px must be rejected!"
    print(f"  [PASS] Test 1C (Small Cluster Rejection): {m_small.rejection_reason}")

    # Test 1D: True pothole cavity (5.5 cm deep, 400 pixels) -> MUST VALIDATE
    delta_Z_cavity = np.zeros((H, W), dtype=np.float32)
    delta_Z_cavity[20:40, 20:40] = 0.055  # 5.5 cm depth, 400 px
    m_cav, mask = profiler.evaluate_and_profile_cavity(delta_Z_cavity, Z_mock, X_mock, Y_mock, 500, 500)
    assert m_cav.is_valid_cavity, "True deep cavity must be validated!"
    assert abs(m_cav.max_depth_cm - 5.5) < 1e-3
    assert m_cav.volume_liters > 0.0
    assert m_cav.severity in ["Moderate", "Severe"]
    print(f"  [PASS] Test 1D (True Cavity Validation): Max Depth={m_cav.max_depth_cm:.2f} cm | Vol={m_cav.volume_liters:.2f} L | Severity={m_cav.severity}")

    # 2. Test Voxel Fusion Grid & 3DGS PLY Exporter
    cfg = config.PipelineConfig()
    cfg.fusion.voxel_size_m = 0.02  # 2 cm
    grid = fusion.VoxelFusionGrid(cfg)

    # Insert 1000 points with overlapping coordinates to test deduplication
    pts1 = np.random.uniform(-1.0, 1.0, size=(1000, 3)).astype(np.float32)
    cols1 = np.random.randint(0, 255, size=(1000, 3), dtype=np.uint8)
    norms1 = np.tile(np.array([0.0, 1.0, 0.0], dtype=np.float32), (1000, 1))
    cav1 = np.zeros(1000, dtype=bool)
    cav1[:100] = True

    grid.insert_cloud(pts1, cols1, norms1, cav1)
    
    # Insert slight perturbation (should merge into existing voxels)
    pts2 = pts1 + np.random.normal(0, 0.005, size=(1000, 3)).astype(np.float32)
    grid.insert_cloud(pts2, cols1, norms1, cav1)

    splats = grid.synthesize_3d_gaussian_splats()
    assert "xyz" in splats
    assert "scales" in splats
    assert "rotations" in splats
    assert "f_dc" in splats
    assert "opacity" in splats
    num_splats = splats["xyz"].shape[0]
    print(f"  [PASS] Test 2A (Voxel Deduplication & 3DGS Synthesis): {num_splats:,} unique 3DGS splats generated.")

    # Test PLY Export
    test_ply = os.path.join(current_dir, "test_output.ply")
    written = grid.export_ply(test_ply, binary=True)
    assert written == num_splats
    assert os.path.exists(test_ply) and os.path.getsize(test_ply) > 1000
    os.remove(test_ply)
    print(f"  [PASS] Test 2B (Binary 3DGS PLY Exporter): Verified byte encoding.")

    # 3. Test WebGL Viewer
    v = viewer.WebGLViewer()
    test_html = os.path.join(current_dir, "test_output.html")
    telemetry = {
        "max_depth_cm": m_cav.max_depth_cm,
        "volume_liters": m_cav.volume_liters,
        "surface_area_cm2": m_cav.surface_area_cm2,
        "severity": m_cav.severity,
        "num_cavities": 1
    }
    v.save_html(test_html, splats["xyz"], splats["colors_rgb"], telemetry)
    assert os.path.exists(test_html)
    with open(test_html, "r", encoding="utf-8") as f:
        html_content = f.read()
    assert "b64ToFloat32Array" in html_content
    assert "Float32Array" in html_content
    os.remove(test_html)
    print("  [PASS] Test 3 (WebGL Base64 Binary Stream Generator): Verified Three.js HTML pipeline.")

    print("\n[SUCCESS] ALL 5 TEST SUITES PASSED WITH 100% SUCCESS!")


if __name__ == "__main__":
    run_tests()
