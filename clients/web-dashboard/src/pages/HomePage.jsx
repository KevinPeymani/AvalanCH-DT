import React from "react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { fetchJson } from "../lib/api";

export default function HomePage() {
  const mapRef = useRef(null);
  const mapContainerRef = useRef(null);
  const popupRef = useRef(null);
  const lastSampleAtRef = useRef(0);
  const terrainWasEnabledRef = useRef(false);
  const [config, setConfig] = useState(null);
  const [showDanger, setShowDanger] = useState(true);
  const [showHs, setShowHs] = useState(true);
  const [showTerrain, setShowTerrain] = useState(false);
  const [mapError, setMapError] = useState("");
  const [runStatus, setRunStatus] = useState(null);

  useEffect(() => {
    fetchJson("/api/runtime-config").then(setConfig).catch(console.error);
  }, []);

  useEffect(() => {
    let active = true;

    const loadRunStatus = async () => {
      try {
        const status = await fetchJson("/api/alpine3d-run-status");
        if (!active) return;
        setRunStatus(status);
      } catch {
        if (!active) return;
        setRunStatus(null);
      }
    };

    loadRunStatus();
    const id = setInterval(loadRunStatus, 60000);

    return () => {
      active = false;
      clearInterval(id);
    };
  }, []);

  const overlays = useMemo(() => {
    if (!config) return null;
    return {
      hsTiles: `/api/overlay/hs/tiles/{z}/{x}/{y}.png?t=${Date.now()}`,
      dangerTiles: `/api/overlay/danger/tiles/{z}/{x}/{y}.png?t=${Date.now()}`,
      maskTiles: `/api/overlay/mask/tiles/{z}/{x}/{y}.png?t=${Date.now()}`
    };
  }, [config]);

  useEffect(() => {
    if (!mapContainerRef.current || !overlays || mapRef.current) {
      return;
    }

    let map;
    try {
      map = new maplibregl.Map({
        container: mapContainerRef.current,
        style: {
          version: 8,
          sources: {
            osm: {
              type: "raster",
              tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
              tileSize: 256,
              attribution: "© OpenStreetMap"
            },
            danger: {
              type: "raster",
              tiles: [overlays.dangerTiles],
              tileSize: 256
            },
            mask: {
              type: "raster",
              tiles: [overlays.maskTiles],
              tileSize: 256
            },
            hs: {
              type: "raster",
              tiles: [overlays.hsTiles],
              tileSize: 256
            }
          },
          layers: [
            {
              id: "osm",
              type: "raster",
              source: "osm",
              paint: {
                "raster-brightness-max": 0.82,
                "raster-saturation": -0.3
              }
            },
            { id: "mask", type: "raster", source: "mask", paint: { "raster-opacity": 1 } },
            { id: "danger", type: "raster", source: "danger", paint: { "raster-opacity": 0.78 } },
            { id: "hs", type: "raster", source: "hs", paint: { "raster-opacity": 0.62 } }
          ]
        },
        center: [7.75, 46.02],
        zoom: 10,
        pitch: 38,
        bearing: -8
      });
    } catch (err) {
      setMapError(err?.message || "Map could not initialize in this browser.");
      return undefined;
    }

    map.on("error", (event) => {
      if (event?.sourceId === "dem") {
        map.setTerrain(null);
        setShowTerrain(false);
        setMapError("3D terrain failed to load, so the map was returned to 2D mode.");
        return;
      }

      setMapError("Some map layers failed to load. Check local raster files and DEM configuration.");
    });

    if (Array.isArray(config.mapBounds) && config.mapBounds.length === 4) {
      map.setMaxBounds([
        [config.mapBounds[0], config.mapBounds[1]],
        [config.mapBounds[2], config.mapBounds[3]]
      ]);

      map.fitBounds(
        [
          [config.mapBounds[0], config.mapBounds[1]],
          [config.mapBounds[2], config.mapBounds[3]]
        ],
        { padding: 28, duration: 0 }
      );
    }

    map.addControl(new maplibregl.NavigationControl(), "top-right");

    const onMouseMove = async (evt) => {
      const now = Date.now();
      if (now - lastSampleAtRef.current < 160) {
        return;
      }
      lastSampleAtRef.current = now;

      const lon = evt.lngLat.lng;
      const lat = evt.lngLat.lat;

      try {
        const sample = await fetchJson(`/api/sample?lon=${lon}&lat=${lat}`);

        if (!popupRef.current) {
          popupRef.current = new maplibregl.Popup({
            closeButton: false,
            closeOnClick: false,
            offset: 10
          });
        }

        const body = sample.inData
          ? `Danger: <strong>${sample.dangerLevel ?? "-"}</strong><br/>Snow height: <strong>${sample.snowHeight ?? "-"} m</strong>`
          : "No local data";

        popupRef.current
          .setLngLat([lon, lat])
          .setHTML(`<div style=\"font-size:12px;line-height:1.35\">${body}</div>`)
          .addTo(map);
      } catch {
        // Ignore transient tooltip sampling failures.
      }
    };

    const onMouseLeave = () => {
      if (popupRef.current) {
        popupRef.current.remove();
      }
    };

    map.on("mousemove", onMouseMove);
    map.on("mouseleave", onMouseLeave);

    mapRef.current = map;

    return () => {
      map.off("mousemove", onMouseMove);
      map.off("mouseleave", onMouseLeave);
      if (popupRef.current) {
        popupRef.current.remove();
      }
      map.remove();
      mapRef.current = null;
    };
  }, [overlays, config]);

  useEffect(() => {
    if (!mapRef.current) return;
    mapRef.current.setLayoutProperty("danger", "visibility", showDanger ? "visible" : "none");
  }, [showDanger]);

  useEffect(() => {
    if (!mapRef.current) return;
    mapRef.current.setLayoutProperty("hs", "visibility", showHs ? "visible" : "none");
  }, [showHs]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;

    const hasDemSource = Boolean(map.getSource("dem"));

    if (!showTerrain) {
      if (map.getTerrain()) {
        map.setTerrain(null);
      }

      if (terrainWasEnabledRef.current) {
        map.easeTo({ pitch: 0, bearing: 0, duration: 700 });
        terrainWasEnabledRef.current = false;
      }
      return;
    }

    if (!config?.demTilesUrl) {
      setMapError("3D terrain is unavailable because no DEM tile source is configured.");
      return;
    }

    try {
      if (!hasDemSource) {
        map.addSource("dem", {
          type: "raster-dem",
          tiles: [config.demTilesUrl],
          encoding: "mapbox",
          tileSize: 256,
          maxzoom: 14
        });
      }

      map.setTerrain({ source: "dem", exaggeration: 1.08 });
      map.easeTo({ pitch: 55, bearing: -15, duration: 800 });
      terrainWasEnabledRef.current = true;
    } catch (err) {
      setShowTerrain(false);
      setMapError(err?.message || "Could not enable 3D terrain.");
    }
  }, [config, showTerrain]);

  return (
    <section className="page today-page">
      {runStatus?.state === "failed" ? (
        <div className="panel scheduler-alert failed">
          Last Alpine3D publish run failed at {runStatus.lastRun?.endedAt || runStatus.updatedAt || "unknown time"}. Check <Link to="/runs">Runs</Link> for logs and retry.
        </div>
      ) : null}

      {runStatus?.state === "running" ? (
        <div className="panel scheduler-alert running">
          Alpine3D publish is currently running. Live details are available on <Link to="/runs">Runs</Link>.
        </div>
      ) : null}

      {mapError ? <div className="panel error">{mapError}</div> : null}

      <div className="controls-row">
        <label>
          <input type="checkbox" checked={showDanger} onChange={(e) => setShowDanger(e.target.checked)} />
          Avalanche danger
        </label>
        <label>
          <input type="checkbox" checked={showHs} onChange={(e) => setShowHs(e.target.checked)} />
          Snow height
        </label>
        <label>
          <input type="checkbox" checked={showTerrain} onChange={(e) => setShowTerrain(e.target.checked)} />
          3D terrain
        </label>
      </div>

      <div className="map-layout">
        <div ref={mapContainerRef} className="map-canvas" />

        <aside className="panel legend-panel legend-panel-side">
          <h3>Color Legend</h3>
          <div className="legend-grid">
            <div>
              <h4>Avalanche Danger (1-5)</h4>
              <ul className="legend-list">
                <li><span className="swatch" style={{ background: "#8dd3c7" }} />1 Low</li>
                <li><span className="swatch" style={{ background: "#ffffb3" }} />2 Moderate</li>
                <li><span className="swatch" style={{ background: "#fed976" }} />3 Considerable</li>
                <li><span className="swatch" style={{ background: "#fd8d3c" }} />4 High</li>
                <li><span className="swatch" style={{ background: "#e31a1c" }} />5 Very High</li>
              </ul>
            </div>
            <div>
              <h4>Snow Height (m)</h4>
              <ul className="legend-list">
                <li><span className="swatch" style={{ background: "#edf8fb" }} />0 - 0.5</li>
                <li><span className="swatch" style={{ background: "#b3cde3" }} />0.5 - 1.0</li>
                <li><span className="swatch" style={{ background: "#8c96c6" }} />1.0 - 1.5</li>
                <li><span className="swatch" style={{ background: "#8856a7" }} />1.5 - 2.0</li>
                <li><span className="swatch" style={{ background: "#810f7c" }} />2.0+</li>
              </ul>
            </div>
          </div>
        </aside>
      </div>
    </section>
  );
}
