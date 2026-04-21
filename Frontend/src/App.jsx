import { BrowserRouter, Navigate, Outlet, Route, Routes } from "react-router-dom";

import Navbar from "./components/Navbar";
import Footer from "./components/Footer";
import Sidebar from "./components/Sidebar";

import Home from "./pages/Home";
import Dashboard from "./pages/Dashboard";
import Rides from "./pages/Rides";
import Complaints from "./pages/Complaints";
import MapMonitor from "./pages/MapMonitor";

export default function App() {
    return (
        <BrowserRouter>
            <Navbar />

            <Routes>
                <Route path="/" element={<Home />} />
                <Route element={<WorkspaceLayout />}>
                    <Route path="/dashboard" element={<Dashboard />} />
                    <Route path="/map" element={<MapMonitor />} />
                    <Route path="/rides" element={<Rides />} />
                    <Route path="/complaints" element={<Complaints />} />
                </Route>
                <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>

            <Footer />
        </BrowserRouter>
    );
}

function WorkspaceLayout() {
    return (
        <div className="layout">
            <Sidebar />
            <main className="content">
                <Outlet />
            </main>
        </div>
    );
}
