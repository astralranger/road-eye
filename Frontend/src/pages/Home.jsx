import { Link } from "react-router-dom";

export default function Home() {
    return (
        <div className="page home-page">
            <section className="hero">
                <p className="eyebrow">Central Monitoring</p>
                <h1>Make ride operations faster, calmer, and easier to track.</h1>
                <p className="hero-copy">
                    RoadEye gives support teams a single workspace to monitor ride flow,
                    prioritize incidents, and resolve complaints with less back-and-forth.
                </p>

                <div className="hero-actions">
                    <Link className="btn btn-primary" to="/dashboard">
                        Open Dashboard
                    </Link>
                    <Link className="btn btn-ghost" to="/complaints">
                        Create Complaint
                    </Link>
                </div>
            </section>

            <section className="home-columns">
                <article className="panel">
                    <h2>Current Problem</h2>
                    <p>
                        Manual ride tracking and complaint handling often create long response
                        times, duplicate follow-ups, and unclear ownership.
                    </p>
                </article>

                <article className="panel">
                    <h2>RoadEye Approach</h2>
                    <p>
                        Consolidate ride status, complaint records, and team workflow in one
                        interface so agents can act quickly with accurate context.
                    </p>
                </article>

                <article className="panel">
                    <h2>User Benefit</h2>
                    <p>
                        Clearer dashboards and guided actions reduce confusion for operators
                        and speed up resolution for riders.
                    </p>
                </article>
            </section>
        </div>
    );
}
