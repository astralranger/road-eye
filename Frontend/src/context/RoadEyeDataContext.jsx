import { useCallback, useEffect, useMemo, useState } from "react";
import {
    fetchComplaints,
    fetchRides,
    insertComplaint
} from "../lib/supabaseApi";
import { RoadEyeDataContext } from "./roadEyeDataContextInstance";

function toFiniteNumber(value) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric : null;
}

function toComplaintItem(row) {
    return {
        id: row.id ?? crypto.randomUUID(),
        message: row.message ?? "No complaint text",
        priority: row.priority ?? row.severity ?? "Medium",
        time: row.created_at ?? null,
        raw: row
    };
}

function toRideItem(row) {
    return {
        id: row.id ?? crypto.randomUUID(),
        latitude: toFiniteNumber(row.latitude),
        longitude: toFiniteNumber(row.longitude),
        roughness: toFiniteNumber(row.confidence ?? row.roughness ?? 0),
        createdAt: row.created_at ?? null,
        sessionId: row.pc_node_id ?? null,
        raw: row
    };
}

function getReasonMessage(reason, fallback) {
    if (reason instanceof Error && reason.message) {
        return reason.message;
    }
    return fallback;
}

export function RoadEyeDataProvider({ children }) {
    const [rides, setRides] = useState([]);
    const [complaints, setComplaints] = useState([]);
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState("");

    const loadAll = useCallback(async () => {
        setIsLoading(true);
        setError("");

        const [rideResult, complaintResult] = await Promise.allSettled([
            fetchRides(),
            fetchComplaints()
        ]);

        const errors = [];

        // ===== Rides =====
        if (rideResult.status === "fulfilled") {
            setRides(
                Array.isArray(rideResult.value)
                    ? rideResult.value.map(toRideItem)
                    : []
            );
        } else {
            setRides([]);
            errors.push(
                `Rides: ${getReasonMessage(
                    rideResult.reason,
                    "Unable to fetch detections from Supabase."
                )}`
            );
        }

        // ===== Complaints =====
        if (complaintResult.status === "fulfilled") {
            setComplaints(
                Array.isArray(complaintResult.value)
                    ? complaintResult.value.map(toComplaintItem)
                    : []
            );
        } else {
            setComplaints([]);
            errors.push(
                `Complaints: ${getReasonMessage(
                    complaintResult.reason,
                    "Unable to fetch complaints from Supabase."
                )}`
            );
        }

        if (errors.length > 0) {
            setError(errors.join(" | "));
        }

        setIsLoading(false);
    }, []);

    useEffect(() => {
        loadAll();
    }, [loadAll]);

    const createComplaint = useCallback(async ({ message, priority }) => {
        const payload = {
            message,
            priority,
            created_at: new Date().toISOString()
        };

        const row = await insertComplaint(payload);
        const next = toComplaintItem(row || payload);

        setComplaints((prev) => [next, ...prev]);
        return next;
    }, []);

    const value = useMemo(
        () => ({
            rides,
            complaints,
            isLoading,
            error,
            refresh: loadAll,
            createComplaint
        }),
        [rides, complaints, isLoading, error, loadAll, createComplaint]
    );

    return (
        <RoadEyeDataContext.Provider value={value}>
            {children}
        </RoadEyeDataContext.Provider>
    );
}