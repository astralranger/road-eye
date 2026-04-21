import { useState } from "react";
import { useRoadEyeData } from "../context/useRoadEyeData";

function formatTime(value) {
    if (!value) {
        return "--:--";
    }

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
        return String(value);
    }

    return date.toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
        hour12: false
    });
}

export default function Complaints() {
    const [message, setMessage] = useState("");
    const [priority, setPriority] = useState("Medium");
    const [submitError, setSubmitError] = useState("");
    const [isSubmitting, setIsSubmitting] = useState(false);
    const { complaints, error, refresh, createComplaint } = useRoadEyeData();

    const handleSubmit = async (event) => {
        event.preventDefault();

        const trimmed = message.trim();
        if (!trimmed) {
            return;
        }

        setSubmitError("");
        setIsSubmitting(true);

        try {
            await createComplaint({ message: trimmed, priority });
            setMessage("");
            setPriority("Medium");
        } catch (err) {
            setSubmitError(err.message || "Could not save complaint.");
        } finally {
            setIsSubmitting(false);
        }
    };

    return (
        <section className="page">
            <header className="page-header">
                <h1>Complaint Desk</h1>
                <p>Create and track rider issues with clear priority tagging.</p>
            </header>

            {error && (
                <div className="notice notice-error">
                    <p>{error}</p>
                    <button type="button" className="btn btn-ghost" onClick={refresh}>
                        Retry
                    </button>
                </div>
            )}

            <div className="complaint-layout">
                <article className="panel">
                    <h2>Log New Complaint</h2>
                    <form className="complaint-form" onSubmit={handleSubmit}>
                        <label htmlFor="complaint-message">Complaint Details</label>
                        <textarea
                            id="complaint-message"
                            value={message}
                            onChange={(event) => setMessage(event.target.value)}
                            placeholder="Describe the issue clearly so an agent can act fast."
                            rows={4}
                        />

                        <label htmlFor="complaint-priority">Priority</label>
                        <select
                            id="complaint-priority"
                            value={priority}
                            onChange={(event) => setPriority(event.target.value)}
                        >
                            <option>Low</option>
                            <option>Medium</option>
                            <option>High</option>
                        </select>

                        <button className="btn btn-primary" type="submit" disabled={isSubmitting}>
                            {isSubmitting ? "Saving..." : "Add Complaint"}
                        </button>

                        {submitError && <p className="inline-error">{submitError}</p>}
                    </form>
                </article>

                <article className="panel">
                    <h2>Recent Complaints</h2>
                    <ul className="complaint-list">
                        {complaints.map((item) => (
                            <li key={item.id}>
                                <div className="complaint-meta">
                                    <span className={`pill pill-${item.priority.toLowerCase()}`}>
                                        {item.priority}
                                    </span>
                                    <span>{formatTime(item.time)}</span>
                                </div>
                                <p>{item.message}</p>
                            </li>
                        ))}
                        {complaints.length === 0 && (
                            <li>
                                <p>No complaints found in Supabase.</p>
                            </li>
                        )}
                    </ul>
                </article>
            </div>
        </section>
    );
}
