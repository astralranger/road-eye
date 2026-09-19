"""
Depth: Production 3D Road & Pothole Geometric Reconstruction Pipeline.
Metric 3D point cloud & Gaussian Splat reconstruction from monocular dashcam video and 2D bounding boxes.
"""

from .config import (
    CameraConfig,
    DepthModelConfig,
    RANSACConfig,
    GatingConfig,
    VolumetricConfig,
    SplatConfig,
    FusionConfig,
    PipelineConfig
)
from .depth_engine import DepthEngine
from .detector import RFDETRDetector, DetectionBox
from .geometry import GeometryProfiler, CavityMetrics
from .odometry import VisualOdometryTracker
from .fusion import VoxelFusionGrid, quaternion_from_vectors
from .viewer import WebGLViewer
from .pipeline import RoadReconstructionPipeline

__all__ = [
    "CameraConfig",
    "DepthModelConfig",
    "RANSACConfig",
    "GatingConfig",
    "VolumetricConfig",
    "SplatConfig",
    "FusionConfig",
    "PipelineConfig",
    "DepthEngine",
    "RFDETRDetector",
    "DetectionBox",
    "GeometryProfiler",
    "CavityMetrics",
    "VisualOdometryTracker",
    "VoxelFusionGrid",
    "quaternion_from_vectors",
    "WebGLViewer",
    "RoadReconstructionPipeline"
]
