# 🛣️ Production 3D Road & Pothole Geometric Reconstruction Pipeline

High-throughput, zero-retraining Computer Vision and 3D Reconstruction pipeline for monocular road dashcam videos (`.mp4`) and 2D bounding boxes from frozen `RF-DETR`.

---

## 🌟 Key Capabilities

1. **Zero-Retraining "Pruned Cascade"**: `Depth Anything V2` and `RF-DETR` remain 100% frozen.
2. **Metric Distance Inversion**: Affine-invariant relative disparity is inverted into projective Cartesian distance, eliminating the monocular "funnel" pinching artifact.
3. **Perimeter-Anchored RANSAC**: Fits baseline ground planes strictly on the outer 10%–12% margin pixels to prevent cavity depressions from skewing the road plane.
4. **Physical Scale Calibration via $H_{\text{cam}}$**: Exact closed-form scale calibration from physical mounting height $H_{\text{cam}}$ (default: $1.35\,\text{m}$):
   $$s = \frac{H_{\text{cam}}}{D_{\text{rel}}}, \quad \mathbf{P}_{\text{metric}} = s \cdot \mathbf{P}_{\text{rel}}$$
5. **Deterministic 3D Cavity Gating**:
   $$\text{If } \max(\Delta Z) < 2.5\,\text{cm} \quad \text{OR} \quad \text{Area} < 50\,\text{px} \implies \text{REJECT (Shadow / Flat patch / Manhole)}$$
6. **Volumetric Cavity Quantification**: Calculates maximum depth (cm), mean depth (cm), surface area ($\text{cm}^2$), and physical volume in **Liters**.
7. **Continuous Visual Odometry & Voxel Hashing**: Tracks forward vehicle motion via Essential matrix and fuses multi-frame points into a metric $2\,\text{cm}$ spatial voxel grid.
8. **Standard 3D Gaussian Splats (3DGS PLY)**: Exports compliant binary/ASCII PLY files with surface-normal aligned anisotropic ellipsoids for road splats ($s_{\parallel} \approx 2.5\,\text{cm}, s_{\perp} \approx 0.5\,\text{cm}$) and isotropic splats for cavities ($s \approx 1.0\,\text{cm}$).
9. **High-Performance Three.js WebGL Viewer**: Zero-lag browser visualization using Base64-encoded `Float32Array` binary buffers with interactive telemetry HUD.

---

## 📁 Package Architecture

```
Depth/
├── config.py          # Dataclasses: Camera, Depth, RANSAC, Gating, Splat, Fusion configs
├── depth_engine.py    # Disparity inversion, metric scaling, perimeter RANSAC, thermal color mapper
├── detector.py        # 2D detector adapter (frozen RF-DETR or auto road ROI)
├── geometry.py        # Deterministic 3D cavity gating, volumetric profiling, and LCI calculation
├── odometry.py        # 6-DoF Visual Odometry with road-plane metric scale propagation
├── fusion.py          # 2 cm Voxel hash grid deduplication, 3DGS covariance synthesis & PLY exporter
├── viewer.py          # High-performance Three.js WebGL viewer with OrbitControls and HUD
├── pipeline.py        # End-to-end video pipeline orchestrator
├── run_pipeline.py    # CLI entry point with synthetic demo generator
└── README.md          # Complete documentation & usage guide
```

---

## 🚀 Quickstart & Execution

### 1. Run on an Input Dashcam Video
```bash
python Depth/run_pipeline.py --video "path/to/dashcam.mp4" --h_cam 1.35 --output_dir "outputs"
```

### 2. Run Self-Contained Synthetic Demo (Zero Setup)
```bash
python Depth/run_pipeline.py --demo --output_dir "demo_outputs"
```

### 3. Open the Interactive 3D WebGL Viewer
Simply open the generated `.html` file in Chrome, Firefox, Safari, or Edge:
```bash
start demo_outputs/synthetic_dashcam_3d_viewer.html
```

---

## 📐 Mathematical Specifications

### 1. Disparity to Metric Distance Inversion
$$d_{\text{norm}} = \frac{d - d_{\min}}{d_{\max} - d_{\min} + \epsilon}$$
$$Z_{\text{rel}} = \frac{1.0}{0.9 \cdot d_{\text{norm}} + 0.07}$$
$$X = \frac{(u - c_x) \cdot Z}{f_x}, \quad Y = -\frac{(v - c_y) \cdot Z}{f_y}$$

### 2. Perimeter Ground Plane Fitting & Scale
Plane equation: $a X + b Y - Z + c = 0$.
Unit normal: $\mathbf{n} = \frac{(a, b, -1)}{\sqrt{a^2 + b^2 + 1}}$.
Perpendicular distance to road: $D_{\text{rel}} = \frac{|c|}{\sqrt{a^2 + b^2 + 1}}$.
Metric scale factor:
$$s = \frac{H_{\text{cam}}}{D_{\text{rel}}}$$
Metric points: $\mathbf{P}_{\text{metric}} = s \cdot \mathbf{P}_{\text{rel}}$.

### 3. Cavity Depth & Volumetric Integration
$$\Delta Z = \max(0, Z_{\text{baseline}} - Z)$$
Differential area:
$$dA(u, v) = \left(\frac{Z(u, v)}{f_x}\right) \cdot \left(\frac{Z(u, v)}{f_y}\right) \quad [\text{m}^2]$$
Volume:
$$V_{\text{liters}} = \sum_{(u, v) \in \text{cavity}} \Delta Z(u, v) \cdot dA(u, v) \times 1000 \quad [\text{Liters}]$$

### 4. 3D Gaussian Splats Format
Each point in the exported PLY contains:
`x, y, z, nx, ny, nz, f_dc_0, f_dc_1, f_dc_2, opacity, scale_0, scale_1, scale_2, rot_0, rot_1, rot_2, rot_3`
- Road splats: $\text{scale}_0 = \ln(0.025)$, $\text{scale}_1 = \ln(0.025)$, $\text{scale}_2 = \ln(0.005)$, quaternion aligned with $\mathbf{n}$.
- Cavity splats: $\text{scale}_0 = \text{scale}_1 = \text{scale}_2 = \ln(0.010)$, thermal gradient coloring.
