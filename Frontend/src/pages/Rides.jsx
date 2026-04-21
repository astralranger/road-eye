import { useRoadEyeData } from "../context/useRoadEyeData";

function statusClass(status) {
    return String(status).toLowerCase();
}

export default function Rides() {
    const { rides, isLoading, error, refresh } = useRoadEyeData();
    const completed = rides.filter((ride) => String(ride.status).toLowerCase() === "completed").length;
    const ongoing = rides.filter((ride) => String(ride.status).toLowerCase() === "ongoing").length;
    const cancelled = rides.filter((ride) => String(ride.status).toLowerCase() === "cancelled").length;

    return (
        <section className="page">
            <header className="page-header">
                <h1>Ride History</h1>
                <p>Monitor recent trips and quickly spot rides needing intervention.</p>
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
                    <p>Total</p>
                    <strong>{rides.length}</strong>
                </article>
                <article className="summary-chip">
                    <p>Completed</p>
                    <strong>{completed}</strong>
                </article>
                <article className="summary-chip">
                    <p>Ongoing</p>
                    <strong>{ongoing}</strong>
                </article>
                <article className="summary-chip">
                    <p>Cancelled</p>
                    <strong>{cancelled}</strong>
                </article>
            </div>

            <div className="table-wrap">
                <table className="table">
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>User</th>
                            <th>Driver</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rides.map((ride) => (
                            <tr key={ride.id}>
                                <td>{ride.id}</td>
                                <td>{ride.user}</td>
                                <td>{ride.driver}</td>
                                <td>
                                    <span className={`status-pill ${statusClass(ride.status)}`}>
                                        {ride.status}
                                    </span>
                                </td>
                            </tr>
                        ))}
                        {!isLoading && rides.length === 0 && (
                            <tr>
                                <td colSpan={4} className="empty-state">
                                    No rides found in Supabase.
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
            </div>
        </section>
    );
}
