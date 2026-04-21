import { useEffect, useMemo } from "react";
import L from "leaflet";
import { CircleMarker, MapContainer, Popup, TileLayer, useMap } from "react-leaflet";
import { useRoadEyeData } from "../context/useRoadEyeData";

const FALLBACK_CENTER = [18.55215, 73.749466];

const severityMeta = {
    pothole: { label: "Pothole", color: "#d94841", rank: 3 },
    rough: { label: "Rough Patch", color: "#f59f00", rank: 2 },
    smooth: { label: "Smooth Surface", color: "#2f9e44", rank: 1 },
    unknown: { label: "Unclassified", color: "#748ca0", rank: 0 }
};

function getSeverity(roughness) {
    if (!Number.isFinite(roughness)) {
        return "unknown";
    }

    if (roughness > 0.65) {
        return "pothole";
    }

    if (roughness > 0.50) {
        return "rough";
    }

    return "smooth";
}
function formatRoughness(roughness) {
    return Number.isFinite(roughness) ? roughness.toFixed(2) : "N/A";
}

function formatTimestamp(value) {
    if (!value) {
        return "Unknown time";
    }

    const parsed = new Date(value);

    if (Number.isNaN(parsed.getTime())) {
        return String(value);
    }

    return parsed.toLocaleString([], {
        year: "numeric",
        month: "short",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false
    });
}

function FitBounds({ points }) {
    const map = useMap();

    useEffect(() => {
        if (points.length === 0) {
            return;
        }

        const bounds = L.latLngBounds(points.map((point) => [point.latitude, point.longitude]));
        map.fitBounds(bounds.pad(0.2), { maxZoom: 16, animate: false });
    }, [map, points]);

    return null;
}

export default function MapMonitor() {
    const { rides, isLoading, error, refresh } = useRoadEyeData();

    const points = useMemo(
        () =>
            rides
                .filter(
                    (ride) =>
                        Number.isFinite(ride.latitude) &&
                        Number.isFinite(ride.longitude)
                )
                .map((ride) => ({
                    id: ride.id,
                    latitude: ride.latitude,
                    longitude: ride.longitude,
                    roughness: ride.roughness,
                    severity: getSeverity(ride.roughness),
                    createdAt: ride.createdAt,
                    sessionId: ride.sessionId
                })),
        [rides]
    );

    const counts = useMemo(
        () =>
            points.reduce(
                (acc, point) => {
                    acc[point.severity] += 1;
                    return acc;
                },
                { pothole: 0, rough: 0, smooth: 0, unknown: 0 }
            ),
        [points]
    );

    const sortedPoints = useMemo(
        () =>
            [...points].sort((first, second) => {
                const severityDelta =
                    severityMeta[second.severity].rank - severityMeta[first.severity].rank;

                if (severityDelta !== 0) {
                    return severityDelta;
                }

                return (second.roughness ?? -Infinity) - (first.roughness ?? -Infinity);
            }),
        [points]
    );

    const mapCenter = points.length
        ? [points[0].latitude, points[0].longitude]
        : FALLBACK_CENTER;

    return (
        <section className="page">
            <header className="page-header">
                <h1>Road Hazard Map</h1>
                <p>Track potholes, rough patches, and smooth segments from live road logs.</p>
            </header>

            {error && (
                <div className="notice notice-error">
                    <p>{error}</p>
                    <button type="button" className="btn btn-ghost" onClick={refresh}>
                        Retry
                    </button>
                </div>
            )}

            <div className="summary-row">
                <article className="summary-chip">
                    <p>Total Points</p>
                    <strong>{points.length.toLocaleString()}</strong>
                </article>
                <article className="summary-chip">
                    <p>Potholes</p>
                    <strong>{counts.pothole.toLocaleString()}</strong>
                </article>
                <article className="summary-chip">
                    <p>Rough Patches</p>
                    <strong>{counts.rough.toLocaleString()}</strong>
                </article>
                <article className="summary-chip">
                    <p>Smooth</p>
                    <strong>{counts.smooth.toLocaleString()}</strong>
                </article>
            </div>

            <div className="map-layout">
                <article className="panel map-panel">
                    <div className="map-legend">
                        <span className="legend-pill legend-pothole">Pothole</span>
                        <span className="legend-pill legend-rough">Rough Patch</span>
                        <span className="legend-pill legend-smooth">Smooth</span>
                        <span className="legend-pill legend-unknown">Unclassified</span>
                    </div>

                    {points.length === 0 ? (
                        <p className="empty-state map-empty">
                            {isLoading
                                ? "Loading map points..."
                                : "No geolocation data found in ride logs."}
                        </p>
                    ) : (
                        <MapContainer
                            center={mapCenter}
                            zoom={13}
                            className="hazard-map"
                            scrollWheelZoom
                        >
                            <TileLayer
                                url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                                attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
                            />
                            <FitBounds points={points} />
                            {points.map((point, index) => {
                                const meta = severityMeta[point.severity];

                                return (
                                    <CircleMarker
                                        key={`${point.id}-${index}`}
                                        center={[point.latitude, point.longitude]}
                                        radius={point.severity === "pothole" ? 8 : 6}
                                        pathOptions={{
                                            color: meta.color,
                                            fillColor: meta.color,
                                            fillOpacity: 0.55,
                                            weight: 2
                                        }}
                                    >
                                        <Popup>
                                            <div className="map-popup">
                                                <p><strong>Severity:</strong> {meta.label}</p>
                                                <p><strong>Roughness:</strong> {formatRoughness(point.roughness)}</p>
                                                <p><strong>Time:</strong> {formatTimestamp(point.createdAt)}</p>
                                                <p><strong>Session:</strong> {point.sessionId || "N/A"}</p>
                                            </div>
                                        </Popup>
                                    </CircleMarker>
                                );
                            })}
                        </MapContainer>
                    )}
                </article>

                <article className="panel map-feed">
                    <h2>Recent Hazard Feed</h2>
                    <ul className="hazard-list">
                        {sortedPoints.slice(0, 12).map((point, index) => {
                            const meta = severityMeta[point.severity];

                            return (
                                <li key={`${point.id}-${index}`}>
                                    <span className={`pill pill-${point.severity}`}>
                                        {meta.label}
                                    </span>
                                    <span>Roughness {formatRoughness(point.roughness)}</span>
                                    <span>{formatTimestamp(point.createdAt)}</span>
                                </li>
                            );
                        })}
                        {!isLoading && sortedPoints.length === 0 && (
                            <li>
                                <span>No hazard events available.</span>
                            </li>
                        )}
                    </ul>
                </article>
            </div>
        </section>
    );
}
