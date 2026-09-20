from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import requests


class SupabaseError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        code: str | None = None,
        table: str | None = None,
        status: int | None = None,
        hint: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.table = table
        self.status = status
        self.hint = hint


def _env(*names: str) -> str | None:
    for name in names:
        value = os.getenv(name)
        if value:
            return value
    return None


@dataclass(frozen=True)
class SupabaseConfig:
    url: str
    anon_key: str
    rides_table: str = "rides"
    complaints_table: str = "complaints"

    @staticmethod
    def from_env() -> "SupabaseConfig":
        url = _env("SUPABASE_URL", "VITE_SUPABASE_URL")
        anon_key = _env(
            "SUPABASE_ANON_KEY",
            "SUPABASE_KEY",
            "VITE_SUPABASE_ANON_KEY",
        )
        rides_table = _env("SUPABASE_RIDES_TABLE", "VITE_SUPABASE_RIDES_TABLE") or "rides"
        complaints_table = (
            _env("SUPABASE_COMPLAINTS_TABLE", "VITE_SUPABASE_COMPLAINTS_TABLE") or "complaints"
        )

        if not url or not anon_key:
            raise SupabaseError(
                "Missing Supabase config. Set SUPABASE_URL and SUPABASE_ANON_KEY in .env."
            )

        return SupabaseConfig(
            url=url,
            anon_key=anon_key,
            rides_table=rides_table,
            complaints_table=complaints_table,
        )


def _build_url(base_url: str, table: str, query: str = "") -> str:
    cleaned_base = base_url.rstrip("/")
    cleaned_query = query[1:] if query.startswith("?") else query
    return f"{cleaned_base}/rest/v1/{table}{('?' + cleaned_query) if cleaned_query else ''}"


def _build_request_error(table: str, status: int, detail: str) -> tuple[str, str | None, str | None]:
    message = detail or f'Supabase request failed ({status}) for table "{table}".'
    code = None
    hint = None

    if detail:
        try:
            parsed = json.loads(detail)
            if isinstance(parsed, dict):
                code = parsed.get("code") if isinstance(parsed.get("code"), str) else None
                hint = parsed.get("hint") if isinstance(parsed.get("hint"), str) else None
                parts: list[str] = []
                if isinstance(parsed.get("message"), str) and parsed["message"]:
                    parts.append(parsed["message"])
                if hint:
                    parts.append(f"Hint: {hint}")
                if code:
                    parts.append(f"Code: {code}")
                if parts:
                    message = f"{' '.join(parts)} (table: {table})"
        except Exception:
            pass

    return message, code, hint


def is_missing_table_error(error: BaseException, table_name: str) -> bool:
    return bool(
        isinstance(error, SupabaseError)
        and error.code == "PGRST205"
        and error.table == table_name
    )


class SupabaseClient:
    def __init__(self, config: SupabaseConfig) -> None:
        self._config = config
        self._session = requests.Session()

    def request(self, table: str, *, method: str = "GET", query: str = "", json_body: Any = None, headers: dict[str, str] | None = None) -> Any:
        url = _build_url(self._config.url, table, query=query)
        response = self._session.request(
            method=method,
            url=url,
            json=json_body,
            headers={
                "apikey": self._config.anon_key,
                "Authorization": f"Bearer {self._config.anon_key}",
                "Content-Type": "application/json",
                **(headers or {}),
            },
            timeout=15,
        )

        if not response.ok:
            detail = response.text
            message, code, hint = _build_request_error(table, response.status_code, detail)
            raise SupabaseError(
                message,
                code=code,
                table=table,
                status=response.status_code,
                hint=hint,
            )

        if response.status_code == 204:
            return None

        if not response.content:
            return None

        return response.json()

    def fetch_rides(self) -> list[dict[str, Any]]:
        rows = self.request(self._config.rides_table, query="select=*&order=id.desc")
        return rows if isinstance(rows, list) else []

    def fetch_complaints(self) -> list[dict[str, Any]]:
        rows = self.request(self._config.complaints_table, query="select=*&order=id.desc")
        return rows if isinstance(rows, list) else []

    def insert_complaint(self, payload: dict[str, Any]) -> dict[str, Any]:
        try:
            rows = self.request(
                self._config.complaints_table,
                method="POST",
                query="select=*",
                json_body=[payload],
                headers={"Prefer": "return=representation"},
            )
        except SupabaseError as error:
            if is_missing_table_error(error, self._config.complaints_table):
                raise SupabaseError(
                    f'Complaints table "{self._config.complaints_table}" is not available in Supabase. '
                    "Set SUPABASE_COMPLAINTS_TABLE to an existing table or create this table."
                ) from error
            raise

        if isinstance(rows, list) and rows:
            return rows[0]
        if isinstance(rows, dict):
            return rows
        return payload


def _to_finite_number(value: Any) -> float | None:
    try:
        numeric = float(value)
    except Exception:
        return None
    return numeric if numeric == numeric and numeric not in (float("inf"), float("-inf")) else None


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


def to_complaint_item(row: dict[str, Any]) -> dict[str, Any]:
    created_at = row.get("created_at") or row.get("time") or row.get("last_seen")
    parsed = _parse_datetime(created_at)
    priority = row.get("priority") or row.get("severity") or "Medium"
    latitude = row.get("latitude")
    longitude = row.get("longitude")
    detection_prefix = ""
    if latitude is not None and longitude is not None and row.get("image_url"):
        detection_prefix = f"Detection @ {latitude:.5f}, {longitude:.5f}: "

    return {
        "id": row.get("id"),
        "message": row.get("message")
        or row.get("complaint")
        or row.get("text")
        or (detection_prefix + (row.get("image_url") or "No complaint text")),
        "priority": priority,
        "time": created_at,
        "time_hm": parsed.strftime("%H:%M") if parsed else (str(created_at) if created_at else "--:--"),
        "status": row.get("status"),
        "resolved": bool(row.get("resolved") or str(row.get("status") or "").lower() == "resolved"),
        "raw": row,
    }


def to_ride_item(row: dict[str, Any]) -> dict[str, Any]:
    # Supports both the previous demo schema and a `road_logs` schema.
    user = row.get("user") or row.get("rider_name") or row.get("customer") or row.get("user_email")
    driver = row.get("driver") or row.get("driver_name") or row.get("pc_node_id") or row.get("session_id")

    return {
        "id": row.get("id"),
        "user": user or "Unknown rider",
        "driver": driver or "Unknown driver",
        "status": row.get("status") or "Unknown",
        "latitude": _to_finite_number(row.get("latitude") or row.get("lat") or row.get("location_lat")),
        "longitude": _to_finite_number(
            row.get("longitude") or row.get("lng") or row.get("lon") or row.get("location_lng")
        ),
        "roughness": _to_finite_number(row.get("roughness") or row.get("bump_score") or row.get("shock_index")),
        "createdAt": row.get("created_at") or row.get("time") or row.get("last_seen"),
        "sessionId": row.get("session_id") or row.get("sessionId"),
        "raw": row,
    }
