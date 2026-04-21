import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { RoadEyeDataProvider } from "./context/RoadEyeDataContext";
import "leaflet/dist/leaflet.css";
import "./styles.css";

ReactDOM.createRoot(document.getElementById("root")).render(
    <RoadEyeDataProvider>
        <App />
    </RoadEyeDataProvider>
);
