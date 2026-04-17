import React from "react";
import { useEffect, useMemo, useState } from "react";
import {
  Area,
  AreaChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis
} from "recharts";
import { fetchJson } from "../lib/api";

function shortTs(ts) {
  return ts?.slice(5, 16).replace("T", " ") || "";
}

export default function MeteoPage() {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    fetchJson("/api/meteo?days=7")
      .then(setData)
      .catch((err) => setError(err.message || "Cannot load meteo"));
  }, []);

  const cards = useMemo(() => {
    if (!data?.summary) return [];
    return [
      { label: "Avg Temp", value: `${data.summary.avgTemperatureC ?? "-"} °C` },
      { label: "Temp Range", value: `${data.summary.minTemperatureC ?? "-"} to ${data.summary.maxTemperatureC ?? "-"} °C` },
      { label: "Avg Wind", value: `${data.summary.avgWind ?? "-"} m/s` },
      { label: "7d Precip", value: `${data.summary.totalPrecipitation ?? "-"} mm` },
      { label: "Max Snow Height", value: `${data.summary.maxHs ?? "-"} m` }
    ];
  }, [data]);

  return (
    <section className="page">
    
      {error ? <div className="panel error">{error}</div> : null}

      <div className="stats-grid">
        {cards.map((card) => (
          <article className="stat-card" key={card.label}>
            <h3>{card.label}</h3>
            <p>{card.value}</p>
          </article>
        ))}
      </div>

      <div className="panel chart-panel">
        <h3>Temperature & Snow Height</h3>
        <div className="chart-wrap">
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={data?.series || []}>
              <CartesianGrid strokeDasharray="2 4" />
              <XAxis dataKey="timestamp" tickFormatter={shortTs} minTickGap={35} />
              <YAxis yAxisId="left" />
              <YAxis yAxisId="right" orientation="right" />
              <Tooltip labelFormatter={shortTs} />
              <Legend />
              <Line yAxisId="left" type="monotone" dataKey="temperatureC" name="Temp (°C)" stroke="#c2410c" dot={false} />
              <Line yAxisId="right" type="monotone" dataKey="hs" name="Snow Height (m)" stroke="#0369a1" dot={false} />
            </LineChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="panel chart-panel">
        <h3>Precipitation & Wind</h3>
        <div className="chart-wrap">
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={data?.series || []}>
              <CartesianGrid strokeDasharray="2 4" />
              <XAxis dataKey="timestamp" tickFormatter={shortTs} minTickGap={35} />
              <YAxis />
              <Tooltip labelFormatter={shortTs} />
              <Legend />
              <Area type="monotone" dataKey="precipitation" name="Precip (mm)" stroke="#16a34a" fill="#86efac" />
              <Line type="monotone" dataKey="wind" name="Wind (m/s)" stroke="#6d28d9" dot={false} />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </div>
    </section>
  );
}
