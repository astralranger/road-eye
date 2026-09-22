"""
High-Performance Three.js WebGL Canvas & Interactive Inline Viewer.
Renders metric 3D road surfaces and Gaussian splats with:
- RoadEye Native Dark Design System (Uber monochromatic palette)
- Photorealistic True-Color RGB Mode
- Subsurface Thermal Depth Heatmap Mode
- Adaptive Road & Cavity Segmentation Mode
- Anisotropic Gaussian Splat Shaders with Directional Micro-Relief Normals
- Responsive Mobile Viewport Layout & Touch Ergonomics
- Camera View Presets (Overview, Pothole Focus, Side Profile, Top-Down)
- Interactive XYZ Orientation Gizmo & Metric Volumetric Telemetry
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
    Generates interactive WebGL 3D Gaussian Splat viewer using Three.js.
    Supports multi-mode color visualization (Photorealistic RGB, Thermal Heatmap, Cavity Segmentation)
    standardized to RoadEye's native design system.
    """
    def __init__(self, title: str = "RoadEye 3DGS Reconstruction Viewer"):
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
        colors_thermal: Optional[np.ndarray] = None,
        colors_segmentation: Optional[np.ndarray] = None,
        normals_xyz: Optional[np.ndarray] = None,
        telemetry: Optional[Dict[str, Any]] = None,
        max_points: int = 500_000
    ) -> str:
        # Backward-compatibility fallback if 4th argument is passed as telemetry dictionary
        if isinstance(colors_thermal, dict) and telemetry is None:
            telemetry = colors_thermal
            colors_thermal = None

        """
        Builds self-contained standalone HTML and JavaScript Three.js viewer.
        
        Args:
            points_xyz: [N, 3] float32 metric coordinates (X, Y, Z)
            colors_rgb: [N, 3] float32 [0.0-1.0] or uint8 [0-255] photorealistic RGB colors
            colors_thermal: Optional [N, 3] thermal depth heatmap colors
            colors_segmentation: Optional [N, 3] road/cavity segmentation colors
            normals_xyz: Optional [N, 3] surface normal vectors for directional lighting
            telemetry: Optional dictionary of volumetric metrics
            max_points: Point budget cap to guarantee 60 FPS rendering
        """
        N = points_xyz.shape[0]
        if N > max_points:
            sub_step = int(np.ceil(N / max_points))
            pts_sub = points_xyz[::sub_step]
            cols_sub = colors_rgb[::sub_step]
            therm_sub = colors_thermal[::sub_step] if colors_thermal is not None else None
            seg_sub = colors_segmentation[::sub_step] if colors_segmentation is not None else None
            norms_sub = normals_xyz[::sub_step] if normals_xyz is not None else None
        else:
            pts_sub = points_xyz
            cols_sub = colors_rgb
            therm_sub = colors_thermal
            seg_sub = colors_segmentation
            norms_sub = normals_xyz

        # Normalize true RGB
        if cols_sub.dtype == np.uint8:
            cols_norm = (cols_sub.astype(np.float32) / 255.0)
        else:
            cols_norm = np.clip(cols_sub.astype(np.float32), 0.0, 1.0)

        # Thermal colors
        if therm_sub is not None:
            if therm_sub.dtype == np.uint8:
                therm_norm = (therm_sub.astype(np.float32) / 255.0)
            else:
                therm_norm = np.clip(therm_sub.astype(np.float32), 0.0, 1.0)
        else:
            therm_norm = cols_norm.copy()

        # Segmentation colors
        if seg_sub is not None:
            if seg_sub.dtype == np.uint8:
                seg_norm = (seg_sub.astype(np.float32) / 255.0)
            else:
                seg_norm = np.clip(seg_sub.astype(np.float32), 0.0, 1.0)
        else:
            seg_norm = cols_norm.copy()

        # Surface Normals
        if norms_sub is not None:
            norms_clean = np.nan_to_num(norms_sub.astype(np.float32), nan=0.0, posinf=0.0, neginf=0.0)
        else:
            norms_clean = np.zeros((pts_sub.shape[0], 3), dtype=np.float32)
            norms_clean[:, 1] = 1.0

        # Base64 encodings
        b64_positions = self._encode_float32_array(pts_sub.ravel().astype(np.float32))
        b64_colors_rgb = self._encode_float32_array(cols_norm.ravel().astype(np.float32))
        b64_colors_thermal = self._encode_float32_array(therm_norm.ravel().astype(np.float32))
        b64_colors_seg = self._encode_float32_array(seg_norm.ravel().astype(np.float32))
        b64_normals = self._encode_float32_array(norms_clean.ravel().astype(np.float32))

        # Telemetry
        telemetry = telemetry or {}
        max_depth_cm = float(telemetry.get("max_depth_cm", 0.0))
        volume_liters = float(telemetry.get("volume_liters", 0.0))
        surface_area_cm2 = float(telemetry.get("surface_area_cm2", 0.0))
        severity = telemetry.get("severity", "Nominal")
        num_cavities = telemetry.get("num_cavities", 1)
        focus_target = telemetry.get("focus_target", [0.0, 0.0, 0.0])
        ply_filename = telemetry.get("ply_filename", "pothole_3d_splat.ply")

        severity_color = "#048848"  # RoadEye Green (Nominal)
        if severity == "Severe":
            severity_color = "#E11900"  # RoadEye Alert Red
        elif severity in ("Moderate", "Warning"):
            severity_color = "#FFC043"  # RoadEye Warning Amber

        html_template = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="theme-color" content="#000000">
    <title>{self.title}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@500;700&display=swap" rel="stylesheet">
    <style>
        * {{
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            -webkit-tap-highlight-color: transparent;
        }}
        html, body {{
            width: 100%;
            height: 100%;
            overflow: hidden;
            background-color: #000000;
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            color: #FFFFFF;
            user-select: none;
            -webkit-user-select: none;
            touch-action: none;
        }}
        #canvas-container {{
            width: 100vw;
            height: 100vh;
            position: absolute;
            top: 0;
            left: 0;
            z-index: 1;
            touch-action: none;
        }}

        /* --- ROADEYE TOP HEADER BAR --- */
        .roadeye-header {{
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 58px;
            background: rgba(0, 0, 0, 0.85);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border-bottom: 1px solid #1F1F1F;
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0 16px;
            z-index: 50;
            pointer-events: auto;
        }}
        .brand-group {{
            display: flex;
            align-items: center;
            gap: 10px;
        }}
        .brand-title {{
            font-size: 16px;
            font-weight: 800;
            letter-spacing: -0.5px;
            color: #FFFFFF;
            display: flex;
            align-items: center;
            gap: 6px;
        }}
        .brand-dot {{
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #276EF1;
            box-shadow: 0 0 10px rgba(39, 110, 241, 0.8);
        }}
        .brand-badge {{
            background: #1A1A1A;
            border: 1px solid #2A2A2A;
            color: #A6A6A6;
            font-size: 10px;
            font-weight: 700;
            padding: 3px 8px;
            border-radius: 4px;
            letter-spacing: 0.6px;
        }}
        .header-actions {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .header-action-btn {{
            background: #1A1A1A;
            border: 1px solid #2A2A2A;
            color: #FFFFFF;
            padding: 7px 12px;
            border-radius: 8px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.4px;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 6px;
            transition: all 0.2s ease;
        }}
        .header-action-btn:active {{
            transform: scale(0.96);
        }}
        .header-action-btn.active {{
            background: #276EF1;
            border-color: #276EF1;
            color: #FFFFFF;
        }}

        /* --- UBER SEGMENTED RENDER MODE SWITCHER --- */
        .mode-segmented-wrapper {{
            position: absolute;
            top: 70px;
            left: 50%;
            transform: translateX(-50%);
            width: calc(100% - 32px);
            max-width: 440px;
            z-index: 45;
            pointer-events: auto;
        }}
        .mode-segmented-control {{
            background: #121212;
            border: 1px solid #2A2A2A;
            border-radius: 10px;
            padding: 4px;
            display: flex;
            gap: 4px;
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.7);
        }}
        .mode-seg-btn {{
            flex: 1;
            min-height: 38px;
            background: transparent;
            color: #A6A6A6;
            border: none;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.3px;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            text-transform: uppercase;
            white-space: nowrap;
            transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
        }}
        .mode-seg-btn.active {{
            background: #FFFFFF;
            color: #000000;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.4);
        }}

        /* --- VOLUMETRIC CAVITY TELEMETRY HUD CARD --- */
        .hud-card {{
            position: absolute;
            top: 126px;
            left: 16px;
            background: rgba(18, 18, 18, 0.94);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid #2A2A2A;
            border-radius: 14px;
            padding: 16px 18px;
            box-shadow: 0 16px 36px rgba(0, 0, 0, 0.8);
            z-index: 40;
            width: 310px;
            max-width: calc(100vw - 32px);
            pointer-events: auto;
            transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.25s ease;
        }}
        .hud-card.collapsed {{
            opacity: 0;
            pointer-events: none;
            transform: translateY(-10px) scale(0.96);
        }}
        .hud-card-header {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 12px;
            padding-bottom: 8px;
            border-bottom: 1px solid #1F1F1F;
        }}
        .hud-card-title {{
            font-size: 11px;
            font-weight: 800;
            letter-spacing: 0.8px;
            text-transform: uppercase;
            color: #A6A6A6;
            display: flex;
            align-items: center;
            gap: 6px;
        }}
        .hud-close-btn {{
            background: #1A1A1A;
            border: 1px solid #2A2A2A;
            color: #A6A6A6;
            width: 24px;
            height: 24px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 12px;
            cursor: pointer;
            transition: color 0.15s ease, border-color 0.15s ease;
        }}
        .hud-close-btn:hover {{
            color: #FFFFFF;
            border-color: #FFFFFF;
        }}
        .severity-badge-row {{
            margin-bottom: 12px;
        }}
        .severity-badge {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 800;
            letter-spacing: 0.4px;
            text-transform: uppercase;
            background: {severity_color}22;
            color: {severity_color};
            border: 1px solid {severity_color}66;
        }}
        .metric-row {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
            font-size: 13px;
        }}
        .metric-label {{
            color: #A6A6A6;
            font-weight: 500;
            font-size: 12px;
        }}
        .metric-val {{
            font-weight: 700;
            font-family: 'JetBrains Mono', ui-monospace, Menlo, Monaco, Consolas, monospace;
            color: #FFFFFF;
            font-size: 13px;
        }}

        /* --- FLOATING BOTTOM CAMERA & TOOLS DOCK --- */
        .bottom-dock {{
            position: absolute;
            bottom: 20px;
            left: 50%;
            transform: translateX(-50%);
            background: rgba(18, 18, 18, 0.94);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid #2A2A2A;
            border-radius: 32px;
            padding: 6px 14px;
            display: flex;
            align-items: center;
            gap: 8px;
            z-index: 45;
            box-shadow: 0 16px 36px rgba(0, 0, 0, 0.8);
            max-width: calc(100vw - 32px);
            overflow-x: auto;
            -webkit-overflow-scrolling: touch;
            scrollbar-width: none;
            pointer-events: auto;
        }}
        .bottom-dock::-webkit-scrollbar {{
            display: none;
        }}
        .dock-btn {{
            background: #1A1A1A;
            border: 1px solid #2A2A2A;
            color: #FFFFFF;
            padding: 0 14px;
            min-height: 40px;
            border-radius: 20px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.4px;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 6px;
            white-space: nowrap;
            transition: all 0.15s ease;
        }}
        .dock-btn:active {{
            transform: scale(0.96);
        }}
        .dock-btn:hover {{
            background: #2C2C2C;
            border-color: #FFFFFF;
        }}
        .dock-btn.dock-btn-accent {{
            background: #FFFFFF;
            color: #000000;
            border-color: #FFFFFF;
        }}
        .dock-btn.dock-btn-accent:hover {{
            background: #E6E6E6;
        }}
        .size-control {{
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 0 8px;
            color: #A6A6A6;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.4px;
            white-space: nowrap;
        }}
        .size-control input[type="range"] {{
            width: 70px;
            accent-color: #276EF1;
            cursor: pointer;
            vertical-align: middle;
        }}

        /* --- THERMAL ELEVATION LEGEND --- */
        .legend-card {{
            position: absolute;
            bottom: 84px;
            right: 16px;
            background: rgba(18, 18, 18, 0.94);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid #2A2A2A;
            border-radius: 12px;
            padding: 10px 14px;
            z-index: 40;
            display: none;
            box-shadow: 0 12px 28px rgba(0, 0, 0, 0.7);
            max-width: calc(100vw - 32px);
            pointer-events: auto;
        }}
        .legend-title {{
            font-size: 11px;
            font-weight: 700;
            color: #A6A6A6;
            margin-bottom: 6px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }}
        .gradient-box {{
            width: 160px;
            height: 8px;
            border-radius: 4px;
            background: linear-gradient(to right, #00ffff, #00ff00, #ffff00, #ff0000);
            margin: 6px 0;
        }}
        .legend-labels {{
            display: flex;
            justify-content: space-between;
            font-size: 10px;
            font-family: 'JetBrains Mono', monospace;
            color: #FFFFFF;
        }}

        /* --- ORIENTATION GIZMO --- */
        #gizmo-container {{
            position: absolute;
            bottom: 84px;
            left: 16px;
            width: 72px;
            height: 72px;
            z-index: 30;
            pointer-events: none;
        }}

        /* --- MOBILE SCREEN ADAPTATIONS --- */
        @media (max-width: 768px) {{
            .roadeye-header {{
                height: 52px;
                padding: 0 12px;
            }}
            .brand-title {{
                font-size: 15px;
            }}
            .brand-badge {{
                font-size: 9px;
                padding: 2px 6px;
            }}
            .header-action-btn {{
                padding: 6px 10px;
                font-size: 10px;
            }}
            .mode-segmented-wrapper {{
                top: 62px;
                width: calc(100% - 24px);
            }}
            .mode-seg-btn {{
                min-height: 36px;
                font-size: 10px;
            }}
            .hud-card {{
                top: 112px;
                left: 12px;
                right: 12px;
                width: auto;
                max-height: 52vh;
                overflow-y: auto;
                padding: 14px 16px;
            }}
            .bottom-dock {{
                bottom: 14px;
                padding: 4px 10px;
                gap: 6px;
            }}
            .dock-btn {{
                min-height: 38px;
                padding: 0 10px;
                font-size: 10px;
            }}
            .size-control input[type="range"] {{
                width: 50px;
            }}
            #gizmo-container {{
                bottom: 74px;
                left: 12px;
                width: 60px;
                height: 60px;
            }}
            .legend-card {{
                bottom: 74px;
                right: 12px;
            }}
        }}
    </style>
    <script src="/static/js/three.min.js" onerror="this.onerror=null;this.src='https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js'"></script>
    <script src="/static/js/OrbitControls.js" onerror="this.onerror=null;this.src='https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js'"></script>
</head>
<body>
    <div id="canvas-container"></div>
    <div id="context-notice" style="display:none;position:absolute;top:66px;left:50%;transform:translateX(-50%);background:rgba(239,68,68,0.92);color:#FFFFFF;padding:8px 18px;border-radius:6px;font-size:11px;font-weight:700;letter-spacing:0.3px;z-index:9999;box-shadow:0 4px 12px rgba(0,0,0,0.5);">
        WebGL Context Interrupted &mdash; Restoring GPU State...
    </div>

    <!-- ROADEYE TOP NAVIGATION BAR -->
    <header class="roadeye-header">
        <div class="brand-group">
            <span class="brand-dot"></span>
            <div class="brand-title">ROADEYE</div>
            <span class="brand-badge">3DGS ENGINE</span>
        </div>
        <div class="header-actions">
            <button class="header-action-btn" id="btn-reset-header" title="Reset Camera">
                <span>RESET</span>
            </button>
            <button class="header-action-btn active" id="btn-toggle-hud" title="Toggle Metrics HUD">
                <span>METRICS</span>
            </button>
        </div>
    </header>

    <!-- UBER SEGMENTED RENDER MODE CONTROL -->
    <div class="mode-segmented-wrapper">
        <div class="mode-segmented-control">
            <button class="mode-seg-btn active" id="mode-rgb">TRUE RGB</button>
            <button class="mode-seg-btn" id="mode-thermal">DEPTH HEATMAP (&Delta;Z)</button>
            <button class="mode-seg-btn" id="mode-seg">CAVITY SEGMENT</button>
        </div>
    </div>

    <!-- VOLUMETRIC CAVITY TELEMETRY HUD CARD -->
    <div class="hud-card" id="hud-panel">
        <div class="hud-card-header">
            <div class="hud-card-title">
                QUANTITATIVE TELEMETRY
            </div>
            <button class="hud-close-btn" id="btn-close-hud" title="Dismiss HUD">✕</button>
        </div>
        <div class="severity-badge-row">
            <span class="severity-badge">{severity}</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Max Cavity Depth (&Delta;Z):</span>
            <span class="metric-val">{max_depth_cm:.2f} cm</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Total Cavity Volume:</span>
            <span class="metric-val">{volume_liters:.2f} L</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Surface Area:</span>
            <span class="metric-val">{surface_area_cm2:.1f} cm&sup2;</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Verified Potholes:</span>
            <span class="metric-val">{num_cavities}</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Total 3D Splats:</span>
            <span class="metric-val">{pts_sub.shape[0]:,}</span>
        </div>
        <div class="metric-row">
            <span class="metric-label">Metric Datum (H<sub>cam</sub>):</span>
            <span class="metric-val">1.35 m (Calibrated)</span>
        </div>
    </div>

    <!-- FLOATING CAMERA PRESETS & TOOL DOCK -->
    <div class="bottom-dock">
        <button class="dock-btn" id="btn-perspective">OVERVIEW</button>
        <button class="dock-btn" id="btn-focus">POTHOLE</button>
        <button class="dock-btn" id="btn-side">SIDE</button>
        <button class="dock-btn" id="btn-top">TOP-DOWN</button>
        <div class="size-control">
            <span>SIZE</span>
            <input type="range" id="slider-size" min="0.02" max="0.12" step="0.005" value="0.055">
        </div>
        <button class="dock-btn dock-btn-accent" id="btn-download">EXPORT PLY</button>
    </div>

    <!-- THERMAL ELEVATION GRADIENT LEGEND -->
    <div class="legend-card" id="legend-panel">
        <div class="legend-title">Cavity Elevation (&Delta;Z)</div>
        <div class="gradient-box"></div>
        <div class="legend-labels">
            <span>0.0 cm (Road)</span>
            <span>&gt; 9.0 cm (Deep Pit)</span>
        </div>
    </div>

    <script>
        (function() {{
            const container = document.getElementById('canvas-container');
            if (typeof THREE === 'undefined') {{
                container.innerHTML = '<div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;color:#FFFFFF;font-family:sans-serif;text-align:center;padding:20px;"><div style="color:#EF4444;font-size:18px;font-weight:800;margin-bottom:8px;">3DGS WebGL Viewer Offline</div><div style="color:#A6A6A6;font-size:13px;max-width:320px;">Could not load Three.js 3D library. Please verify network access.</div></div>';
                return;
            }}

            // Multi-tiered Resilient WebGL Context Creation
            function createResilientRenderer(canvasElem, width, height, pixelRatio) {{
                const contextTiers = [
                    {{ version: 'webgl2', attrs: {{ antialias: true, alpha: false, depth: true, stencil: false, powerPreference: 'default', failIfMajorPerformanceCaveat: false }} }},
                    {{ version: 'webgl2', attrs: {{ antialias: false, alpha: false, depth: true, stencil: false, powerPreference: 'default', failIfMajorPerformanceCaveat: false }} }},
                    {{ version: 'webgl', attrs: {{ antialias: true, alpha: false, depth: true, stencil: false, powerPreference: 'default', failIfMajorPerformanceCaveat: false }} }},
                    {{ version: 'webgl', attrs: {{ antialias: false, alpha: false, depth: true, stencil: false, powerPreference: 'low-power', failIfMajorPerformanceCaveat: false }} }},
                    {{ version: 'experimental-webgl', attrs: {{ antialias: false, alpha: false, depth: true, stencil: false, powerPreference: 'low-power', failIfMajorPerformanceCaveat: false }} }}
                ];

                for (let i = 0; i < contextTiers.length; i++) {{
                    const tier = contextTiers[i];
                    try {{
                        const gl = canvasElem.getContext(tier.version, tier.attrs);
                        if (gl) {{
                            console.info('[WebGL] Hardware rasterization acquired via ' + tier.version, tier.attrs);
                            const rend = new THREE.WebGLRenderer({{
                                canvas: canvasElem,
                                context: gl,
                                antialias: tier.attrs.antialias,
                                powerPreference: tier.attrs.powerPreference
                            }});
                            rend.setSize(width, height);
                            rend.setPixelRatio(pixelRatio);
                            rend.autoClear = false;
                            return rend;
                        }}
                    }} catch (err) {{
                        console.warn('[WebGL] Tier ' + (i + 1) + ' (' + tier.version + ') context probe failed:', err);
                    }}
                }}

                // Direct Three.js fallback
                try {{
                    const rend = new THREE.WebGLRenderer({{
                        canvas: canvasElem,
                        antialias: false,
                        powerPreference: 'default',
                        failIfMajorPerformanceCaveat: false
                    }});
                    rend.setSize(width, height);
                    rend.setPixelRatio(pixelRatio);
                    rend.autoClear = false;
                    return rend;
                }} catch (fatal) {{
                    console.error('[WebGL] Fatal: All WebGL context creation attempts exhausted.', fatal);
                    return null;
                }}
            }}

            const canvas = document.createElement('canvas');
            canvas.id = 'webgl-surface';
            canvas.style.width = '100%';
            canvas.style.height = '100%';
            canvas.style.display = 'block';
            container.appendChild(canvas);

            const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
            const renderer = createResilientRenderer(canvas, window.innerWidth, window.innerHeight, dpr);

            if (!renderer) {{
                container.innerHTML = `
                    <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;background:#000000;color:#FFFFFF;text-align:center;padding:24px;font-family:'Inter',sans-serif;">
                        <div style="width:52px;height:52px;border-radius:50%;background:#1A1A1A;border:1px solid #333333;display:flex;align-items:center;justify-content:center;margin-bottom:16px;">
                            <span style="color:#EF4444;font-size:24px;line-height:1;">&#9888;</span>
                        </div>
                        <div style="font-size:16px;font-weight:800;letter-spacing:-0.4px;margin-bottom:8px;">WebGL 3D Acceleration Required</div>
                        <div style="font-size:12px;color:#A6A6A6;max-width:340px;line-height:1.5;margin-bottom:20px;">
                            Your browser was unable to initialize a WebGL hardware rasterization context. Please ensure Hardware Acceleration is enabled or open in an external browser.
                        </div>
                        <button onclick="window.location.reload()" style="background:#276EF1;border:none;color:#FFFFFF;font-weight:700;font-size:11px;letter-spacing:0.4px;padding:10px 22px;border-radius:8px;cursor:pointer;">
                            RETRY INITIALIZATION
                        </button>
                    </div>
                `;
                return;
            }}

            let isContextLost = false;
            canvas.addEventListener('webglcontextlost', function(e) {{
                e.preventDefault();
                isContextLost = true;
                console.warn('[WebGL] Context lost event received! Pausing render loop.');
                const notice = document.getElementById('context-notice');
                if (notice) notice.style.display = 'block';
            }}, false);

            canvas.addEventListener('webglcontextrestored', function(e) {{
                console.info('[WebGL] Context restored event received! Re-initializing buffers.');
                isContextLost = false;
                const notice = document.getElementById('context-notice');
                if (notice) notice.style.display = 'none';
            }}, false);

            const scene = new THREE.Scene();
            scene.background = new THREE.Color(0x000000);

            const camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.01, 500);

            // OrbitControls with Native Mobile Touch Handling
            const controls = new THREE.OrbitControls(camera, renderer.domElement);
            controls.enableDamping = true;
            controls.dampingFactor = 0.08;
            controls.rotateSpeed = 0.8;
            controls.zoomSpeed = 1.0;
            controls.panSpeed = 0.8;
            controls.touches = {{
                ONE: THREE.TOUCH.ROTATE,
                TWO: THREE.TOUCH.DOLLY_PAN
            }};

            // Fast base64 to Float32Array converter
            function b64ToFloat32Array(b64Str) {{
                const binaryString = window.atob(b64Str);
                const bytes = new Uint8Array(binaryString.length);
                for (let i = 0; i < binaryString.length; i++) {{
                    bytes[i] = binaryString.charCodeAt(i);
                }}
                return new Float32Array(bytes.buffer);
            }}

            const positions = b64ToFloat32Array("{b64_positions}");
            const colorsRGB = b64ToFloat32Array("{b64_colors_rgb}");
            const colorsThermal = b64ToFloat32Array("{b64_colors_thermal}");
            const colorsSeg = b64ToFloat32Array("{b64_colors_seg}");
            const normals = b64ToFloat32Array("{b64_normals}");

            const geometry = new THREE.BufferGeometry();
            geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
            geometry.setAttribute('color', new THREE.BufferAttribute(colorsRGB.slice(), 3));
            geometry.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
            geometry.computeBoundingBox();

            // Custom Crisp 3D Gaussian Splat Shader Material
            const splatMaterial = new THREE.ShaderMaterial({{
                vertexColors: true,
                uniforms: {{
                    uSize: {{ value: 0.055 }},
                    uScale: {{ value: window.innerHeight * 0.5 * dpr }},
                    uLightDir: {{ value: new THREE.Vector3(0.4, 0.8, 0.4).normalize() }}
                }},
                vertexShader: `
                    varying vec3 vColor;
                    varying vec3 vNormal;
                    uniform float uSize;
                    uniform float uScale;

                    void main() {{
                        vColor = color;
                        vec3 n = normalMatrix * normal;
                        vNormal = (length(n) > 0.001) ? normalize(n) : vec3(0.0, 1.0, 0.0);
                        vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
                        gl_Position = projectionMatrix * mvPosition;
                        float dist = max(0.1, -mvPosition.z);
                        gl_PointSize = clamp(uSize * (uScale / dist), 2.5, 96.0);
                    }}
                `,
                fragmentShader: `
                    varying vec3 vColor;
                    varying vec3 vNormal;
                    uniform vec3 uLightDir;

                    void main() {{
                        vec2 coord = gl_PointCoord - vec2(0.5);
                        float distSq = dot(coord, coord);
                        if (distSq > 0.25) discard;

                        // Anti-aliased Gaussian radial roll-off
                        float alpha = exp(-3.5 * distSq);

                        // Directional micro-relief surface shading
                        float diff = 1.0;
                        if (length(vNormal) > 0.001) {{
                            diff = max(dot(vNormal, uLightDir), 0.38);
                        }}
                        vec3 shadedColor = vColor * (diff * 0.55 + 0.45);
                        gl_FragColor = vec4(shadedColor, alpha);
                    }}
                `,
                transparent: true,
                depthWrite: false,
                depthTest: true
            }});

            const pointCloud = new THREE.Points(geometry, splatMaterial);
            scene.add(pointCloud);

            // Bounding box and centers
            const center = new THREE.Vector3();
            geometry.boundingBox.getCenter(center);
            const box = geometry.boundingBox;
            const size = new THREE.Vector3();
            box.getSize(size);
            const maxDim = Math.max(size.x, size.y, size.z, 1.0);

            const focusCenter = new THREE.Vector3({focus_target[0]:.4f}, {focus_target[1]:.4f}, {focus_target[2]:.4f});

            // Camera Presets
            function setPerspectiveView() {{
                controls.target.copy(center);
                camera.position.set(center.x, center.y + maxDim * 0.65, center.z - maxDim * 1.15);
                controls.update();
            }}

            function setFocusPothole() {{
                controls.target.copy(focusCenter);
                camera.position.set(focusCenter.x, focusCenter.y + maxDim * 0.24, focusCenter.z - maxDim * 0.36);
                controls.update();
            }}

            function setSideView() {{
                controls.target.copy(center);
                camera.position.set(center.x - maxDim * 1.45, center.y + 0.005, center.z);
                controls.update();
            }}

            function setTopView() {{
                controls.target.copy(center);
                camera.position.set(center.x, center.y + maxDim * 1.6, center.z + 0.001);
                controls.update();
            }}

            setPerspectiveView();

            // Subtle dark ground grid below road surface (RoadEye monochromatic theme)
            const gridHelper = new THREE.GridHelper(maxDim * 3, 40, 0x2A2A2A, 0x141414);
            gridHelper.position.set(center.x, center.y - 0.22, center.z);
            scene.add(gridHelper);

            // Color Channel Switcher (Uber Segmented Control)
            function switchColorMode(colorArray, modeName) {{
                const colAttr = geometry.getAttribute('color');
                colAttr.array.set(colorArray);
                colAttr.needsUpdate = true;

                document.querySelectorAll('.mode-seg-btn').forEach(btn => btn.classList.remove('active'));
                const legend = document.getElementById('legend-panel');
                if (modeName === 'thermal') {{
                    document.getElementById('mode-thermal').classList.add('active');
                    legend.style.display = 'block';
                }} else if (modeName === 'seg') {{
                    document.getElementById('mode-seg').classList.add('active');
                    legend.style.display = 'none';
                }} else {{
                    document.getElementById('mode-rgb').classList.add('active');
                    legend.style.display = 'none';
                }}
            }}

            document.getElementById('mode-rgb').addEventListener('click', () => switchColorMode(colorsRGB, 'rgb'));
            document.getElementById('mode-thermal').addEventListener('click', () => switchColorMode(colorsThermal, 'thermal'));
            document.getElementById('mode-seg').addEventListener('click', () => switchColorMode(colorsSeg, 'seg'));

            // HUD Toggle & Close Handlers
            const hudPanel = document.getElementById('hud-panel');
            const btnToggleHud = document.getElementById('btn-toggle-hud');
            const btnCloseHud = document.getElementById('btn-close-hud');

            function toggleHud() {{
                const isCollapsed = hudPanel.classList.toggle('collapsed');
                if (isCollapsed) {{
                    btnToggleHud.classList.remove('active');
                }} else {{
                    btnToggleHud.classList.add('active');
                }}
            }}

            btnToggleHud.addEventListener('click', toggleHud);
            btnCloseHud.addEventListener('click', () => {{
                hudPanel.classList.add('collapsed');
                btnToggleHud.classList.remove('active');
            }});

            // Camera Preset Listeners
            document.getElementById('btn-reset-header').addEventListener('click', setPerspectiveView);
            document.getElementById('btn-perspective').addEventListener('click', setPerspectiveView);
            document.getElementById('btn-focus').addEventListener('click', setFocusPothole);
            document.getElementById('btn-side').addEventListener('click', setSideView);
            document.getElementById('btn-top').addEventListener('click', setTopView);

            // Splat Size Slider
            document.getElementById('slider-size').addEventListener('input', (e) => {{
                splatMaterial.uniforms.uSize.value = parseFloat(e.target.value);
            }});

            // Export PLY Listener
            document.getElementById('btn-download').addEventListener('click', () => {{
                const link = document.createElement('a');
                link.href = '{ply_filename}';
                link.download = '{ply_filename}';
                link.click();
            }});

            // Single-Context Orientation Gizmo (Prevents WebGL context loss on mobile)
            const gizmoScene = new THREE.Scene();
            const gizmoCamera = new THREE.PerspectiveCamera(50, 1, 0.1, 10);
            const axesHelper = new THREE.AxesHelper(1.8);
            gizmoScene.add(axesHelper);

            // Resize & Orientation Change
            function handleResize() {{
                const w = window.innerWidth;
                const h = window.innerHeight;
                const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
                camera.aspect = w / h;
                camera.updateProjectionMatrix();
                if (renderer) {{
                    renderer.setSize(w, h);
                    renderer.setPixelRatio(dpr);
                }}
                splatMaterial.uniforms.uScale.value = h * 0.5 * dpr;
            }}

            window.addEventListener('resize', handleResize);
            window.addEventListener('orientationchange', () => {{
                setTimeout(handleResize, 150);
            }});

            function animate() {{
                requestAnimationFrame(animate);
                if (isContextLost || !renderer) return;

                controls.update();

                const w = window.innerWidth;
                const h = window.innerHeight;

                // 1. Primary Point Cloud Pass
                renderer.setViewport(0, 0, w, h);
                renderer.setScissorTest(false);
                renderer.clear();
                renderer.render(scene, camera);

                // 2. Viewport-isolated Gizmo Pass (Single WebGL context, zero GPU memory exhaustion)
                const gSize = w <= 768 ? 64 : 76;
                const gLeft = w <= 768 ? 14 : 18;
                const gBottom = w <= 768 ? 74 : 84;

                renderer.clearDepth();
                renderer.setScissor(gLeft, gBottom, gSize, gSize);
                renderer.setViewport(gLeft, gBottom, gSize, gSize);
                renderer.setScissorTest(true);

                gizmoCamera.position.copy(camera.position).sub(controls.target).normalize().multiplyScalar(3.5);
                gizmoCamera.lookAt(0, 0, 0);
                renderer.render(gizmoScene, gizmoCamera);

                renderer.setScissorTest(false);
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
        colors_thermal: Optional[np.ndarray] = None,
        colors_segmentation: Optional[np.ndarray] = None,
        normals_xyz: Optional[np.ndarray] = None,
        telemetry: Optional[Dict[str, Any]] = None
    ) -> str:
        """Saves self-contained HTML WebGL viewer file to disk."""
        if isinstance(colors_thermal, dict) and telemetry is None:
            telemetry = colors_thermal
            colors_thermal = None
        html_code = self.build_html_content(
            points_xyz=points_xyz,
            colors_rgb=colors_rgb,
            colors_thermal=colors_thermal,
            colors_segmentation=colors_segmentation,
            normals_xyz=normals_xyz,
            telemetry=telemetry
        )
        with open(output_file_path, "w", encoding="utf-8") as f:
            f.write(html_code)
        return output_file_path
