"""
Spatial Voxel-Grid Fusion, Gaussian Covariance Synthesis, and 3DGS PLY Exporter.
Deduplicates continuous multi-frame point clouds via spatial voxel hashing (2 cm grid)
and formats 3D Gaussian Splats with anisotropic ellipsoids along road surface normals.
"""

from typing import Dict, Tuple, List, Optional
import struct
import numpy as np

try:
    from .config import PipelineConfig, SplatConfig, FusionConfig
except ImportError:
    from config import PipelineConfig, SplatConfig, FusionConfig


def quaternion_from_vectors(u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """
    Computes unit quaternion [w, x, y, z] rotating vector u to vector v.
    Both u and v must be unit vectors [3].
    """
    dot = float(np.dot(u, v))
    if dot >= 0.999999:
        return np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float32)
    elif dot <= -0.999999:
        # 180 degree rotation: pick an orthogonal vector
        ortho = np.array([1.0, 0.0, 0.0], dtype=np.float32)
        if abs(u[0]) > 0.8:
            ortho = np.array([0.0, 1.0, 0.0], dtype=np.float32)
        axis = np.cross(u, ortho)
        axis = axis / np.linalg.norm(axis)
        return np.array([0.0, axis[0], axis[1], axis[2]], dtype=np.float32)
    else:
        w = np.sqrt((1.0 + dot) * 2.0)
        xyz = np.cross(u, v) / w
        return np.array([w * 0.5, xyz[0], xyz[1], xyz[2]], dtype=np.float32)


class VoxelFusionGrid:
    """
    Continuous Multi-Frame Voxel Hash Grid.
    Fuses keyframe point clouds into a metric spatial grid, deduplicating
    overlapping road surfaces within a 2 cm radius to prevent memory explosion.
    """
    def __init__(self, config: Optional[PipelineConfig] = None):
        self.config = config or PipelineConfig()
        self.fusion_cfg = self.config.fusion
        self.splat_cfg = self.config.splat
        self.voxel_size = self.fusion_cfg.voxel_size_m

        # Voxel storage dictionary:
        # key: (ix, iy, iz)
        # value: [sum_x, sum_y, sum_z, sum_nx, sum_ny, sum_nz, sum_r, sum_g, sum_b, count, is_cavity]
        self.grid: Dict[Tuple[int, int, int], List[float]] = {}

    def insert_cloud(
        self,
        points_world: np.ndarray,
        colors_rgb: np.ndarray,
        normals_world: Optional[np.ndarray] = None,
        cavity_mask: Optional[np.ndarray] = None
    ) -> int:
        """
        Inserts and fuses a frame's point cloud into the global voxel hash map.
        
        Args:
            points_world: [N, 3] float32 metric points in world coordinates
            colors_rgb: [N, 3] uint8 or float32 [0-255] RGB colors
            normals_world: [N, 3] float32 unit surface normals
            cavity_mask: [N] bool, True if point is part of a verified pothole cavity
            
        Returns:
            Current total number of unique voxels in the global model
        """
        if points_world.size == 0:
            return len(self.grid)

        N = points_world.shape[0]
        pts = points_world.astype(np.float64)
        cols = colors_rgb.astype(np.float64)
        
        if normals_world is not None and normals_world.shape[0] == N:
            norms = normals_world.astype(np.float64)
        else:
            # Default normal pointing up (+Y)
            norms = np.tile(np.array([0.0, 1.0, 0.0], dtype=np.float64), (N, 1))

        if cavity_mask is None:
            cavities = np.zeros(N, dtype=bool)
        else:
            cavities = cavity_mask

        # Compute voxel integer grid indices
        inv_v = 1.0 / self.voxel_size
        indices = np.floor(pts * inv_v).astype(np.int64)

        for i in range(N):
            key = (int(indices[i, 0]), int(indices[i, 1]), int(indices[i, 2]))
            is_cav = 1.0 if cavities[i] else 0.0

            if key in self.grid:
                entry = self.grid[key]
                entry[0] += pts[i, 0]
                entry[1] += pts[i, 1]
                entry[2] += pts[i, 2]
                entry[3] += norms[i, 0]
                entry[4] += norms[i, 1]
                entry[5] += norms[i, 2]
                entry[6] += cols[i, 0]
                entry[7] += cols[i, 1]
                entry[8] += cols[i, 2]
                entry[9] += 1.0
                if is_cav > 0.5:
                    entry[10] = 1.0  # Cavity label persists
            else:
                self.grid[key] = [
                    pts[i, 0], pts[i, 1], pts[i, 2],
                    norms[i, 0], norms[i, 1], norms[i, 2],
                    cols[i, 0], cols[i, 1], cols[i, 2],
                    1.0, is_cav
                ]

        return len(self.grid)

    def extract_fused_arrays(self) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """
        Extracts averaged voxel centers, surface normals, colors, and cavity tags.
        
        Returns:
            points: [M, 3] float32
            normals: [M, 3] float32
            colors: [M, 3] uint8
            is_cavity: [M] bool
        """
        M = len(self.grid)
        if M == 0:
            empty = np.array([], dtype=np.float32)
            return empty, empty, empty, np.array([], dtype=bool)

        points = np.zeros((M, 3), dtype=np.float32)
        normals = np.zeros((M, 3), dtype=np.float32)
        colors = np.zeros((M, 3), dtype=np.uint8)
        is_cavity = np.zeros(M, dtype=bool)

        for idx, (_, entry) in enumerate(self.grid.items()):
            count = entry[9]
            inv_c = 1.0 / count

            points[idx, 0] = entry[0] * inv_c
            points[idx, 1] = entry[1] * inv_c
            points[idx, 2] = entry[2] * inv_c

            nx = entry[3] * inv_c
            ny = entry[4] * inv_c
            nz = entry[5] * inv_c
            n_len = np.sqrt(nx * nx + ny * ny + nz * nz) + 1e-8
            normals[idx, 0] = nx / n_len
            normals[idx, 1] = ny / n_len
            normals[idx, 2] = nz / n_len

            colors[idx, 0] = int(np.clip(entry[6] * inv_c, 0, 255))
            colors[idx, 1] = int(np.clip(entry[7] * inv_c, 0, 255))
            colors[idx, 2] = int(np.clip(entry[8] * inv_c, 0, 255))

            is_cavity[idx] = (entry[10] > 0.5)

        return points, normals, colors, is_cavity

    def synthesize_3d_gaussian_splats(self) -> Dict[str, np.ndarray]:
        """
        Synthesizes standard 3D Gaussian Splat parameters:
        - Flat road: Anisotropic disc oriented with normal n (s_parallel ~= 2.5 cm, s_perp ~= 0.5 cm)
        - Pothole cavity: Small isotropic spheres (s ~= 1.0 cm) to preserve cavity depth
        - Opacity: High logit (~2.944)
        - Rotation: Unit quaternion [rot_0, rot_1, rot_2, rot_3]
        - Spherical Harmonics: f_dc_0, f_dc_1, f_dc_2
        """
        points, normals, colors, is_cavity = self.extract_fused_arrays()
        M = points.shape[0]

        if M == 0:
            return {}

        # 1. Spherical Harmonics 0th order (f_dc) from RGB [0, 255]
        SH_C0 = 0.28209479177387814
        f_dc = ((colors.astype(np.float32) / 255.0) - 0.5) / SH_C0

        # 2. Log-space Scales
        # Flat road: scale_0 = ln(s_par), scale_1 = ln(s_par), scale_2 = ln(s_perp)
        # Cavity: isotropic ln(s_cavity)
        ln_s_par = float(np.log(self.splat_cfg.scale_parallel_m))
        ln_s_perp = float(np.log(self.splat_cfg.scale_perp_m))
        ln_s_cav = float(np.log(self.splat_cfg.scale_cavity_m))

        scales = np.zeros((M, 3), dtype=np.float32)
        # Default road:
        scales[:, 0] = ln_s_par
        scales[:, 1] = ln_s_par
        scales[:, 2] = ln_s_perp
        # Cavity override:
        scales[is_cavity, :] = ln_s_cav

        # 3. Opacity in logit space
        opacities = np.full((M, 1), self.splat_cfg.opacity_logit, dtype=np.float32)

        # 4. Quaternions [rot_0, rot_1, rot_2, rot_3] (W, X, Y, Z)
        # Canonical normal for thin axis (scale_2) is (0, 0, 1)
        canonical_axis = np.array([0.0, 0.0, 1.0], dtype=np.float32)
        quats = np.zeros((M, 4), dtype=np.float32)

        for i in range(M):
            if is_cavity[i]:
                # Isotropic cavity splats have identity rotation
                quats[i] = [1.0, 0.0, 0.0, 0.0]
            else:
                n_i = normals[i]
                quats[i] = quaternion_from_vectors(canonical_axis, n_i)

        return {
            "xyz": points,
            "normals": normals,
            "f_dc": f_dc,
            "opacity": opacities,
            "scales": scales,
            "rotations": quats,
            "is_cavity": is_cavity,
            "colors_rgb": colors
        }

    def export_ply(self, file_path: str, binary: bool = True) -> int:
        """
        Exports the fused 3D Gaussian Splats into standard 3DGS PLY format.
        Compatible with SuperSplat, Three.js, and standard 3DGS renderers.
        
        Header properties:
        x, y, z, nx, ny, nz, f_dc_0, f_dc_1, f_dc_2, opacity,
        scale_0, scale_1, scale_2, rot_0, rot_1, rot_2, rot_3
        """
        splat_data = self.synthesize_3d_gaussian_splats()
        if not splat_data:
            print("Warning: Voxel grid is empty. Skipping PLY export.")
            return 0

        xyz = splat_data["xyz"]
        normals = splat_data["normals"]
        f_dc = splat_data["f_dc"]
        opacity = splat_data["opacity"]
        scales = splat_data["scales"]
        rots = splat_data["rotations"]
        num_points = xyz.shape[0]

        if binary:
            # High-speed binary little endian export
            header = f"""ply
format binary_little_endian 1.0
element vertex {num_points}
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
            # Pack binary buffer: 17 float32 fields per vertex = 68 bytes per point
            all_fields = np.hstack([
                xyz, normals, f_dc, opacity, scales, rots
            ]).astype(np.float32)

            with open(file_path, "wb") as f:
                f.write(header.encode("ascii"))
                f.write(all_fields.tobytes())

        else:
            # ASCII format
            header = f"""ply
format ascii 1.0
element vertex {num_points}
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
            all_fields = np.hstack([
                xyz, normals, f_dc, opacity, scales, rots
            ]).astype(np.float32)

            with open(file_path, "w", encoding="ascii") as f:
                f.write(header)
                np.savetxt(f, all_fields, fmt="%.4f " * 17)

        return num_points
