"""
Visual Odometry & Multi-Frame Trajectory Estimator:
Estimates relative 6-DoF camera motion between consecutive dashcam video frames,
resolves monocular scale using road plane metrics, and tracks global vehicle trajectory.
"""

from typing import Tuple, Optional, List
import numpy as np
import cv2

try:
    from .config import PipelineConfig, CameraConfig
except ImportError:
    from config import PipelineConfig, CameraConfig


class VisualOdometryTracker:
    """
    Robust 6-DoF Visual Odometry tracker optimized for forward dashcam kinematics.
    Solves monocular scale ambiguity via ground-plane metric height constraints.
    """
    def __init__(self, config: Optional[PipelineConfig] = None):
        self.config = config or PipelineConfig()
        self.cam_cfg = self.config.camera

        # Feature extractor for frame-to-frame matching
        self.orb = cv2.ORB_create(
            nfeatures=1500,
            scaleFactor=1.2,
            nlevels=8,
            edgeThreshold=15,
            fastThreshold=20
        )
        self.bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)

        # Global accumulated trajectory state
        # World frame is anchored at frame 0 camera pose (R = Eye, t = 0)
        self.R_world: np.ndarray = np.eye(3, dtype=np.float64)
        self.t_world: np.ndarray = np.zeros((3, 1), dtype=np.float64)
        self.trajectory_history: List[np.ndarray] = [self.t_world.copy()]

        # Cache of previous frame data
        self.prev_gray: Optional[np.ndarray] = None
        self.prev_kp: Optional[List[cv2.KeyPoint]] = None
        self.prev_des: Optional[np.ndarray] = None
        self.prev_metric_scale: float = 1.0

    def estimate_relative_pose(
        self,
        current_frame_bgr: np.ndarray,
        fx: float,
        fy: float,
        cx: float,
        cy: float,
        metric_scale_factor: float
    ) -> Tuple[np.ndarray, np.ndarray, bool]:
        """
        Estimates relative pose [R_rel, t_rel] from previous to current frame.
        
        Args:
            current_frame_bgr: Current image frame
            fx, fy, cx, cy: Camera intrinsics
            metric_scale_factor: Scale factor s = H_cam / D_rel
            
        Returns:
            R_rel (3x3), t_rel (3x1 metric meters), is_valid (bool)
        """
        curr_gray = cv2.cvtColor(current_frame_bgr, cv2.COLOR_BGR2GRAY)
        
        # Mask out top horizon/sky to match features strictly on road and stable scene elements
        h, w = curr_gray.shape
        mask = np.zeros((h, w), dtype=np.uint8)
        horizon_y = int(h * self.cam_cfg.horizon_cutoff_ratio)
        mask[horizon_y:, :] = 255

        curr_kp, curr_des = self.orb.detectAndCompute(curr_gray, mask=mask)

        # Handle first frame initialization
        if self.prev_gray is None or self.prev_des is None or curr_des is None or len(curr_kp) < 30:
            self.prev_gray = curr_gray
            self.prev_kp = curr_kp
            self.prev_des = curr_des
            self.prev_metric_scale = metric_scale_factor
            return np.eye(3, dtype=np.float64), np.zeros((3, 1), dtype=np.float64), True

        # Match ORB descriptors between consecutive frames
        matches = self.bf.match(self.prev_des, curr_des)
        matches = sorted(matches, key=lambda x: x.distance)

        # Retain top 200 matches
        good_matches = matches[:min(200, len(matches))]

        if len(good_matches) < 15:
            # Fallback for low texture: assume forward vehicle translation
            R_rel = np.eye(3, dtype=np.float64)
            t_rel = np.array([[0.0], [0.0], [0.4]], dtype=np.float64) # 0.4m nominal forward step
            self._update_state(curr_gray, curr_kp, curr_des, metric_scale_factor, R_rel, t_rel)
            return R_rel, t_rel, False

        pts_prev = np.float32([self.prev_kp[m.queryIdx].pt for m in good_matches])
        pts_curr = np.float32([curr_kp[m.trainIdx].pt for m in good_matches])

        K = np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)

        # Compute Essential Matrix with RANSAC
        E, inlier_mask = cv2.findEssentialMat(
            pts_curr, pts_prev, K,
            method=cv2.RANSAC,
            prob=0.999,
            threshold=1.5
        )

        if E is None or E.shape != (3, 3):
            # Fallback
            R_rel = np.eye(3, dtype=np.float64)
            t_rel = np.array([[0.0], [0.0], [0.4]], dtype=np.float64)
            self._update_state(curr_gray, curr_kp, curr_des, metric_scale_factor, R_rel, t_rel)
            return R_rel, t_rel, False

        _, R_est, t_est, mask_pose = cv2.recoverPose(E, pts_curr, pts_prev, K)

        # Scale resolution:
        # Essential matrix translation unit vector ||t_est|| = 1.
        # Scale by ratio of physical road ground plane and forward parallax
        mean_scale = (metric_scale_factor + self.prev_metric_scale) / 2.0
        
        # Calculate nominal forward displacement (positive along camera Z)
        # Vehicles predominantly travel forward (+Z)
        forward_component = float(t_est[2, 0])
        if forward_component < 0:
            # Invert if sign is oriented towards backwards motion
            t_est = -t_est

        # Metric translation step (e.g. 0.3 - 1.2 m per frame at 30-50 km/h)
        step_metric = float(np.clip(mean_scale * 0.25, 0.15, 1.5))
        t_rel = t_est * step_metric

        self._update_state(curr_gray, curr_kp, curr_des, metric_scale_factor, R_est, t_rel)
        return R_est, t_rel, True

    def _update_state(
        self,
        curr_gray: np.ndarray,
        curr_kp: List[cv2.KeyPoint],
        curr_des: np.ndarray,
        metric_scale: float,
        R_rel: np.ndarray,
        t_rel: np.ndarray
    ):
        """Accumulates relative motion into global world pose."""
        # Update world pose: T_world = T_world * T_rel
        # t_world = t_world + R_world * t_rel
        # R_world = R_world * R_rel
        self.t_world = self.t_world + (self.R_world @ t_rel)
        self.R_world = self.R_world @ R_rel
        self.trajectory_history.append(self.t_world.copy())

        self.prev_gray = curr_gray
        self.prev_kp = curr_kp
        self.prev_des = curr_des
        self.prev_metric_scale = metric_scale

    def transform_points_to_world(
        self,
        points_camera: np.ndarray,
        normals_camera: Optional[np.ndarray] = None
    ) -> Tuple[np.ndarray, Optional[np.ndarray]]:
        """
        Transforms 3D points and normal vectors from current camera frame to global world coordinate frame:
        P_world = R_world * P_camera + t_world
        n_world = R_world * n_camera
        """
        if points_camera.size == 0:
            return points_camera, normals_camera

        # points_camera is [N, 3]
        pts_world = (points_camera @ self.R_world.T) + self.t_world.ravel()

        norms_world = None
        if normals_camera is not None and normals_camera.size > 0:
            norms_world = normals_camera @ self.R_world.T
            # Re-normalize
            norms_len = np.linalg.norm(norms_world, axis=-1, keepdims=True) + 1e-8
            norms_world = norms_world / norms_len

        return pts_world.astype(np.float32), norms_world.astype(np.float32) if norms_world is not None else None
