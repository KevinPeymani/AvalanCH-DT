import React from "react";
import { useEffect, useMemo, useState } from "react";
import {
  CartesianGrid,
  ComposedChart,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis
} from "recharts";
import { fetchJson } from "../lib/api";

function shortDate(ts) {
  return ts?.slice(0, 10) || "";
}

export default function HistoryPage() {
  const [data, setData] = useState([]);
  const [error, setError] = useState("");
  const [index, setIndex] = useState(0);

  useEffect(() => {
    fetchJson("/api/historical?days=120")
      .then((payload) => {
        const series = payload?.series || [];
        setData(series);
        setIndex(Math.max(0, series.length - 1));
      })
      .catch((err) => setError(err.message || "Cannot load historical data"));
  }, []);

  const selected = useMemo(() => {
    if (!data.length) return null;
    return data[Math.min(index, data.length - 1)];
  }, [data, index]);

  return (
    <section className="page">


      {error ? <div className="panel error">{error}</div> : null}

      <div className="panel chart-panel">
        <h3>Snow Height & Danger Through Time</h3>
        <div className="chart-wrap">
          <ResponsiveContainer width="100%" height="100%">
            <ComposedChart data={data}>
              <CartesianGrid strokeDasharray="2 4" />
              <XAxis dataKey="date" tickFormatter={shortDate} minTickGap={30} />
              <YAxis yAxisId="left" label={{ value: "HS (m)", angle: -90, position: "insideLeft" }} />
              <YAxis yAxisId="right" orientation="right" label={{ value: "Danger", angle: 90, position: "insideRight" }} />
              <Tooltip labelFormatter={shortDate} />
              <Line yAxisId="left" type="monotone" dataKey="hsMean" name="HS mean" stroke="#0284c7" dot={false} />
              <Line yAxisId="left" type="monotone" dataKey="hsMax" name="HS max" stroke="#0f766e" dot={false} />
              <Line yAxisId="right" type="monotone" dataKey="dangerMean" name="Danger mean" stroke="#dc2626" dot={false} />
              <Line yAxisId="right" type="monotone" dataKey="dangerMax" name="Danger max" stroke="#7f1d1d" dot={false} />
            </ComposedChart>
          </ResponsiveContainer>
        </div>
      </div>

      {selected ? (
        <>
          <div className="panel">
            <label htmlFor="timelineRange">Select day: {shortDate(selected.date)}</label>
            <input
              id="timelineRange"
              className="timeline"
              type="range"
              min={0}
              max={Math.max(0, data.length - 1)}
              value={index}
              onChange={(e) => setIndex(Number(e.target.value))}
            />
            <div className="metrics-inline">
              <span>HS mean: {selected.hsMean} m</span>
              <span>HS max: {selected.hsMax} m</span>
              <span>Danger mean: {selected.dangerMean}</span>
              <span>Danger max: {selected.dangerMax}</span>
            </div>
          </div>

          <div className="panel">
            <h3>Danger map preview ({shortDate(selected.date)})</h3>
            <img className="danger-preview" src={selected.dangerPreview} alt={`Danger preview ${shortDate(selected.date)}`} />
          </div>
        </>
      ) : (
        <div className="panel">Loading timeline...</div>
      )}
    </section>
  );
}
