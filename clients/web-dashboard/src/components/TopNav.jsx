import React from "react";
import { NavLink } from "react-router-dom";

const links = [
  { to: "/", label: "Today" },
  { to: "/snow-profile", label: "Snow Profile" },
  { to: "/meteo", label: "Meteo 7d" },
  { to: "/history", label: "History" }
];

export default function TopNav() {
  return (
    <header className="topbar">
      <div className="brand">
        <span className="brand-dot" />
        AvalanCH-DT Explorer
      </div>
      <nav>
        {links.map((link) => (
          <NavLink
            key={link.to}
            to={link.to}
            className={({ isActive }) => (isActive ? "navlink active" : "navlink")}
          >
            {link.label}
          </NavLink>
        ))}
      </nav>
    </header>
  );
}
