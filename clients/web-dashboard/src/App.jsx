import React from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import TopNav from "./components/TopNav";
import HomePage from "./pages/HomePage";
import MeteoPage from "./pages/MeteoPage";
import ProfilePage from "./pages/ProfilePage";
import HistoryPage from "./pages/HistoryPage";
import AlpineRunsPage from "./pages/AlpineRunsPage";

export default function App() {
  return (
    <div className="app-shell">
      <TopNav />
      <main className="page-shell">
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/snow-profile" element={<ProfilePage />} />
          <Route path="/meteo" element={<MeteoPage />} />
          <Route path="/history" element={<HistoryPage />} />
          <Route path="/runs" element={<AlpineRunsPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}
