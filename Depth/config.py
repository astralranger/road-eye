"""
Configuration dataclasses for the 3D Road & Pothole Geometric Reconstruction Pipeline.
Encapsulates camera intrinsics, mounting geometry, RANSAC thresholds, gating logic,
Gaussian splatting parameters, and multi-frame voxel fusion parameters.
"""

from dataclasses import dataclass, field
from typing import Tuple, Optional


@dataclass
class CameraConfig:
    """Camera intrinsic and extrinsic mounting parameters."""
    # Physical height of the dashcam above the flat road surface in meters
    camera_height_m: float = 1.35
    
    # Intrinsic parameters (focal length and principal point in pixels)
    # If None, automatically derived from image dimensions via standard field-of-view heuristics
    fx: Optional[float] = None
    fy: Optional[float] = None
    cx: Optional[float] = None
    cy: Optional[float] = None
    
    # Normalized field of view multiplier when fx, fy are auto-estimated: fx = max(w, h) * fov_scale
    fov_scale: float = 0.8
    
    # Horizon pitch cut-off: Fraction of the top frame ignored (sky/far horizon, e.g. top 35%)
    horizon_cutoff_ratio: float = 0.35


@dataclass
class DepthModelConfig:
    """Depth Anything V2 model and inference configuration."""
    model_name: str = "depth-anything/Depth-Anything-V2-Base-hf"
    device: str = "cuda"  # Auto-falls back to cpu if unavailable
    
    # Downsample factor for back-projection to balance resolution and throughput
    # downsample=2 reduces 1080p to 540p for 3D cloud rendering (4x fewer points, >25 FPS)
    downsample_factor: int = 2
    
    # Depth Anything disparity inversion coefficients: Z_rel = 1.0 / (0.9 * d_norm + 0.07)
    inv_scale: float = 0.90
    inv_offset: float = 0.07
    epsilon: float = 1e-8


@dataclass
class RANSACConfig:
    """Border-anchored perimeter RANSAC ground plane fitting configuration."""
    # Fraction of outer border margin used to sample true road surface (10% - 12%)
    border_margin_ratio: float = 0.12
    
    # Maximum residual in metric meters for inlier classification in RANSAC
    residual_threshold_m: float = 0.02  # 2 cm inlier band
    
    # Minimum inlier ratio required to declare a valid fitted road plane
    min_inlier_ratio: float = 0.40
    
    # Maximum RANSAC trials
    max_trials: int = 200
    random_state: int = 42


@dataclass
class GatingConfig:
    """Deterministic 3D Cavity Gating parameters for false positive rejection."""
    # Minimum required physical depression depth to qualify as a cavity (in centimeters)
    # Rejects painted markings, oil stains, manhole covers, shadows, flat asphalt patches
    min_cavity_depth_cm: float = 2.5
    
    # Minimum connected component / cavity pixel count at downsampled resolution
    min_cavity_pixel_area: int = 50
    
    # Sensitivity factor k for adaptive threshold: T = median_dip + k * std_dev
    # Standard values: high=0.8, medium=1.5, low=2.5
    adaptive_k: float = 1.5
    
    # Hard noise floor in meters for delta Z thresholding
    noise_floor_m: float = 0.015  # 1.5 cm minimum threshold floor


@dataclass
class VolumetricConfig:
    """Volumetric analysis and severity classification."""
    # Severity classification depth thresholds in centimeters
    minor_depth_threshold_cm: float = 3.0     # < 3 cm -> Minor
    moderate_depth_threshold_cm: float = 6.0  # 3 - 6 cm -> Moderate, > 6 cm -> Severe
    
    # Liters threshold for hazardous cavity volume
    severe_volume_liters: float = 5.0


@dataclass
class SplatConfig:
    """3D Gaussian Splatting synthesis parameters."""
    # Tangential spread for flat road splats (in meters, e.g. 2.5 cm)
    scale_parallel_m: float = 0.025
    
    # Normal thickness for flat road splats (in meters, e.g. 0.5 cm)
    scale_perp_m: float = 0.005
    
    # Isotropic scale for pothole cavity splats (in meters, e.g. 1.0 cm)
    scale_cavity_m: float = 0.010
    
    # Opacity logit (logit(0.95) ~= 2.944)
    opacity_logit: float = 2.944
    
    # Thermal gradient color map for cavities:
    # Yellow rim [255, 230, 0] -> Deep Crimson pit [200, 0, 0]
    cavity_rim_rgb: Tuple[int, int, int] = (255, 230, 0)
    cavity_pit_rgb: Tuple[int, int, int] = (200, 10, 20)


@dataclass
class FusionConfig:
    """Global multi-frame trajectory fusion and spatial voxel hashing."""
    # Spatial voxel grid cell size in meters (e.g. 0.02 = 2 cm deduplication radius)
    voxel_size_m: float = 0.02
    
    # Maximum points retained in active point cloud before adaptive sub-sampling
    max_point_budget: int = 1_500_000
    
    # Keyframe sampling interval (e.g. process 1 in every N video frames)
    keyframe_step: int = 2
    
    # Minimum camera forward displacement (meters) to trigger keyframe fusion
    min_keyframe_distance_m: float = 0.20


@dataclass
class PipelineConfig:
    """Master pipeline configuration combining all modules."""
    camera: CameraConfig = field(default_factory=CameraConfig)
    depth: DepthModelConfig = field(default_factory=DepthModelConfig)
    ransac: RANSACConfig = field(default_factory=RANSACConfig)
    gating: GatingConfig = field(default_factory=GatingConfig)
    volumetric: VolumetricConfig = field(default_factory=VolumetricConfig)
    splat: SplatConfig = field(default_factory=SplatConfig)
    fusion: FusionConfig = field(default_factory=FusionConfig)
    
    # Visualization and export options
    export_ply: bool = True
    export_html_viewer: bool = True
    ply_binary_format: bool = True  # Binary is 5x faster and 4x smaller than ASCII
    output_dir: str = "reconstruction_outputs"
