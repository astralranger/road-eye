"""
Geometry & Volumetric Profiler:
Deterministic 3D Cavity Gating, implicit cavity masking, volumetric calculation,
cross-sectional profiling, and geometric severity classification.
"""

from typing import Dict, Any, Tuple, Optional
from dataclasses import dataclass
import numpy as np
import cv2

try:
    from .config import GatingConfig, VolumetricConfig, PipelineConfig
except ImportError:
    from config import GatingConfig, VolumetricConfig, PipelineConfig


@dataclass
class CavityMetrics:
    """Quantitative metric measurements of a verified 3D pothole cavity."""
    is_valid_cavity: bool
    rejection_reason: Optional[str]
    max_depth_cm: float
    mean_depth_cm: float
    surface_area_cm2: float
    volume_liters: float
    lci_score: float
    severity: str  # 'Minor', 'Moderate', 'Severe'
    deepest_point_uv: Tuple[int, int]
    deepest_point_xyz: Tuple[float, float, float]
    x_profile_cm: np.ndarray
    y_profile_cm: np.ndarray


class GeometryProfiler:
    """
    Computes sub-centimeter volumetric cavity profiles and rejects 2D false positives.
    Zero model retraining required; uses deterministic 3D geometric constraints.
    """
    def __init__(self, config: Optional[PipelineConfig] = None):
        self.config = config or PipelineConfig()
        self.gating_cfg = self.config.gating
        self.vol_cfg = self.config.volumetric

    def generate_implicit_cavity_mask(
        self,
        delta_Z: np.ndarray,
        sensitivity_k: Optional[float] = None
    ) -> Tuple[np.ndarray, float]:
        """
        Calculates zero-shot implicit 3D cavity mask:
        T = median_dip + k * std_dev
        Mask = delta_Z > max(noise_floor, T)
        """
        k = sensitivity_k if sensitivity_k is not None else self.gating_cfg.adaptive_k
        noise_floor = self.gating_cfg.noise_floor_m

        positive_dips = delta_Z[delta_Z > 0]
        max_dip = float(np.max(delta_Z)) if delta_Z.size > 0 else 0.0
        if len(positive_dips) > 0:
            median_dip = float(np.median(positive_dips))
            std_dev = float(np.std(positive_dips))
            adaptive_threshold = median_dip + (k * std_dev)
            if adaptive_threshold >= max_dip and max_dip > noise_floor:
                adaptive_threshold = max(noise_floor, max_dip * 0.5)
            else:
                adaptive_threshold = max(noise_floor, adaptive_threshold)
        else:
            adaptive_threshold = noise_floor

        cavity_mask = (delta_Z >= adaptive_threshold)

        # Morphological cleanup: remove isolated salt-and-pepper noise
        if np.any(cavity_mask):
            mask_uint8 = (cavity_mask.astype(np.uint8)) * 255
            kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
            cleaned = cv2.morphologyEx(mask_uint8, cv2.MORPH_OPEN, kernel)
            cleaned = cv2.morphologyEx(cleaned, cv2.MORPH_CLOSE, kernel)
            cavity_mask = (cleaned > 0)

        return cavity_mask, adaptive_threshold

    def evaluate_and_profile_cavity(
        self,
        delta_Z_m: np.ndarray,
        Z_metric: np.ndarray,
        X_metric: np.ndarray,
        Y_metric: np.ndarray,
        fx: float,
        fy: float
    ) -> Tuple[CavityMetrics, np.ndarray]:
        """
        Executes Deterministic 3D Cavity Gating:
        - If Max(Delta_Z) < 2.5 cm OR Area < 50 px -> DISCARD as Shadow/Patch.
        - Otherwise, compute exact physical volume (Liters), surface area (cm2), and severity.
        """
        cavity_mask, threshold_m = self.generate_implicit_cavity_mask(delta_Z_m)
        pixel_count = int(np.sum(cavity_mask))
        max_depth_m = float(np.max(delta_Z_m)) if delta_Z_m.size > 0 else 0.0
        max_depth_cm = max_depth_m * 100.0

        # --- Deterministic 3D Gating Logic ---
        min_depth_cm = self.gating_cfg.min_cavity_depth_cm
        min_area_px = self.gating_cfg.min_cavity_pixel_area

        if max_depth_cm < min_depth_cm:
            # Rejection: Too flat (< 2.5 cm deep), false positive 2D visual artifact
            metrics = CavityMetrics(
                is_valid_cavity=False,
                rejection_reason=f"Insufficient depth: {max_depth_cm:.2f} cm < threshold {min_depth_cm:.1f} cm (Flat/Shadow/Manhole)",
                max_depth_cm=max_depth_cm,
                mean_depth_cm=0.0,
                surface_area_cm2=0.0,
                volume_liters=0.0,
                lci_score=0.0,
                severity="Flat Patch / Rejected",
                deepest_point_uv=(0, 0),
                deepest_point_xyz=(0.0, 0.0, 0.0),
                x_profile_cm=np.array([]),
                y_profile_cm=np.array([])
            )
            return metrics, cavity_mask

        if pixel_count < min_area_px:
            # Rejection: Pixel cluster too small, sensor noise artifact
            metrics = CavityMetrics(
                is_valid_cavity=False,
                rejection_reason=f"Insufficient area: {pixel_count} px < threshold {min_area_px} px",
                max_depth_cm=max_depth_cm,
                mean_depth_cm=0.0,
                surface_area_cm2=0.0,
                volume_liters=0.0,
                lci_score=0.0,
                severity="Noise / Rejected",
                deepest_point_uv=(0, 0),
                deepest_point_xyz=(0.0, 0.0, 0.0),
                x_profile_cm=np.array([]),
                y_profile_cm=np.array([])
            )
            return metrics, cavity_mask

        # --- True Cavity Profile Computation ---
        cavity_depths_m = delta_Z_m[cavity_mask]
        mean_depth_cm = float(np.mean(cavity_depths_m) * 100.0)

        # Differential pixel surface area projection:
        # dA(u, v) = (Z / fx) * (Z / fy) in square meters
        Z_cavity = Z_metric[cavity_mask]
        dA_m2 = (Z_cavity / fx) * (Z_cavity / fy)
        
        # Surface area in cm2 (1 m2 = 10,000 cm2)
        surface_area_cm2 = float(np.sum(dA_m2) * 10000.0)

        # Physical volume in Liters:
        # V = sum(delta_Z * dA) in m3, 1 m3 = 1000 Liters
        volume_m3 = float(np.sum(cavity_depths_m * dA_m2))
        volume_liters = float(volume_m3 * 1000.0)

        # Localized Cavity Index (LCI)
        lci_score = float(np.sum(cavity_depths_m * 100.0))

        # Identify deepest pit coordinate (u_max, v_max)
        deepest_idx = np.argmax(delta_Z_m)
        deepest_v, deepest_u = np.unravel_index(deepest_idx, delta_Z_m.shape)
        deepest_xyz = (
            float(X_metric[deepest_v, deepest_u]),
            float(Y_metric[deepest_v, deepest_u]),
            float(Z_metric[deepest_v, deepest_u])
        )

        # Cross-sectional profiles through deepest point (in cm)
        x_profile_cm = delta_Z_m[deepest_v, :] * 100.0
        y_profile_cm = delta_Z_m[:, deepest_u] * 100.0

        # Geometric severity ranking
        if max_depth_cm >= self.vol_cfg.moderate_depth_threshold_cm or volume_liters >= self.vol_cfg.severe_volume_liters:
            severity = "Severe"
        elif max_depth_cm >= self.vol_cfg.minor_depth_threshold_cm:
            severity = "Moderate"
        else:
            severity = "Minor"

        metrics = CavityMetrics(
            is_valid_cavity=True,
            rejection_reason=None,
            max_depth_cm=max_depth_cm,
            mean_depth_cm=mean_depth_cm,
            surface_area_cm2=surface_area_cm2,
            volume_liters=volume_liters,
            lci_score=lci_score,
            severity=severity,
            deepest_point_uv=(int(deepest_u), int(deepest_v)),
            deepest_point_xyz=deepest_xyz,
            x_profile_cm=x_profile_cm,
            y_profile_cm=y_profile_cm
        )

        return metrics, cavity_mask
