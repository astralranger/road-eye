/* global L */
(function () {
    const pointsNode = document.getElementById("points-data");
    const mapNode = document.getElementById("hazard-map");
    if (!pointsNode || !mapNode || typeof L === "undefined") {
        return;
    }

    let points = [];
    try {
        points = JSON.parse(pointsNode.textContent || "[]");
    } catch {
        points = [];
    }

    const severityMeta = {
        pothole: { label: "Pothole", color: "#d94841", rank: 3 },
        rough: { label: "Rough Patch", color: "#f59f00", rank: 2 },
        smooth: { label: "Smooth Surface", color: "#2f9e44", rank: 1 },
        unknown: { label: "Unclassified", color: "#748ca0", rank: 0 }
    };

    const fallbackCenter = [18.55215, 73.749466];
    const mapCenter = points.length ? [points[0].latitude, points[0].longitude] : fallbackCenter;

    const map = L.map(mapNode, { scrollWheelZoom: true }).setView(mapCenter, 13);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        attribution:
            '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(map);

    const latLngs = [];

    points.forEach((point) => {
        const meta = severityMeta[point.severity] || severityMeta.unknown;
        const radius = point.severity === "pothole" ? 8 : 6;
        const latLng = [point.latitude, point.longitude];
        latLngs.push(latLng);

        const marker = L.circleMarker(latLng, {
            radius,
            color: meta.color,
            fillColor: meta.color,
            fillOpacity: 0.55,
            weight: 2
        });

        const popupHtml = `
            <div class="map-popup">
                <p><strong>Severity:</strong> ${meta.label}</p>
                <p><strong>Roughness:</strong> ${point.roughness_fmt}</p>
                <p><strong>Time:</strong> ${point.timestamp_fmt}</p>
                <p><strong>Session:</strong> ${point.sessionId || "N/A"}</p>
            </div>
        `;

        marker.bindPopup(popupHtml);
        marker.addTo(map);
    });

    if (latLngs.length > 0) {
        map.fitBounds(latLngs, { padding: [30, 30], maxZoom: 16, animate: false });
    }
})();

