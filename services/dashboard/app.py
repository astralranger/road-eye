from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request

from supabase_client import (
    SupabaseClient,
    SupabaseConfig,
    SupabaseError,
    is_missing_table_error,
    to_complaint_item,
    to_ride_item,
)


FALLBACK_CENTER = (18.55215, 73.749466)

SEVERITY_META: dict[str, dict[str, Any]] = {
    "pothole": {"label": "Pothole", "color": "#d94841", "rank": 3},
    "rough": {"label": "Rough Patch", "color": "#f59f00", "rank": 2},
    "smooth": {"label": "Smooth Surface", "color": "#2f9e44", "rank": 1},
    "unknown": {"label": "Unclassified", "color": "#748ca0", "rank": 0},
}


def _parse_datetime(value: Any) -> datetime | None:
    if not value:
        return None
    if isinstance(value, datetime):
        return value
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text)
    except Exception:
        return None


def _format_timestamp(value: Any) -> str:
    if not value:
        return "Unknown time"
    parsed = _parse_datetime(value)
    if not parsed:
        return str(value)
    return parsed.strftime("%b %d, %Y, %H:%M")


def _derive_status(ride: dict[str, Any]) -> str:
    # The original React demo had an explicit `status` column. Your `road_logs` schema does not.
    # To keep the UI stable, derive a reasonable label from timestamps.
    status = str(ride.get("status") or "").strip()
    if status:
        return status

    created_at = _parse_datetime(ride.get("createdAt"))
    if not created_at:
        return "Unknown"

    age_seconds = (datetime.utcnow().replace(tzinfo=created_at.tzinfo) - created_at).total_seconds()
    if age_seconds <= 15 * 60:
        return "Ongoing"
    return "Completed"


def _format_roughness(value: Any) -> str:
    try:
        numeric = float(value)
        if numeric != numeric or numeric in (float("inf"), float("-inf")):
            return "N/A"
        return f"{numeric:.2f}"
    except Exception:
        return "N/A"


def _get_severity(roughness: float | None) -> str:
    if roughness is None:
        return "unknown"
    if roughness >= 1.1:
        return "pothole"
    if roughness >= 0.7:
        return "rough"
    return "smooth"


def create_app() -> Flask:
    repo_root = Path(__file__).resolve().parent.parent
    load_dotenv(repo_root / ".env")

    app = Flask(__name__, template_folder="templates", static_folder="static")
    import os

    app.secret_key = os.getenv("FLASK_SECRET_KEY") or "dev-only-change-me"

    def _client() -> SupabaseClient:
        config = SupabaseConfig.from_env()
        return SupabaseClient(config)

    def _load_rides_and_complaints() -> tuple[list[dict[str, Any]], list[dict[str, Any]], str]:
        error_parts: list[str] = []
        rides: list[dict[str, Any]] = []
        complaints: list[dict[str, Any]] = []

        try:
            rides_rows = _client().fetch_rides()
            rides = [to_ride_item(row) for row in rides_rows]
            for ride in rides:
                ride["status"] = _derive_status(ride)
        except Exception as exc:
            error_parts.append(f"Rides: {exc}")

        try:
            client = _client()
            complaint_rows = client.fetch_complaints()
            complaints = [to_complaint_item(row) for row in complaint_rows]
        except Exception as exc:
            # Match the previous UX: missing complaints table should not block the dashboard.
            try:
                cfg = SupabaseConfig.from_env()
                if not is_missing_table_error(exc, cfg.complaints_table):
                    error_parts.append(f"Complaints: {exc}")
            except Exception:
                error_parts.append(f"Complaints: {exc}")

        return rides, complaints, " | ".join(error_parts)

    @app.get("/healthz")
    def healthz():
        return {"ok": True}

    @app.get("/")
    def home():
        return render_template("home.html", title="RoadEye")

    @app.get("/dashboard")
    def dashboard():
        rides, complaints, error = _load_rides_and_complaints()

        def _is_complaint_resolved(item: dict[str, Any]) -> bool:
            normalized_status = str(item.get("status") or "").lower()
            return bool(item.get("resolved") is True or normalized_status == "resolved")

        resolved_count = sum(1 for c in complaints if _is_complaint_resolved(c))
        ongoing_rides = [r for r in rides if str(r.get("status") or "").lower() == "ongoing"]
        active_agents = len({r.get("driver") for r in ongoing_rides if r.get("driver")})

        complaints_count = len(complaints)
        stats = [
            {
                "title": "Total Rides",
                "value": f"{len(rides):,}",
                "note": "Live from Supabase",
                "tone": "info",
            },
            {
                "title": "Complaints",
                "value": f"{complaints_count:,}",
                "note": "Open and historical records",
                "tone": "alert",
            },
            {
                "title": "Resolved",
                "value": f"{resolved_count:,}",
                "note": f"{round((resolved_count / complaints_count) * 100)}% resolved"
                if complaints_count
                else "No complaints yet",
                "tone": "good",
            },
            {
                "title": "Agents Active",
                "value": f"{active_agents:,}",
                "note": "Based on ongoing rides",
                "tone": "neutral",
            },
        ]

        return render_template(
            "dashboard.html",
            title="Dashboard",
            rides=rides,
            complaints_count=complaints_count,
            ongoing_rides=len(ongoing_rides),
            stats=stats,
            error=error,
        )

    @app.get("/rides")
    def rides():
        rides_data, _, error = _load_rides_and_complaints()

        def _count(status: str) -> int:
            return sum(1 for r in rides_data if str(r.get("status") or "").lower() == status)

        return render_template(
            "rides.html",
            title="Rides",
            rides=rides_data,
            total=len(rides_data),
            completed=_count("completed"),
            ongoing=_count("ongoing"),
            cancelled=_count("cancelled"),
            error=error,
        )

    @app.route("/complaints", methods=["GET", "POST"])
    def complaints():
        form_message = ""
        form_priority = "Medium"
        submit_error = ""
        error = ""

        try:
            client = _client()
        except SupabaseError as exc:
            client = None  # type: ignore[assignment]
            error = str(exc)

        if request.method == "POST":
            form_message = (request.form.get("message") or "").strip()
            form_priority = (request.form.get("priority") or "Medium").strip() or "Medium"

            if not form_message:
                submit_error = "Please enter complaint details."
            elif client is None:
                submit_error = error or "Missing Supabase config."
            else:
                complaints_table = None
                try:
                    complaints_table = SupabaseConfig.from_env().complaints_table
                except Exception:
                    complaints_table = None

                if complaints_table == "detections":
                    submit_error = (
                        'Your Supabase complaints table is set to "detections", which requires '
                        "`latitude`, `longitude`, and `image_url` (NOT NULL). "
                        "Either create a separate complaints table, or tell me to change the "
                        "Complaints page to collect those fields."
                    )
                else:
                    payload = {
                        "message": form_message,
                        "priority": form_priority,
                        "created_at": datetime.utcnow().isoformat() + "Z",
                    }
                    try:
                        client.insert_complaint(payload)
                        return redirect("/complaints")
                    except Exception as exc:
                        submit_error = str(exc) or "Could not save complaint."

        complaints_items: list[dict[str, Any]] = []
        if client is not None:
            try:
                rows = client.fetch_complaints()
                complaints_items = [to_complaint_item(row) for row in rows]
            except Exception as exc:
                try:
                    cfg = SupabaseConfig.from_env()
                    if not is_missing_table_error(exc, cfg.complaints_table):
                        error = str(exc)
                except Exception:
                    error = str(exc)

        return render_template(
            "complaints.html",
            title="Complaints",
            complaints=complaints_items,
            error=error,
            submit_error=submit_error,
            form_message=form_message,
            form_priority=form_priority,
        )

    @app.get("/map")
    def map_view():
        rides_data, _, error = _load_rides_and_complaints()

        points: list[dict[str, Any]] = []
        for ride in rides_data:
            lat = ride.get("latitude")
            lng = ride.get("longitude")
            if lat is None or lng is None:
                continue
            roughness = ride.get("roughness")
            severity = _get_severity(roughness)
            meta = SEVERITY_META.get(severity, SEVERITY_META["unknown"])
            points.append(
                {
                    "id": ride.get("id"),
                    "latitude": lat,
                    "longitude": lng,
                    "roughness": roughness,
                    "severity": severity,
                    "severity_label": meta["label"],
                    "createdAt": ride.get("createdAt"),
                    "timestamp_fmt": _format_timestamp(ride.get("createdAt")),
                    "roughness_fmt": _format_roughness(roughness),
                    "sessionId": ride.get("sessionId"),
                }
            )

        counts = {"pothole": 0, "rough": 0, "smooth": 0, "unknown": 0}
        for p in points:
            counts[p["severity"]] = counts.get(p["severity"], 0) + 1

        sorted_points = sorted(
            points,
            key=lambda p: (
                -int(SEVERITY_META.get(p["severity"], SEVERITY_META["unknown"])["rank"]),
                -(p["roughness"] if isinstance(p["roughness"], (int, float)) else float("-inf")),
            ),
        )

        return render_template(
            "map.html",
            title="Map",
            error=error,
            points=points,
            sorted_points=sorted_points,
            total_points=f"{len(points):,}",
            counts=counts,
            fallback_center=FALLBACK_CENTER,
        )

    @app.errorhandler(404)
    def not_found(_):
        return redirect("/")

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=True)
