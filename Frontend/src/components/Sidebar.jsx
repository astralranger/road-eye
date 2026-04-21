import { NavLink } from "react-router-dom";

const sideLinks = [
    { to: "/dashboard", label: "Overview" },
    { to: "/map", label: "Hazard Map" },
    { to: "/rides", label: "Ride History" },
    { to: "/complaints", label: "Complaints" }
];

export default function Sidebar() {
    return (
        <aside className="sidebar">
            <p className="sidebar-label">Operations</p>

            <nav className="side-nav" aria-label="Workspace">
                {sideLinks.map((link) => (
                    <NavLink
                        key={link.to}
                        to={link.to}
                        className={({ isActive }) =>
                            isActive ? "side-link side-link-active" : "side-link"
                        }
                    >
                        {link.label}
                    </NavLink>
                ))}
            </nav>

            <section className="sidebar-note">
                <h4>Shift Reminder</h4>
                <p>Prioritize unresolved complaints older than 30 minutes.</p>
            </section>
        </aside>
    );
}
