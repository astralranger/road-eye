import { useEffect, useState, useCallback } from "react";
import { fetchRides, fetchComplaints, insertComplaint } from "../lib/supabaseApi";

export function useRoadEyeData() {
    const [rides, setRides] = useState([]);
    const [complaints, setComplaints] = useState([]);
    const [error, setError] = useState("");
    const [isLoading, setIsLoading] = useState(false);

    const fetchData = useCallback(async () => {
        setIsLoading(true);
        setError("");

        try {
            const detections = await fetchRides();
            const complaintData = await fetchComplaints();

            // 🔥 CLASSIFICATION LOGIC
            const formattedRides = detections.map((item) => {
                const roughnessValue = item.confidence ?? 0;

                let category = "Smooth";

                if (roughnessValue > 0.70) {
                    category = "Pothole";
                } else if (roughnessValue > 0.55) {
                    category = "Rough Patch";
                }

                return {
                    id: item.id,
                    latitude: item.latitude,
                    longitude: item.longitude,
                    roughness: roughnessValue,
                    category,
                    createdAt: item.created_at,
                    sessionId: item.pc_node_id,
                    image_url: item.image_url
                };
            });

            const formattedComplaints = complaintData.map((item) => ({
                id: item.id,
                message: item.severity || item.message || "Pothole detected",
                priority: item.severity || "Medium",
                time: item.created_at
            }));

            setRides(formattedRides);
            setComplaints(formattedComplaints);

        } catch (err) {
            setError(err.message || "Error loading data");
        } finally {
            setIsLoading(false);
        }
    }, []);

    const createComplaint = async ({ message, priority }) => {
        await insertComplaint({
            severity: priority,
            latitude: null,
            longitude: null,
            image_url: null,
            emailed: false,
            created_at: new Date().toISOString()
        });

        await fetchData();
    };

    useEffect(() => {
        fetchData();
    }, [fetchData]);

    return {
        rides,
        complaints,
        error,
        isLoading,
        refresh: fetchData,
        createComplaint
    };
}