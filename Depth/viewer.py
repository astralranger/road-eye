"""
High-Performance Three.js WebGL Canvas & Interactive Inline Viewer.
Renders metric 3D road surfaces and thermal pothole cavity highlights using
compact base64-encoded Float32Array binary buffers to eliminate JSON serialization latency.
"""

from typing import Optional, Dict, Any, List
import base64
import numpy as np

try:
    from IPython.display import HTML, display
    IPYTHON_AVAILABLE = True
except ImportError:
    IPYTHON_AVAILABLE = False


class WebGLViewer:
    """
    Generates interactive WebGL 3D point cloud and Gaussian viewer using Three.js.
    Uses binary byte buffers encoded in Base64 for instant browser deserialization.
    """
    def __init__(self, title: str = "Road Sense Pro 3D Surface Reconstruction"):
        self.title = title

    @staticmethod
    def _encode_float32_array(arr: np.ndarray) -> str:
        """Converts a numpy float32 array directly to a compact Base64 binary string."""
        contiguous = np.ascontiguousarray(arr, dtype=np.float32)
        return base64.b64encode(contiguous.tobytes()).decode("ascii")

    def build_html_content(
        self,
        points_xyz: np.ndarray,
        colors_rgb: np.ndarray,
        telemetry: Optional[Dict[str, Any]] = None,
        max_points: int = 500_000
    ) -> str:
        """
        Builds self-contained standalone HTML and JavaScript Three.js viewer.
        
        Args:
            points_xyz: [N, 3] float32 metric coordinates (X, Y, Z)
            colors_rgb: [N, 3] float32 [0.0-1.0] or uint8 [0-255] color coordinates
            telemetry: Optional dictionary of volumetric stats (volume, max_depth, severity)
            max_points: Point budget cap to guarantee 60 FPS rendering in WebGL
        """
        N = points_xyz.shape[0]
        if N > max_points:
            sub_step = int(np.ceil(N / max_points))
            pts_sub = points_xyz[::sub_step]
            cols_sub = colors_rgb[::sub_step]
        else:
            pts_sub = points_xyz
            cols_sub = colors_rgb

        # Normalize colors to float32 [0.0, 1.0]
        if cols_sub.dtype == np.uint8:
            cols_norm = (cols_sub.astype(np.float32) / 255.0)
        else:
            cols_norm = np.clip(cols_sub.astype(np.float32), 0.0, 1.0)

        # Flatten into contiguous float32 buffers
        flat_positions = pts_sub.ravel().astype(np.float32)
        flat_colors = cols_norm.ravel().astype(np.float32)

        b64_positions = self._encode_float32_array(flat_positions)
        b64_colors = self._encode_float32_array(flat_colors)

        # Parse telemetry
        telemetry = telemetry or {}
        max_depth_cm = telemetry.get("max_depth_cm", 0.0)
        volume_liters = telemetry.get("volume_liters", 0.0)
        surface_area_cm2 = telemetry.get("surface_area_cm2", 0.0)
        severity = telemetry.get("severity", "Nominal")
        num_cavities = telemetry.get("num_cavities", 0)
        fps_target = telemetry.get("fps", 30)
        focus_target = telemetry.get("focus_target", [0.0, 0.0, 0.0])
        ply_filename = telemetry.get("ply_filename", "pothole_3d_splat.ply")

        severity_color = "#22c55e"  # Green
        if severity == "Severe":
            severity_color = "#ef4444"  # Red
        elif severity == "Moderate":
            severity_color = "#f59e0b"  # Amber

        html_template = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>{self.title}</title>
    <style>
        body {{
            margin: 0;
            padding: 0;
            overflow: hidden;
            background-color: #0b0f19;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            color: #f3f4f6;
        }}
        #canvas-container {{
            width: 100vw;
            height: 100vh;
            position: absolute;
            top: 0;
            left: 0;
        }}
        .hud-panel {{
            position: absolute;
            top: 20px;
            left: 20px;
            background: rgba(17, 24, 39, 0.85);
            backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 12px;
            padding: 16px 20px;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
            pointer-events: auto;
            z-index: 10;
            min-width: 280px;
        }}
        .hud-title {{
            font-size: 14px;
            font-weight: 700;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: #38bdf8;
            margin-bottom: 12px;
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .metric-row {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 13px;
            margin-bottom: 8px;
        }}
        .metric-label {{
            color: #9ca3af;
        }}
        .metric-val {{
            font-weight: 600;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        }}
        .severity-badge {{
            display: inline-block;
            padding: 2px 8px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 700;
            background: {severity_color}22;
            color: {severity_color};
            border: 1px solid {severity_color}66;
        }}
        .controls-panel {{
            position: absolute;
            bottom: 24px;
            left: 50%;
            transform: translateX(-50%);
            background: rgba(17, 24, 39, 0.85);
            backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 30px;
            padding: 8px 24px;
            display: flex;
            gap: 16px;
            align-items: center;
            z-index: 10;
        }}
        .ctrl-btn {{
            background: #1e293b;
            color: #f8fafc;
            border: 1px solid #334155;
            padding: 6px 14px;
            border-radius: 20px;
            cursor: pointer;
            font-size: 12px;
            font-weight: 600;
            transition: all 0.2s ease;
        }}
        .ctrl-btn:hover {{
            background: #38bdf8;
            color: #0f172a;
        }}
        .legend-bar {{
            position: absolute;
            bottom: 24px;
            right: 24px;
            background: rgba(17, 24, 39, 0.85);
            backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 12px;
            padding: 12px 16px;
            z-index: 10;
            font-size: 11px;
        }}
        .gradient-box {{
            width: 140px;
            height: 10px;
            border-radius: 4px;
            background: linear-gradient(to right, #ffe600, #c80a14);
            margin: 6px 0;
        }}
    </style>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
</head>
<body>
    <div id="canvas-container"></div>

    <div class="hud-panel">
        <div class="hud-title">
            <span>&#9889;</span> 3D METRIC TELEMETRY HUD
        </div>
        <div class="metric-row">
            <span class="metric-label">Severity Level:</span>
            <span class="severity-badge">{severity}</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Max Cavity Depth (&Delta;Z):</span>
            <span class="metric-val">{max_depth_cm:.2f} cm</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Cavity Volume:</span>
            <span class="metric-val">{volume_liters:.2f} Liters</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Surface Area:</span>
            <span class="metric-val">{surface_area_cm2:.1f} cm&sup2;</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Cavities Detected:</span>
            <span class="metric-val">{num_cavities}</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Total Points Rendered:</span>
            <span class="metric-val">{pts_sub.shape[0]:,}</span>
        </div>
    </div>

    <div class="controls-panel">
        <button class="ctrl-btn" id="btn-perspective">&#128065; Perspective 3D</button>
        <button class="ctrl-btn" id="btn-side">&#128208; Side Profile (Cross-Section)</button>
        <button class="ctrl-btn" id="btn-focus">&#128269; Focus Pothole</button>
        <button class="ctrl-btn" id="btn-top">&#128747; Top Down (Bird's Eye)</button>
        <button class="ctrl-btn" id="btn-reset">&#8634; Reset</button>
        <button class="ctrl-btn" id="btn-download">&#11015; Download PLY</button>
        <label style="font-size: 12px; color: #94a3b8; margin-left: 8px;">Point Size:
            <input type="range" id="slider-size" min="0.01" max="0.12" step="0.005" value="0.035" style="vertical-align: middle;">
        </label>
    </div>

    <div class="legend-bar">
        <span style="color: #94a3b8; font-weight: 600;">Cavity Depth Scale (&Delta;Z)</span>
        <div class="gradient-box"></div>
        <div style="display: flex; justify-content: space-between; color: #cbd5e1;">
            <span>2.5 cm (Rim)</span>
            <span>&gt; 6.0 cm (Pit)</span>
        </div>
    </div>

    <script>
        (function() {{
            const container = document.getElementById('canvas-container');
            const scene = new THREE.Scene();
            scene.background = new THREE.Color(0x0b0f19);

            const camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.01, 500);
            const renderer = new THREE.WebGLRenderer({{ antialias: true, powerPreference: "high-performance" }});
            renderer.setSize(window.innerWidth, window.innerHeight);
            renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
            container.appendChild(renderer.domElement);

            const controls = new THREE.OrbitControls(camera, renderer.domElement);
            controls.enableDamping = true;
            controls.dampingFactor = 0.05;

            // Fast base64 to Float32Array converter (zero JSON overhead)
            function b64ToFloat32Array(b64Str) {{
                const binaryString = window.atob(b64Str);
                const bytes = new Uint8Array(binaryString.length);
                for (let i = 0; i < binaryString.length; i++) {{
                    bytes[i] = binaryString.charCodeAt(i);
                }}
                return new Float32Array(bytes.buffer);
            }}

            const positions = b64ToFloat32Array("{b64_positions}");
            const colors = b64ToFloat32Array("{b64_colors}");

            const geometry = new THREE.BufferGeometry();
            geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
            geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
            geometry.computeBoundingBox();

            const material = new THREE.PointsMaterial({{
                size: 0.035,
                vertexColors: true,
                sizeAttenuation: true
            }});

            const pointCloud = new THREE.Points(geometry, material);
            scene.add(pointCloud);

            // Center camera target on point cloud
            const center = new THREE.Vector3();
            geometry.boundingBox.getCenter(center);
            controls.target.copy(center);

            const box = geometry.boundingBox;
            const size = new THREE.Vector3();
            box.getSize(size);
            const maxDim = Math.max(size.x, size.y, size.z, 1.0);

            const focusCenter = new THREE.Vector3({focus_target[0]:.4f}, {focus_target[1]:.4f}, {focus_target[2]:.4f});

            // Initial camera pose: 3D perspective angle (Image 2 style)
            function setPerspectiveView() {{
                controls.target.copy(center);
                camera.position.set(center.x, center.y + maxDim * 0.75, center.z - maxDim * 1.15);
                controls.update();
            }}

            // Close-up inspection of primary pothole cavity (Image 1 style)
            function setFocusPothole() {{
                controls.target.copy(focusCenter);
                camera.position.set(focusCenter.x, focusCenter.y + maxDim * 0.28, focusCenter.z - maxDim * 0.38);
                controls.update();
            }}

            // Razor-flat side elevation cross-section (Image 3 style)
            function setSideView() {{
                controls.target.copy(center);
                camera.position.set(center.x - maxDim * 1.5, center.y + 0.005, center.z);
                controls.update();
            }}

            function setTopView() {{
                controls.target.copy(center);
                camera.position.set(center.x, center.y + maxDim * 1.8, center.z + 0.001);
                controls.update();
            }}

            setPerspectiveView();

            // Subtle ground grid below road surface
            const gridHelper = new THREE.GridHelper(maxDim * 3, 40, 0x38bdf8, 0x1e293b);
            gridHelper.position.set(center.x, center.y - 0.22, center.z);
            scene.add(gridHelper);

            // UI Listeners
            document.getElementById('slider-size').addEventListener('input', (e) => {{
                material.size = parseFloat(e.target.value);
            }});

            document.getElementById('btn-reset').addEventListener('click', setPerspectiveView);
            document.getElementById('btn-perspective').addEventListener('click', setPerspectiveView);
            document.getElementById('btn-side').addEventListener('click', setSideView);
            document.getElementById('btn-focus').addEventListener('click', setFocusPothole);
            document.getElementById('btn-top').addEventListener('click', setTopView);

            document.getElementById('btn-download').addEventListener('click', () => {{
                const link = document.createElement('a');
                link.href = '{ply_filename}';
                link.download = '{ply_filename}';
                link.click();
            }});

            window.addEventListener('resize', () => {{
                camera.aspect = window.innerWidth / window.innerHeight;
                camera.updateProjectionMatrix();
                renderer.setSize(window.innerWidth, window.innerHeight);
            }});

            function animate() {{
                requestAnimationFrame(animate);
                controls.update();
                renderer.render(scene, camera);
            }}
            animate();
        }})();
    </script>
</body>
</html>
"""
        return html_template

    def save_html(
        self,
        output_file_path: str,
        points_xyz: np.ndarray,
        colors_rgb: np.ndarray,
        telemetry: Optional[Dict[str, Any]] = None
    ) -> str:
        """Saves self-contained HTML WebGL viewer file to disk."""
        html_code = self.build_html_content(points_xyz, colors_rgb, telemetry)
        with open(output_file_path, "w", encoding="utf-8") as f:
            f.write(html_code)
        return output_file_path

    def display_inline(
        self,
        points_xyz: np.ndarray,
        colors_rgb: np.ndarray,
        telemetry: Optional[Dict[str, Any]] = None,
        height_px: int = 650
    ):
        """Displays interactive canvas directly inside Jupyter or Google Colab."""
        if not IPYTHON_AVAILABLE:
            raise RuntimeError("IPython is not available in the current environment.")

        html_code = self.build_html_content(points_xyz, colors_rgb, telemetry)
        iframe_wrapper = f"""
        <iframe srcdoc="{html_code.replace('"', '&quot;')}" style="width: 100%; height: {height_px}px; border: none; border-radius: 12px;"></iframe>
        """
        display(HTML(iframe_wrapper))
