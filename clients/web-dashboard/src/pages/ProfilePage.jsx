import React from "react";
import { useEffect, useState } from "react";
import { fetchJson } from "../lib/api";

export default function ProfilePage() {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    fetchJson("/api/profile/latest")
      .then(setData)
      .catch((err) => {
        setError(err.message || "Cannot fetch profile");
      });
  }, []);

  return (
    <section className="page">
    

      {error ? <div className="panel error">{error}</div> : null}

      {data ? (
        <>
          <div className="panel row">
            <div>
              <strong>Profile file:</strong> {data.fileName}
            </div>
            <div className="row-actions">
              <a className="button" href={data.niVizUrl} target="_blank" rel="noreferrer">
                Open in niViz
              </a>
              <a className="button ghost" href={data.profileUrl} target="_blank" rel="noreferrer">
                Raw .pro
              </a>
            </div>
          </div>

          <iframe className="niviz-frame" src={data.niVizUrl} title="niViz profile" />
        </>
      ) : (
        <div className="panel">Loading profile...</div>
      )}
    </section>
  );
}
