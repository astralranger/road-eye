import { NavLink } from "react-router-dom";

const links = [
    { to: "/", label: "Home" },
    { to: "/dashboard", label: "Dashboard" },
    { to: "/map", label: "Map" },
    { to: "/rides", label: "Rides" },
    { to: "/complaints", label: "Complaints" }
];

export default function Navbar() {
    return (
        <header className="navbar">
            <div className="brand">
                <span className="brand-badge">RE</span>
                <div>
                    <p className="brand-title">RoadEye</p>
                    <p className="brand-subtitle">Ride Monitoring Console</p>
                </div>
            </div>

            <nav className="top-nav" aria-label="Primary">
                {links.map((link) => (
                    <NavLink
                        key={link.to}
                        to={link.to}
                        className={({ isActive }) =>
                            isActive ? "nav-link nav-link-active" : "nav-link"
                        }
                        end={link.to === "/"}
                    >
                        {link.label}
                    </NavLink>
                ))}
            </nav>
        </header>
    );
}
