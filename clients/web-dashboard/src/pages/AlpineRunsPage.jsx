import React from "react";
import { useEffect, useMemo, useState } from "react";
import { fetchJson, postJson } from "../lib/api";

function formatDate(value) {
  if (!value) return "-";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return String(value);
  return d.toLocaleString();
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "-";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export default function AlpineRunsPage() {
  const [status, setStatus] = useState(null);
  const [error, setError] = useState("");
  const [requestState, setRequestState] = useState({ loading: false, message: "", error: "" });

  useEffect(() => {
    let active = true;

    const load = async () => {
      try {
        const payload = await fetchJson("/api/alpine3d-run-status");
        if (!active) return;
        setStatus(payload);
        setError("");
      } catch (err) {
        if (!active) return;
        setError(err?.message || "Cannot load scheduler status");
      }
    };

    load();
    const id = setInterval(load, 30000);

    return () => {
      active = false;
      clearInterval(id);
    };
  }, []);

  async function triggerManualRun() {
    try {
      setRequestState({ loading: true, message: "", error: "" });
      const payload = await postJson("/api/alpine3d-run-status/trigger");
      setRequestState({ loading: false, message: payload.message || "Manual run requested.", error: "" });

      const refreshed = await fetchJson("/api/alpine3d-run-status");
      setStatus(refreshed);
    } catch (err) {
      setRequestState({ loading: false, message: "", error: err?.message || "Failed to request run." });
    }
  }

  const stateClass = useMemo(() => {
    const state = (status?.state || "unknown").toLowerCase();
    if (state === "success") return "ok";
    if (state === "running") return "running";
    if (state === "failed") return "failed";
    return "unknown";
  }, [status]);

  return (
    <section className="page">
      {error ? <div className="panel error">{error}</div> : null}

      <div className="panel run-status-header">
        <h2>Daily Alpine3D Publish Job</h2>
        <div className="run-status-actions">
          <div className={`status-pill ${stateClass}`}>{status?.state || "unknown"}</div>
          <button
            type="button"
            className="button run-now"
            onClick={triggerManualRun}
            disabled={requestState.loading}
          >
            {requestState.loading ? "Requesting..." : "Run Now"}
          </button>
        </div>
      </div>

      {requestState.message ? <div className="panel panel-info">{requestState.message}</div> : null}
      {requestState.error ? <div className="panel error">{requestState.error}</div> : null}

      <div className="stats-grid">
        <article className="stat-card">
          <h3>Last update</h3>
          <p>{formatDate(status?.updatedAt || status?.statusFileUpdatedAt)}</p>
        </article>
        <article className="stat-card">
          <h3>Next scheduled run</h3>
          <p>{formatDate(status?.nextRunAt)}</p>
        </article>
        <article className="stat-card">
          <h3>Last run duration</h3>
          <p>{formatDuration(status?.lastRun?.durationSec)}</p>
        </article>
        <article className="stat-card">
          <h3>Last exit code</h3>
          <p>{status?.lastRun?.exitCode ?? "-"}</p>
        </article>
      </div>

      <div className="panel">
        <h3>Run configuration</h3>
        <div className="metrics-inline">
          <span>Station: {status?.runConfig?.station ?? "-"}</span>
          <span>Days: {status?.runConfig?.days ?? "-"}</span>
          <span>Predict days: {status?.runConfig?.predictDays ?? "-"}</span>
          <span>Threads (np): {status?.runConfig?.np ?? "-"}</span>
          <span>Schedule (UTC): {status?.schedule?.timeUtc ?? "-"}</span>
        </div>
      </div>

      <div className="panel">
        <h3>Last run timeline</h3>
        <div className="metrics-inline">
          <span>Started: {formatDate(status?.lastRun?.startedAt)}</span>
          <span>Ended: {formatDate(status?.lastRun?.endedAt)}</span>
          <span>Status file: {status?.statusFile || "-"}</span>
        </div>
      </div>

      <div className="panel">
        <h3>Latest log tail</h3>
        <p className="legend-note">Showing the most recent lines captured by the scheduler.</p>
        <pre className="log-tail">{(status?.lastLog?.tail || []).join("\n") || "No log lines yet."}</pre>
      </div>
    </section>
  );
}
