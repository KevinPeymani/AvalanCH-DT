import express from "express";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";
import { fromArrayBuffer } from "geotiff";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = process.env.WORKSPACE_ROOT || path.resolve(__dirname, "..", "..", "..");

const app = express();
const port = Number(process.env.PORT || 8090);

const alpineOutputDir = process.env.ALPINE_OUTPUT_DIR || path.join(projectRoot, "Alpine3D", "output");
const dangerOutputDir = process.env.DANGER_OUTPUT_DIR || path.join(alpineOutputDir, "grid_predictions");
const smetFile = process.env.SMET_FILE || path.join(projectRoot, "Alpine3D", "input", "ZER2.smet");
const profileDir = process.env.PROFILE_DIR || path.join(projectRoot, "prediction", "output");

const geoserverBaseUrl = process.env.GEOSERVER_BASE_URL || "http://localhost:8081/geoserver";
const geoserverInternalBaseUrl =
  process.env.GEOSERVER_INTERNAL_BASE_URL ||
  (geoserverBaseUrl.includes("localhost")
    ? "http://geoserver:8080/geoserver"
    : geoserverBaseUrl);
const geoserverWorkspace = process.env.GEOSERVER_WORKSPACE || "avalanch";
const hsLayer = process.env.GEOSERVER_HS_LAYER || "hs_latest";
const dangerLayer = process.env.GEOSERVER_DANGER_LAYER || "danger_latest";
const hsStyle = process.env.GEOSERVER_HS_STYLE || "";
const dangerStyle = process.env.GEOSERVER_DANGER_STYLE || "";
const demTilesUrl = process.env.DEM_TILES_URL || "";
const demAscFile =
  process.env.DEM_ASC_FILE ||
  path.join(projectRoot, "Alpine3D", "prep", "surface_grids", "dem_50m.asc");
const demTifFile =
  process.env.DEM_TIF_FILE ||
  path.join(projectRoot, "Alpine3D", "prep", "dem_50m.tif");
const mapBounds = process.env.MAP_BOUNDS || "7.45,45.85,8.15,46.2";

const distPath = path.resolve(__dirname, "..", "dist");
const defaultDemTilesPath = "/api/dem/tiles/{z}/{x}/{y}.png";

let demCache = null;
let demCacheMtimeMs = 0;
let demCacheSource = "";
const overlayGridCache = {
  danger: { filePath: "", mtimeMs: 0, grid: null },
  hs: { filePath: "", mtimeMs: 0, grid: null }
};

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  next();
});

app.use("/historical/danger", express.static(dangerOutputDir));
app.use("/profiles", express.static(profileDir));

function parseAscStats(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/).filter(Boolean);
  if (lines.length < 7) {
    return null;
  }

  const header = {};
  for (let i = 0; i < 6; i += 1) {
    const [k, v] = lines[i].trim().split(/\s+/);
    header[k.toLowerCase()] = Number(v);
  }

  const nodata = Number.isFinite(header.nodata_value) ? header.nodata_value : -9999;
  let count = 0;
  let sum = 0;
  let min = Number.POSITIVE_INFINITY;
  let max = Number.NEGATIVE_INFINITY;

  for (let i = 6; i < lines.length; i += 1) {
    const tokens = lines[i].trim().split(/\s+/);
    for (const token of tokens) {
      const value = Number(token);
      if (!Number.isFinite(value) || value === nodata) {
        continue;
      }
      count += 1;
      sum += value;
      if (value < min) min = value;
      if (value > max) max = value;
    }
  }

  if (count === 0) {
    return null;
  }

  return {
    mean: Number((sum / count).toFixed(3)),
    min: Number(min.toFixed(3)),
    max: Number(max.toFixed(3))
  };
}

function parseAscGrid(filePath) {
  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  if (lines.length < 7) {
    return null;
  }

  const header = {};
  for (let i = 0; i < 6; i += 1) {
    const [k, v] = lines[i].trim().split(/\s+/);
    header[k.toLowerCase()] = Number(v);
  }

  const ncols = Number(header.ncols);
  const nrows = Number(header.nrows);
  const nodata = Number.isFinite(header.nodata_value) ? header.nodata_value : -9999;
  if (!Number.isFinite(ncols) || !Number.isFinite(nrows) || ncols <= 0 || nrows <= 0) {
    return null;
  }

  const data = new Float32Array(ncols * nrows);
  let minValid = Number.POSITIVE_INFINITY;
  let y = 0;
  for (let i = 6; i < lines.length && y < nrows; i += 1) {
    const row = lines[i].trim().split(/\s+/);
    if (row.length < ncols) {
      continue;
    }
    for (let x = 0; x < ncols; x += 1) {
      const value = Number(row[x]);
      const isValid = Number.isFinite(value) && value !== nodata;
      data[y * ncols + x] = isValid ? value : NaN;
      if (isValid && value < minValid) {
        minValid = value;
      }
    }
    y += 1;
  }

  return {
    ncols,
    nrows,
    nodata,
    data,
    minValid: Number.isFinite(minValid) ? minValid : 0
  };
}

async function parseTifGrid(filePath) {
  const buffer = fs.readFileSync(filePath);
  const ab = buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
  const tiff = await fromArrayBuffer(ab);
  const image = await tiff.getImage();
  const width = image.getWidth();
  const height = image.getHeight();
  const noDataRaw = image.getGDALNoData();
  const nodata = Number.isFinite(Number(noDataRaw)) ? Number(noDataRaw) : NaN;
  const raster = await image.readRasters({ interleave: true });

  const data = new Float32Array(width * height);
  let minValid = Number.POSITIVE_INFINITY;
  for (let i = 0; i < raster.length; i += 1) {
    const value = Number(raster[i]);
    const isValid = Number.isFinite(value) && (!Number.isFinite(nodata) || value !== nodata);
    data[i] = isValid ? value : NaN;
    if (isValid && value < minValid) {
      minValid = value;
    }
  }

  return {
    ncols: width,
    nrows: height,
    nodata,
    data,
    minValid: Number.isFinite(minValid) ? minValid : 0
  };
}

async function loadDemGrid() {
  const ascExists = fs.existsSync(demAscFile);
  const tifExists = fs.existsSync(demTifFile);
  if (!ascExists && !tifExists) {
    return null;
  }

  const source = ascExists ? demAscFile : demTifFile;
  const st = fs.statSync(source);
  if (!demCache || st.mtimeMs !== demCacheMtimeMs || demCacheSource !== source) {
    demCache = ascExists ? parseAscGrid(demAscFile) : await parseTifGrid(demTifFile);
    demCacheMtimeMs = st.mtimeMs;
    demCacheSource = source;
  }

  return demCache;
}

function clamp(v, min, max) {
  return Math.max(min, Math.min(max, v));
}

function tileToLonLat(x, y, z) {
  const n = 2 ** z;
  const lon = (x / n) * 360 - 180;
  const latRad = Math.atan(Math.sinh(Math.PI * (1 - (2 * y) / n)));
  const lat = (latRad * 180) / Math.PI;
  return [lon, lat];
}

function encodeTerrainRgb(heightMeters) {
  const safe = Number.isFinite(heightMeters) ? heightMeters : 0;
  const encoded = Math.round((safe + 10000) * 10);
  const r = clamp(Math.floor(encoded / (256 * 256)), 0, 255);
  const g = clamp(Math.floor((encoded - r * 256 * 256) / 256), 0, 255);
  const b = clamp(encoded - r * 256 * 256 - g * 256, 0, 255);
  return [r, g, b, 255];
}

function sampleDemByLonLat(grid, lon, lat, bounds) {
  const [minLon, minLat, maxLon, maxLat] = bounds;
  if (maxLon <= minLon || maxLat <= minLat) {
    return NaN;
  }

  const fx = (lon - minLon) / (maxLon - minLon);
  const fy = (maxLat - lat) / (maxLat - minLat);
  if (!Number.isFinite(fx) || !Number.isFinite(fy) || fx < 0 || fx > 1 || fy < 0 || fy > 1) {
    return NaN;
  }

  const x = clamp(Math.round(fx * (grid.ncols - 1)), 0, grid.ncols - 1);
  const y = clamp(Math.round(fy * (grid.nrows - 1)), 0, grid.nrows - 1);
  return grid.data[y * grid.ncols + x];
}

function sampleAscByLonLat(grid, lon, lat, bounds) {
  const [minLon, minLat, maxLon, maxLat] = bounds;
  if (maxLon <= minLon || maxLat <= minLat) {
    return NaN;
  }

  const fx = (lon - minLon) / (maxLon - minLon);
  const fy = (maxLat - lat) / (maxLat - minLat);
  if (!Number.isFinite(fx) || !Number.isFinite(fy) || fx < 0 || fx > 1 || fy < 0 || fy > 1) {
    return NaN;
  }

  const x = clamp(Math.round(fx * (grid.ncols - 1)), 0, grid.ncols - 1);
  const y = clamp(Math.round(fy * (grid.nrows - 1)), 0, grid.nrows - 1);
  return grid.data[y * grid.ncols + x];
}

function loadLatestOverlayGrid(kind) {
  if (kind !== "danger" && kind !== "hs") {
    return null;
  }

  const dirPath = kind === "danger" ? dangerOutputDir : alpineOutputDir;
  const suffix = kind === "danger" ? "_danger.asc" : "_HS.asc";
  const latest = findLatestBySuffix(dirPath, suffix);
  if (!latest) {
    return null;
  }

  const cache = overlayGridCache[kind];
  if (cache.filePath === latest.fullPath && cache.mtimeMs === latest.mtimeMs && cache.grid) {
    return cache.grid;
  }

  const grid = parseAscGrid(latest.fullPath);
  if (!grid) {
    return null;
  }

  cache.filePath = latest.fullPath;
  cache.mtimeMs = latest.mtimeMs;
  cache.grid = grid;
  return grid;
}

function listDatedFiles(dirPath, suffix) {
  if (!fs.existsSync(dirPath)) {
    return [];
  }

  return fs
    .readdirSync(dirPath)
    .filter((name) => name.endsWith(suffix))
    .map((name) => ({
      fileName: name,
      dateKey: name.slice(0, 19)
    }))
    .sort((a, b) => a.dateKey.localeCompare(b.dateKey));
}

function parseSmet(filePath) {
  if (!fs.existsSync(filePath)) {
    return [];
  }

  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/);

  let inData = false;
  let fields = [];
  const records = [];

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;

    if (line.startsWith("fields")) {
      const idx = line.indexOf("=");
      if (idx > -1) {
        fields = line
          .slice(idx + 1)
          .trim()
          .split(/\s+/)
          .map((f) => f.trim());
      }
      continue;
    }

    if (line === "[DATA]") {
      inData = true;
      continue;
    }

    if (!inData || line.startsWith("#")) {
      continue;
    }

    const parts = line.split(/\s+/);
    if (fields.length === 0 || parts.length < fields.length) {
      continue;
    }

    const row = {};
    fields.forEach((field, idx) => {
      row[field] = idx === 0 ? parts[idx] : Number(parts[idx]);
    });
    records.push(row);
  }

  return records;
}

function findLatestBySuffix(dirPath, suffix) {
  if (!fs.existsSync(dirPath)) {
    return null;
  }

  const candidates = fs
    .readdirSync(dirPath)
    .filter((name) => name.endsWith(suffix))
    .map((name) => {
      const fullPath = path.join(dirPath, name);
      const st = fs.statSync(fullPath);
      return { name, fullPath, mtimeMs: st.mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  return candidates[0] || null;
}

function colorDangerFromGray(gray) {
  if (!Number.isFinite(gray) || gray <= 0) {
    return [0, 0, 0, 0];
  }

  const level = Math.max(1, Math.min(5, Math.round((gray / 255) * 5)));
  if (level === 1) return [141, 211, 199, 210];
  if (level === 2) return [255, 255, 179, 210];
  if (level === 3) return [254, 217, 118, 215];
  if (level === 4) return [253, 141, 60, 220];
  return [227, 26, 28, 225];
}

function colorDangerFromValue(value) {
  if (!Number.isFinite(value) || value <= 0) {
    return [0, 0, 0, 0];
  }

  const level = Math.max(1, Math.min(5, Math.round(value)));
  if (level === 1) return [141, 211, 199, 210];
  if (level === 2) return [255, 255, 179, 210];
  if (level === 3) return [254, 217, 118, 215];
  if (level === 4) return [253, 141, 60, 220];
  return [227, 26, 28, 225];
}

function colorSnowFromValue(value) {
  if (!Number.isFinite(value) || value <= 0) {
    return [0, 0, 0, 0];
  }
  if (value < 0.5) return [237, 248, 251, 205];
  if (value < 1.0) return [179, 205, 227, 210];
  if (value < 1.5) return [140, 150, 198, 215];
  if (value < 2.0) return [136, 86, 167, 220];
  return [129, 15, 124, 225];
}

function colorSnowFromGray(gray) {
  if (!Number.isFinite(gray) || gray <= 0) {
    return [0, 0, 0, 0];
  }
  const approxMeters = (gray / 255) * 2.5;
  return colorSnowFromValue(approxMeters);
}

function colorizePngBuffer(inputBuffer, paletteFn) {
  const src = PNG.sync.read(inputBuffer);
  const out = new PNG({ width: src.width, height: src.height });

  for (let i = 0; i < src.data.length; i += 4) {
    const r = src.data[i];
    const g = src.data[i + 1];
    const b = src.data[i + 2];
    const a = src.data[i + 3];

    if (a === 0) {
      out.data[i] = 0;
      out.data[i + 1] = 0;
      out.data[i + 2] = 0;
      out.data[i + 3] = 0;
      continue;
    }

    const gray = Math.round((r + g + b) / 3);
    const [or, og, ob, oa] = paletteFn(gray);
    out.data[i] = or;
    out.data[i + 1] = og;
    out.data[i + 2] = ob;
    out.data[i + 3] = oa;
  }

  return PNG.sync.write(out);
}

function colorizeAscBuffer(filePath, paletteFn, options = {}) {
  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  if (lines.length < 7) {
    return null;
  }

  const header = {};
  for (let i = 0; i < 6; i += 1) {
    const [k, v] = lines[i].trim().split(/\s+/);
    header[k.toLowerCase()] = Number(v);
  }

  const ncols = header.ncols;
  const nrows = header.nrows;
  const nodata = Number.isFinite(header.nodata_value) ? header.nodata_value : -9999;
  const nodataColor = options.nodataColor || [0, 0, 0, 0];
  if (!Number.isFinite(ncols) || !Number.isFinite(nrows)) {
    return null;
  }

  const png = new PNG({ width: ncols, height: nrows });
  let y = 0;

  for (let i = 6; i < lines.length && y < nrows; i += 1) {
    const values = lines[i].trim().split(/\s+/).map(Number);
    if (values.length < ncols) {
      continue;
    }

    for (let x = 0; x < ncols; x += 1) {
      const v = values[x];
      const idx = (y * ncols + x) * 4;
      const [r, g, b, a] =
        Number.isFinite(v) && v !== nodata ? paletteFn(v) : nodataColor;
      png.data[idx] = r;
      png.data[idx + 1] = g;
      png.data[idx + 2] = b;
      png.data[idx + 3] = a;
    }

    y += 1;
  }

  return PNG.sync.write(png);
}

function isTempKelvin(value) {
  return Number.isFinite(value) && value > 150;
}

function kToC(value) {
  return value - 273.15;
}

app.get("/api/runtime-config", (_req, res) => {
  const demFileExists = fs.existsSync(demAscFile) || fs.existsSync(demTifFile);
  res.json({
    geoserverBaseUrl,
    geoserverWorkspace,
    hsLayer,
    dangerLayer,
    hsStyle,
    dangerStyle,
    demTilesUrl: demTilesUrl || (demFileExists ? defaultDemTilesPath : ""),
    demAscFile,
    demTifFile,
    mapBounds: mapBounds.split(",").map(Number)
  });
});

app.get("/api/sample", (req, res) => {
  const lon = Number(req.query.lon);
  const lat = Number(req.query.lat);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    res.status(400).json({ error: "lon and lat query params are required" });
    return;
  }

  const bounds = mapBounds.split(",").map(Number);
  if (bounds.length !== 4 || bounds.some((v) => !Number.isFinite(v))) {
    res.status(500).json({ error: "invalid MAP_BOUNDS" });
    return;
  }

  const dangerGrid = loadLatestOverlayGrid("danger");
  const hsGrid = loadLatestOverlayGrid("hs");

  const dangerRaw = dangerGrid ? sampleAscByLonLat(dangerGrid, lon, lat, bounds) : NaN;
  const hsRaw = hsGrid ? sampleAscByLonLat(hsGrid, lon, lat, bounds) : NaN;

  const danger = Number.isFinite(dangerRaw) && dangerRaw > 0 ? Number(dangerRaw.toFixed(2)) : null;
  const snowHeight = Number.isFinite(hsRaw) && hsRaw > 0 ? Number(hsRaw.toFixed(3)) : null;
  const inData = danger !== null || snowHeight !== null;

  res.json({
    lon: Number(lon.toFixed(6)),
    lat: Number(lat.toFixed(6)),
    danger,
    dangerLevel: danger !== null ? Math.max(1, Math.min(5, Math.round(danger))) : null,
    snowHeight,
    inData
  });
});

app.get("/api/geoserver/wms", async (req, res) => {
  try {
    const upstream = new URL(`${geoserverInternalBaseUrl}/wms`);
    for (const [key, value] of Object.entries(req.query)) {
      if (Array.isArray(value)) {
        value.forEach((item) => upstream.searchParams.append(key, String(item)));
      } else if (value !== undefined) {
        upstream.searchParams.set(key, String(value));
      }
    }

    const response = await fetch(upstream, {
      headers: {
        Accept: "image/png,image/*;q=0.9,*/*;q=0.8"
      }
    });

    if (!response.ok) {
      const text = await response.text();
      res.status(response.status).send(text || "GeoServer WMS request failed");
      return;
    }

    const arrayBuffer = await response.arrayBuffer();
    const contentType = response.headers.get("content-type") || "image/png";
    res.setHeader("Content-Type", contentType);
    res.setHeader("Cache-Control", "public, max-age=60");
    res.send(Buffer.from(arrayBuffer));
  } catch (error) {
    res.status(502).json({
      error: error instanceof Error ? error.message : "Failed to proxy GeoServer WMS request"
    });
  }
});

app.get("/api/dem/tiles/:z/:x/:y.png", async (req, res) => {
  const z = Number(req.params.z);
  const x = Number(req.params.x);
  const y = Number(req.params.y);
  if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y) || z < 0) {
    res.status(400).json({ error: "invalid tile coordinates" });
    return;
  }

  const grid = await loadDemGrid();
  if (!grid) {
    res.status(404).json({ error: "no DEM file found (ASC/TIF)" });
    return;
  }

  const bounds = mapBounds.split(",").map(Number);
  if (bounds.length !== 4 || bounds.some((v) => !Number.isFinite(v))) {
    res.status(500).json({ error: "invalid MAP_BOUNDS" });
    return;
  }

  const size = 256;
  const png = new PNG({ width: size, height: size });
  const fallbackElevation = Number.isFinite(grid.minValid) ? grid.minValid : 0;

  const [tileMinLon, tileMaxLat] = tileToLonLat(x, y, z);
  const [tileMaxLon, tileMinLat] = tileToLonLat(x + 1, y + 1, z);

  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      const u = (px + 0.5) / size;
      const v = (py + 0.5) / size;
      const lon = tileMinLon + u * (tileMaxLon - tileMinLon);
      const lat = tileMaxLat + v * (tileMinLat - tileMaxLat);
      const elev = sampleDemByLonLat(grid, lon, lat, bounds);

      const idx = (py * size + px) * 4;
      const [r, g, b, a] = encodeTerrainRgb(Number.isFinite(elev) ? elev : fallbackElevation);
      png.data[idx] = r;
      png.data[idx + 1] = g;
      png.data[idx + 2] = b;
      png.data[idx + 3] = a;
    }
  }

  res.setHeader("Content-Type", "image/png");
  res.setHeader("Cache-Control", "public, max-age=60");
  res.send(PNG.sync.write(png));
});

app.get("/api/overlay/:kind/tiles/:z/:x/:y.png", (req, res) => {
  const { kind } = req.params;
  const z = Number(req.params.z);
  const x = Number(req.params.x);
  const y = Number(req.params.y);

  if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y) || z < 0) {
    res.status(400).json({ error: "invalid tile coordinates" });
    return;
  }

  const bounds = mapBounds.split(",").map(Number);
  if (bounds.length !== 4 || bounds.some((v) => !Number.isFinite(v))) {
    res.status(500).json({ error: "invalid MAP_BOUNDS" });
    return;
  }

  const dangerGrid = loadLatestOverlayGrid("danger");
  const hsGrid = loadLatestOverlayGrid("hs");
  let grid = null;
  if (kind === "danger") {
    grid = dangerGrid;
  } else if (kind === "hs") {
    grid = hsGrid;
  } else if (kind === "mask") {
    grid = dangerGrid || hsGrid;
  }

  if (!grid) {
    res.status(404).json({ error: `no ${kind} asc raster found` });
    return;
  }

  const size = 256;
  const png = new PNG({ width: size, height: size });
  const [tileMinLon, tileMaxLat] = tileToLonLat(x, y, z);
  const [tileMaxLon, tileMinLat] = tileToLonLat(x + 1, y + 1, z);

  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      const u = (px + 0.5) / size;
      const v = (py + 0.5) / size;
      const lon = tileMinLon + u * (tileMaxLon - tileMinLon);
      const lat = tileMaxLat + v * (tileMinLat - tileMaxLat);
      const value = sampleAscByLonLat(grid, lon, lat, bounds);

      let color;
      if (kind === "danger") {
        color = Number.isFinite(value) && value > 0 ? colorDangerFromValue(value) : [0, 0, 0, 0];
      } else if (kind === "hs") {
        color = Number.isFinite(value) && value > 0 ? colorSnowFromValue(value) : [0, 0, 0, 0];
      } else {
        color = Number.isFinite(value) && value > 0 ? [0, 0, 0, 0] : [0, 0, 0, 255];
      }

      const idx = (py * size + px) * 4;
      png.data[idx] = color[0];
      png.data[idx + 1] = color[1];
      png.data[idx + 2] = color[2];
      png.data[idx + 3] = color[3];
    }
  }

  res.setHeader("Content-Type", "image/png");
  res.setHeader("Cache-Control", "public, max-age=30");
  res.send(PNG.sync.write(png));
});

app.get("/api/overlay/:kind/latest.png", (req, res) => {
  const { kind } = req.params;

  if (kind === "mask") {
    const latestDangerAsc = findLatestBySuffix(dangerOutputDir, "_danger.asc");
    const latestHsAsc = findLatestBySuffix(alpineOutputDir, "_HS.asc");
    const source = latestDangerAsc || latestHsAsc;

    if (!source) {
      res.status(404).json({ error: "no mask raster found" });
      return;
    }

    const mask = colorizeAscBuffer(
      source.fullPath,
      () => [0, 0, 0, 0],
      { nodataColor: [0, 0, 0, 255] }
    );

    if (!mask) {
      res.status(500).json({ error: "failed to build no-data mask" });
      return;
    }

    res.setHeader("Content-Type", "image/png");
    res.setHeader("Cache-Control", "no-store");
    res.send(mask);
    return;
  }

  if (kind === "danger") {
    const latestAsc = findLatestBySuffix(dangerOutputDir, "_danger.asc");
    if (latestAsc) {
      const colored = colorizeAscBuffer(latestAsc.fullPath, colorDangerFromValue);
      if (!colored) {
        res.status(500).json({ error: "failed to colorize danger asc" });
        return;
      }

      res.setHeader("Content-Type", "image/png");
      res.setHeader("Cache-Control", "no-store");
      res.send(colored);
      return;
    }

    const latestPng = findLatestBySuffix(dangerOutputDir, "_danger.png");
    if (!latestPng) {
      res.status(404).json({ error: "no danger raster found" });
      return;
    }

    const raw = fs.readFileSync(latestPng.fullPath);
    const colored = colorizePngBuffer(raw, colorDangerFromGray);
    res.setHeader("Content-Type", "image/png");
    res.setHeader("Cache-Control", "no-store");
    res.send(colored);
    return;
  }

  if (kind === "hs") {
    const latestHsPng = findLatestBySuffix(alpineOutputDir, "_HS.png");
    if (latestHsPng) {
      const raw = fs.readFileSync(latestHsPng.fullPath);
      const colored = colorizePngBuffer(raw, colorSnowFromGray);
      res.setHeader("Content-Type", "image/png");
      res.setHeader("Cache-Control", "no-store");
      res.send(colored);
      return;
    }

    const latestHsAsc = findLatestBySuffix(alpineOutputDir, "_HS.asc");
    if (!latestHsAsc) {
      res.status(404).json({ error: "no hs raster found" });
      return;
    }

    const colored = colorizeAscBuffer(latestHsAsc.fullPath, colorSnowFromValue);
    if (!colored) {
      res.status(500).json({ error: "failed to colorize hs asc" });
      return;
    }

    res.setHeader("Content-Type", "image/png");
    res.setHeader("Cache-Control", "no-store");
    res.send(colored);
    return;
  }

  res.status(400).json({ error: "kind must be danger or hs" });
});

app.get("/api/historical", (req, res) => {
  const days = Number(req.query.days || 30);
  const hsFiles = listDatedFiles(alpineOutputDir, "_HS.asc");
  const dangerFiles = listDatedFiles(dangerOutputDir, "_danger.asc");

  const dangerByDate = new Map(dangerFiles.map((f) => [f.dateKey, f]));
  const rows = hsFiles
    .map((hs) => {
      const danger = dangerByDate.get(hs.dateKey);
      if (!danger) {
        return null;
      }

      const hsStats = parseAscStats(path.join(alpineOutputDir, hs.fileName));
      const dangerStats = parseAscStats(path.join(dangerOutputDir, danger.fileName));
      if (!hsStats || !dangerStats) {
        return null;
      }

      const dangerPng = danger.fileName.replace(/\.asc$/, ".png");

      return {
        date: hs.dateKey,
        hsMean: hsStats.mean,
        hsMax: hsStats.max,
        dangerMean: dangerStats.mean,
        dangerMax: dangerStats.max,
        dangerPreview: `/historical/danger/${dangerPng}`
      };
    })
    .filter(Boolean);

  const trimmed = rows.slice(Math.max(0, rows.length - days));
  res.json({
    count: trimmed.length,
    series: trimmed
  });
});

app.get("/api/meteo", (req, res) => {
  const days = Number(req.query.days || 7);
  const rows = parseSmet(smetFile);
  if (rows.length === 0) {
    res.json({
      stationFile: smetFile,
      series: [],
      summary: null
    });
    return;
  }

  const timestamps = rows.map((r) => new Date(r.timestamp).getTime()).filter(Number.isFinite);
  const maxTs = Math.max(...timestamps);
  const minTs = maxTs - days * 24 * 60 * 60 * 1000;

  const filtered = rows.filter((row) => {
    const ts = new Date(row.timestamp).getTime();
    return Number.isFinite(ts) && ts >= minTs;
  });

  const series = filtered.map((row) => {
    const ta = Number(row.TA);
    const tempC = isTempKelvin(ta) ? kToC(ta) : ta;

    return {
      timestamp: row.timestamp,
      temperatureC: Number(tempC.toFixed(2)),
      hs: Number.isFinite(row.HS) ? row.HS : null,
      wind: Number.isFinite(row.VW) ? row.VW : null,
      precipitation: Number.isFinite(row.PSUM) ? row.PSUM : null,
      humidityPct: Number.isFinite(row.RH) ? Number((row.RH * 100).toFixed(1)) : null
    };
  });

  const metric = (key) => series.map((d) => d[key]).filter(Number.isFinite);
  const avg = (arr) => (arr.length ? Number((arr.reduce((a, b) => a + b, 0) / arr.length).toFixed(2)) : null);

  const summary = {
    avgTemperatureC: avg(metric("temperatureC")),
    avgWind: avg(metric("wind")),
    totalPrecipitation: Number(metric("precipitation").reduce((a, b) => a + b, 0).toFixed(2)),
    minTemperatureC: metric("temperatureC").length ? Math.min(...metric("temperatureC")) : null,
    maxTemperatureC: metric("temperatureC").length ? Math.max(...metric("temperatureC")) : null,
    maxHs: metric("hs").length ? Math.max(...metric("hs")) : null
  };

  res.json({
    stationFile: smetFile,
    points: series.length,
    summary,
    series
  });
});

app.get("/api/profile/latest", (req, res) => {
  if (!fs.existsSync(profileDir)) {
    res.status(404).json({ error: "profile directory not found" });
    return;
  }

  const candidates = fs
    .readdirSync(profileDir)
    .filter((name) => name.endsWith(".pro"))
    .map((name) => {
      const fullPath = path.join(profileDir, name);
      const st = fs.statSync(fullPath);
      return { name, mtimeMs: st.mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  if (candidates.length === 0) {
    res.status(404).json({ error: "no .pro profile found" });
    return;
  }

  const latest = candidates[0].name;
  const origin = `${req.protocol}://${req.get("host")}`;
  const profileUrl = `${origin}/profiles/${encodeURIComponent(latest)}`;

  res.json({
    fileName: latest,
    profileUrl,
    niVizUrl: `https://run.niviz.org/?file=${encodeURIComponent(profileUrl)}`
  });
});

app.use(express.static(distPath));

app.get("*", (_req, res) => {
  res.sendFile(path.join(distPath, "index.html"));
});

app.listen(port, () => {
  console.log(`AvalanCH dashboard running on :${port}`);
});
