import StatCard from "../components/StatCard";
import { useRoadEyeData } from "../context/useRoadEyeData";

function isComplaintResolved(complaint) {
    const normalizedStatus = String(complaint.status || "").toLowerCase();
    return complaint.resolved === true || normalizedStatus === "resolved";
}

export default function Dashboard() {
    const { rides, complaints, isLoading, error, refresh } = useRoadEyeData();

    const resolvedCount = complaints.filter(isComplaintResolved).length;
    const activeAgents = new Set(
        rides
            .filter((ride) => String(ride.status).toLowerCase() === "ongoing")
            .map((ride) => ride.driver)
    ).size;

    const stats = [
        {
            title: "Total Rides",
            value: rides.length.toLocaleString(),
            note: "Live from Supabase",
            tone: "info"
        },
        {
            title: "Complaints",
            value: complaints.length.toLocaleString(),
            note: "Open and historical records",
            tone: "alert"
        },
        {
            title: "Resolved",
            value: resolvedCount.toLocaleString(),
            note: complaints.length ? `${Math.round((resolvedCount / complaints.length) * 100)}% resolved` : "No complaints yet",
            tone: "good"
        },
        {
            title: "Agents Active",
            value: activeAgents.toLocaleString(),
            note: "Based on ongoing rides",
            tone: "neutral"
        }
    ];

    return (
        <section className="page">
            <header className="page-header">
                <h1>Operations Overview</h1>
                <p>Track system health, complaints, and team coverage at a glance.</p>
            </header>

            {error && (
                <div className="notice notice-error">
                    <p>{error}</p>
                    <button type="button" className="btn btn-ghost" onClick={refresh}>
                        Retry
                    </button>
                </div>
            )}

            <div className="grid">
                {stats.map((item) => (
                    <StatCard
                        key={item.title}
                        title={item.title}
                        value={item.value}
                        note={item.note}
                        tone={item.tone}
                    />
                ))}
            </div>

            <section className="panel">
                <h2>Attention Queue</h2>
                <ul className="queue-list">
                    <li>
                        <span className="pill pill-alert">High</span>
                        {complaints.length} complaint record(s) loaded from the database.
                    </li>
                    <li>
                        <span className="pill pill-info">Medium</span>
                        {rides.filter((ride) => String(ride.status).toLowerCase() === "ongoing").length}
                        {" "}ride(s) are currently ongoing.
                    </li>
                    <li>
                        <span className="pill pill-good">Low</span>
                        {isLoading ? "Refreshing data..." : "Data sync completed."}
                    </li>
                </ul>
            </section>
        </section>
    );
}
