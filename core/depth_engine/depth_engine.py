"""
Depth Engine: Monocular depth estimation, disparity-to-distance inversion,
perimeter-anchored RANSAC plane fitting, and physical metric scale calibration via H_cam.
"""

from typing import Tuple, Dict, Any, Optional
import os
import numpy as np
import torch
import cv2
from PIL import Image
from sklearn.linear_model import RANSACRegressor
from transformers import pipeline

try:
    from .config import PipelineConfig, CameraConfig, DepthModelConfig, RANSACConfig
except ImportError:
    from config import PipelineConfig, CameraConfig, DepthModelConfig, RANSACConfig


class DepthEngine:
    """
    Production-grade depth estimation and metric 3D back-projection engine.
    Applies proven physical formulas from depth_anything_v3.py without retraining.
    """
    def __init__(self, config: Optional[PipelineConfig] = None):
        self.config = config or PipelineConfig()
        self.cam_cfg = self.config.camera
        self.depth_cfg = self.config.depth
        self.ransac_cfg = self.config.ransac
        
        # Determine compute device
        if self.depth_cfg.device == "cuda" and not torch.cuda.is_available():
            self.device = -1
            self.device_str = "cpu"
        elif self.depth_cfg.device == "cuda":
            self.device = 0
            self.device_str = "cuda"
        else:
            self.device = -1
            self.device_str = "cpu"

        # Initialize Hugging Face pipeline for Depth Anything V2 (frozen)
        self.pipeline = pipeline(
            task="depth-estimation",
            model=self.depth_cfg.model_name,
            device=self.device
        )

    def infer_depth_map(self, image_rgb: np.ndarray) -> np.ndarray:
        """
        Executes Depth Anything V2 once on the full video frame.
        
        Args:
            image_rgb: Input frame in RGB format [H, W, 3], uint8
            
        Returns:
            disparity_map: Continuous relative inverse depth [H, W], float32
        """
        pil_img = Image.fromarray(image_rgb)
        result = self.pipeline(pil_img)
        disparity_map = np.array(result["depth"]).astype(np.float32)
        return disparity_map

    def disparity_to_relative_distance(self, disparity_map: np.ndarray) -> np.ndarray:
        """
        Inverts disparity into projective distance Z_rel to eliminate the 'funnel' distortion:
        d_norm = (d - d_min) / (d_max - d_min + eps)
        Z_rel = 1.0 / (0.9 * d_norm + 0.07)
        """
        d_min = float(np.min(disparity_map))
        d_max = float(np.max(disparity_map))
        eps = self.depth_cfg.epsilon
        
        disp_norm = (disparity_map - d_min) / (d_max - d_min + eps)
        Z_rel = 1.0 / (self.depth_cfg.inv_scale * disp_norm + self.depth_cfg.inv_offset)
        return Z_rel.astype(np.float32)

    def backproject_to_3d(
        self,
        Z: np.ndarray,
        width: int,
        height: int,
        downsample: int = 1
    ) -> Tuple[np.ndarray, np.ndarray, np.ndarray, float, float, float, float]:
        """
        Ray back-projection from 2D pixel coordinates to 3D Cartesian coordinates:
        X = (u - c_x) * Z / f_x
        Y = -(v - c_y) * Z / f_y  (Y is inverted so +Y points UP)
        
        Returns:
            X, Y, Z coordinates arrays and camera intrinsics (fx, fy, cx, cy)
        """
        if downsample > 1:
            Z_sub = Z[::downsample, ::downsample]
            h, w = Z_sub.shape
            scale_factor = 1.0 / downsample
        else:
            Z_sub = Z
            h, w = height, width
            scale_factor = 1.0

        # Estimate intrinsics if not explicitly provided
        fx = (self.cam_cfg.fx * scale_factor) if self.cam_cfg.fx else max(w, h) * self.cam_cfg.fov_scale
        fy = (self.cam_cfg.fy * scale_factor) if self.cam_cfg.fy else max(w, h) * self.cam_cfg.fov_scale
        cx = (self.cam_cfg.cx * scale_factor) if self.cam_cfg.cx else w / 2.0
        cy = (self.cam_cfg.cy * scale_factor) if self.cam_cfg.cy else h / 2.0

        u, v = np.meshgrid(np.arange(w), np.arange(h))
        X = (u - cx) * Z_sub / fx
        Y = -(v - cy) * Z_sub / fy

        return X, Y, Z_sub, fx, fy, cx, cy

    def fit_perimeter_ransac_plane(
        self,
        X_crop: np.ndarray,
        Y_crop: np.ndarray,
        Z_crop: np.ndarray,
        border_ratio: Optional[float] = None
    ) -> Dict[str, Any]:
        """
        Fits baseline ground plane strictly on outer perimeter margin pixels (outer 10%-12%).
        Excludes central cavity to ensure depressions do NOT drag down the road plane.
        
        Fits plane equation: a * X + b * Y - Z + c = 0  =>  Z_pred = a * X + b * Y + c
        """
        h, w = Z_crop.shape
        margin = border_ratio if border_ratio is not None else self.ransac_cfg.border_margin_ratio
        border_w = max(2, int(w * margin))
        border_h = max(2, int(h * margin))

        # Generate perimeter boolean mask
        perimeter_mask = np.zeros((h, w), dtype=bool)
        perimeter_mask[:border_h, :] = True
        perimeter_mask[-border_h:, :] = True
        perimeter_mask[:, :border_w] = True
        perimeter_mask[:, -border_w:] = True

        valid = ~np.isnan(Z_crop) & ~np.isinf(Z_crop)
        train_mask = perimeter_mask & valid

        if np.sum(train_mask) < 20:
            # Fallback if crop is too small: use all valid pixels
            train_mask = valid

        X_train = np.column_stack((X_crop[train_mask], Y_crop[train_mask]))
        Z_train = Z_crop[train_mask]

        ransac = RANSACRegressor(
            residual_threshold=self.ransac_cfg.residual_threshold_m,
            max_trials=self.ransac_cfg.max_trials,
            random_state=self.ransac_cfg.random_state
        )
        ransac.fit(X_train, Z_train)

        # Retrieve plane coefficients: Z = a*X + b*Y + c
        a, b = ransac.estimator_.coef_
        c = float(ransac.estimator_.intercept_)

        # Plane normal vector: [a, b, -1]
        # Invert if normal does not point upward (+Y)
        norm_len = float(np.sqrt(a * a + b * b + 1.0))
        n_x, n_y, n_z = a / norm_len, b / norm_len, -1.0 / norm_len
        
        # Ensure unit normal points upwards into upper hemisphere (+Y)
        if n_y < 0:
            n_x, n_y, n_z = -n_x, -n_y, -n_z
            plane_d = -c / norm_len
        else:
            plane_d = c / norm_len

        # Relative perpendicular distance from camera origin (0,0,0) to road plane
        # D_rel = |c| / ||n||
        D_rel = abs(c) / norm_len

        # Predict baseline ground plane over entire crop grid
        full_grid = np.column_stack((X_crop.ravel(), Y_crop.ravel()))
        Z_baseline = ransac.predict(full_grid).reshape(h, w)

        return {
            "a": a,
            "b": b,
            "c": c,
            "normal": np.array([n_x, n_y, n_z], dtype=np.float32),
            "D_rel": D_rel,
            "Z_baseline": Z_baseline,
            "inlier_mask": train_mask
        }

    def calibrate_metric_scale(self, D_rel: float) -> float:
        """
        Computes closed-form metric scale factor from known physical mounting height H_cam:
        s = H_cam / D_rel
        P_metric = s * P_rel
        """
        H_cam = self.cam_cfg.camera_height_m
        if D_rel <= 1e-6:
            return 1.0
        scale = H_cam / D_rel
        return float(scale)

    def compute_metric_cavity_depth(
        self,
        Z_metric: np.ndarray,
        Z_baseline_metric: np.ndarray
    ) -> np.ndarray:
        """
        Calculates physical depression depth:
        Delta_Z = max(0, Z - Z_baseline)
        In distance coords, cavity points are further from camera than baseline road surface.
        Positive values indicate true physical depth below the drivable road surface.
        """
        delta_Z = Z_metric - Z_baseline_metric
        delta_Z = np.maximum(0.0, delta_Z)
        return delta_Z.astype(np.float32)

    def compute_road_alignment_matrix(self, normal: np.ndarray) -> np.ndarray:
        """
        Computes 3x3 rotation matrix R that aligns the road plane normal vector
        to point vertically along the +Y axis [0, 1, 0].
        Uses Rodrigues formula.
        """
        n = normal / (np.linalg.norm(normal) + 1e-8)
        target = np.array([0.0, 1.0, 0.0], dtype=np.float32)

        dot = float(np.dot(n, target))
        if dot > 0.9999:
            return np.eye(3, dtype=np.float32)
        elif dot < -0.9999:
            # 180 degree flip around X axis
            return np.diag([1.0, -1.0, -1.0]).astype(np.float32)

        v = np.cross(n, target)
        s = np.linalg.norm(v)
        c = dot
        vx = np.array([
            [0, -v[2], v[1]],
            [v[2], 0, -v[0]],
            [-v[1], v[0], 0]
        ], dtype=np.float32)

        R = np.eye(3, dtype=np.float32) + vx + (vx @ vx) * ((1.0 - c) / (s * s + 1e-8))
        return R.astype(np.float32)

    def sculpt_cavity_depression(
        self,
        points: np.ndarray,
        normal: np.ndarray,
        delta_Z: np.ndarray,
        mask: np.ndarray
    ) -> np.ndarray:
        """
        Physically displaces points identified as pothole cavity downwards along
        the negative road normal (-n) by delta_Z.
        Produces realistic 3D bowl depressions matching physical reality.
        """
        sculpted = points.copy()
        if not np.any(mask):
            return sculpted

        n = normal / (np.linalg.norm(normal) + 1e-8)
        # Displace along -normal
        cav_indices = np.where(mask.ravel())[0] if mask.ndim > 1 else np.where(mask)[0]
        flat_delta = delta_Z.ravel()[cav_indices] if delta_Z.ndim > 1 else delta_Z[cav_indices]

        sculpted[cav_indices] -= np.outer(flat_delta, n)
        return sculpted

    def apply_thermal_cavity_colormap(
        self,
        rgb_crop: np.ndarray,
        delta_Z: np.ndarray,
        cavity_mask: np.ndarray,
        dynamic_threshold: Optional[float] = None
    ) -> np.ndarray:
        """
        Applies high-contrast thermal gradient on cavity pixels matching depth_anything_v3.py:
        Yellow rim [255, 230, 0] -> Vibrant Orange -> Deep Crimson red pit [200, 10, 20].
        Non-cavity road pixels retain their natural RGB texture.
        """
        output_rgb = rgb_crop.copy()
        if not np.any(cavity_mask):
            return output_rgb

        cavity_depths = delta_Z[cavity_mask]
        t_min = dynamic_threshold if dynamic_threshold is not None else float(np.min(cavity_depths))
        max_depth = float(np.percentile(cavity_depths, 98))

        denom = max_depth - t_min + 1e-6
        norm_depth = np.clip((cavity_depths - t_min) / denom, 0.0, 1.0)

        # Thermal gradient interpolation: Yellow -> Orange -> Crimson Red
        # Rim: [255, 230, 0], Mid: [255, 100, 0], Pit: [200, 10, 20]
        r = np.full_like(norm_depth, 255.0)
        g = 230.0 * (1.0 - norm_depth)
        b = np.zeros_like(norm_depth)

        # Deepest 30% transitions from orange/red to deep crimson
        deep_mask = norm_depth > 0.7
        if np.any(deep_mask):
            deep_ratio = (norm_depth[deep_mask] - 0.7) / 0.3
            r[deep_mask] = 255.0 - (55.0 * deep_ratio)
            g[deep_mask] = np.maximum(0.0, g[deep_mask] * (1.0 - deep_ratio))
            b[deep_mask] = 20.0 * deep_ratio

        colored_cavity = np.column_stack((r, g, b)).astype(np.uint8)
        output_rgb[cavity_mask] = colored_cavity

        return output_rgb

    def export_3dgs_ply(
        self,
        ply_path: str,
        points_xyz: np.ndarray,
        colors_rgb: np.ndarray,
        normals: Optional[np.ndarray] = None,
        scale_val: float = -5.5,
        opacity_val: float = 3.0
    ) -> int:
        """
        Exports true 3D Gaussian Splats PLY file with full anisotropic attributes:
        Positions (x, y, z), Normals (nx, ny, nz), Spherical Harmonics (f_dc_0, f_dc_1, f_dc_2),
        Opacity, Log Scale (scale_0, scale_1, scale_2), and Rotation Quaternion (rot_0, rot_1, rot_2, rot_3).
        Compatible with standard 3DGS viewers (Splatfacto, WebGL splat viewers, SuperSplat, MeshLab).
        """
        valid = ~np.isnan(points_xyz).any(axis=1) & ~np.isinf(points_xyz).any(axis=1)
        pts = points_xyz[valid].astype(np.float32)
        cols = colors_rgb[valid].astype(np.float32)
        num_pts = pts.shape[0]

        if num_pts == 0:
            return 0

        if cols.max() > 1.0:
            cols = cols / 255.0

        # Spherical Harmonics Zero-Order (f_dc)
        SH_C0 = 0.28209479177387814
        f_dc_0 = (cols[:, 0] - 0.5) / SH_C0
        f_dc_1 = (cols[:, 1] - 0.5) / SH_C0
        f_dc_2 = (cols[:, 2] - 0.5) / SH_C0

        if normals is not None and len(normals) == len(pts):
            norms = normals[valid].astype(np.float32)
        else:
            norms = np.zeros((num_pts, 3), dtype=np.float32)
            norms[:, 1] = 1.0  # Default up normal

        scale = np.full(num_pts, scale_val, dtype=np.float32)
        opacity = np.full(num_pts, opacity_val, dtype=np.float32)
        rot_0 = np.ones(num_pts, dtype=np.float32)
        rot_123 = np.zeros(num_pts, dtype=np.float32)

        os.makedirs(os.path.dirname(os.path.abspath(ply_path)), exist_ok=True)
        header = f"""ply
format ascii 1.0
element vertex {num_pts}
property float x
property float y
property float z
property float nx
property float ny
property float nz
property float f_dc_0
property float f_dc_1
property float f_dc_2
property float opacity
property float scale_0
property float scale_1
property float scale_2
property float rot_0
property float rot_1
property float rot_2
property float rot_3
end_header
"""
        data = np.column_stack((
            pts[:, 0], pts[:, 1], pts[:, 2],
            norms[:, 0], norms[:, 1], norms[:, 2],
            f_dc_0, f_dc_1, f_dc_2,
            opacity,
            scale, scale, scale,
            rot_0, rot_123, rot_123, rot_123
        ))

        with open(ply_path, "w") as f:
            f.write(header)
            np.savetxt(f, data, fmt="%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f")

        return num_pts

