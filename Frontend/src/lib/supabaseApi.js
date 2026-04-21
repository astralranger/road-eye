const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY;

function getConfigError() {
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
        return "Missing Supabase config. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in .env.";
    }
    return null;
}

function buildUrl(table, query = "") {
    const cleanedBase = SUPABASE_URL.replace(/\/$/, "");
    const cleanedQuery = query.startsWith("?") ? query.slice(1) : query;
    return `${cleanedBase}/rest/v1/${table}${cleanedQuery ? `?${cleanedQuery}` : ""}`;
}

async function request(table, options = {}, query = "") {
    const configError = getConfigError();
    if (configError) throw new Error(configError);

    const response = await fetch(buildUrl(table, query), {
        ...options,
        headers: {
            apikey: SUPABASE_ANON_KEY,
            Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
            "Content-Type": "application/json",
            ...(options.headers || {})
        }
    });

    if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail);
    }

    if (response.status === 204) return null;
    return response.json();
}

// 🔥 FETCH DETECTIONS FOR MAP
export async function fetchRides() {
    return request("detections", {}, "select=*&order=created_at.desc");
}

// 🔥 FETCH COMPLAINTS
export async function fetchComplaints() {
    return request("pothole_complaints", {}, "select=*&order=created_at.desc");
}

// 🔥 INSERT COMPLAINT
export async function insertComplaint(payload) {
    const rows = await request(
        "pothole_complaints",
        {
            method: "POST",
            headers: { Prefer: "return=representation" },
            body: JSON.stringify([payload])
        },
        "select=*"
    );

    return Array.isArray(rows) ? rows[0] : rows;
}