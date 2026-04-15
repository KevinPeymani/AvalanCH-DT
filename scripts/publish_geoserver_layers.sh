#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GEOSERVER_URL="${GEOSERVER_URL:-http://localhost:8081/geoserver}"
GEOSERVER_USER="${GEOSERVER_USER:-admin}"
GEOSERVER_PASSWORD="${GEOSERVER_PASSWORD:-geoserver}"
GEOSERVER_WORKSPACE="${GEOSERVER_WORKSPACE:-avalanch}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

# Must match docker-compose mount: ${GEOSERVER_RASTER_MOUNT_DIR:-./data/geoserver_external}:/opt/geospatial_data
GEOSERVER_RASTER_BASE="${GEOSERVER_RASTER_BASE:-/opt/geospatial_data/rasters}"
RASTER_SOURCE_DIR="${GEOSERVER_RASTER_SOURCE_DIR:-$ROOT_DIR/data/geoserver_external/rasters}"

HS_STORE="${HS_STORE:-hs_latest_store}"
HS_LAYER="${HS_LAYER:-hs_latest}"
DANGER_STORE="${DANGER_STORE:-danger_latest_store}"
DANGER_LAYER="${DANGER_LAYER:-danger_latest}"
HS_STYLE="${HS_STYLE:-hs_latest}"
DANGER_STYLE="${DANGER_STYLE:-danger_latest}"

json_headers=( -H "Content-Type: application/json" -H "Accept: application/json" )
auth=( -u "${GEOSERVER_USER}:${GEOSERVER_PASSWORD}" )
curl_common=( --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" )

clear_mapproxy_cache() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Skipping MapProxy cache clear: docker not available." >&2
    return 0
  fi

  if ! docker compose ps -q mapproxy >/dev/null 2>&1; then
    echo "Skipping MapProxy cache clear: mapproxy service not available." >&2
    return 0
  fi

  local mapproxy_id
  mapproxy_id="$(docker compose ps -q mapproxy 2>/dev/null || true)"
  if [[ -z "$mapproxy_id" ]]; then
    echo "Skipping MapProxy cache clear: mapproxy container not running." >&2
    return 0
  fi

  if ! docker compose exec -T mapproxy sh -lc '
    rm -rf \
      /mapproxy/cache_data/avalanch_danger \
      /mapproxy/cache_data/avalanch_hs \
      /mapproxy/config/cache_data/avalanch_danger \
      /mapproxy/config/cache_data/avalanch_hs && \
    mkdir -p \
      /mapproxy/cache_data/avalanch_danger \
      /mapproxy/cache_data/avalanch_hs \
      /mapproxy/config/cache_data/avalanch_danger \
      /mapproxy/config/cache_data/avalanch_hs
  ' >/dev/null; then
    echo "Warning: failed to clear MapProxy cache." >&2
    return 0
  fi

  echo "MapProxy cache cleared: avalanch_danger, avalanch_hs"
}

curl_status() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS "${curl_common[@]}" -o /tmp/geoserver_rest.out -w "%{http_code}" "${auth[@]}" "${json_headers[@]}" -X "$method" "$url" -d "$data"
  else
    curl -sS "${curl_common[@]}" -o /tmp/geoserver_rest.out -w "%{http_code}" "${auth[@]}" "${json_headers[@]}" -X "$method" "$url"
  fi
}

expect_ok() {
  local code="$1"
  local ctx="$2"
  if [[ ! "$code" =~ ^(200|201)$ ]]; then
    echo "GeoServer REST error during: $ctx" >&2
    echo "HTTP $code" >&2
    cat /tmp/geoserver_rest.out >&2 || true
    exit 1
  fi
}

upload_style() {
  local style_name="$1"
  local sld_path="$2"

  if [[ ! -f "$sld_path" ]]; then
    echo "Missing style file: $sld_path" >&2
    exit 1
  fi

  local style_url="${GEOSERVER_URL}/rest/styles/${style_name}"
  local code

  code="$(curl -sS "${curl_common[@]}" -o /tmp/geoserver_rest.out -w "%{http_code}" "${auth[@]}" -H "Accept: application/json" "${style_url}.json")"

  if [[ "$code" == "404" ]]; then
    code="$(curl -sS "${curl_common[@]}" -o /tmp/geoserver_rest.out -w "%{http_code}" "${auth[@]}" -H "Content-Type: application/vnd.ogc.sld+xml" -X POST "${GEOSERVER_URL}/rest/styles?name=${style_name}" --data-binary "@${sld_path}")"
    expect_ok "$code" "create style ${style_name}"
    echo "Style created: ${style_name}"
    return
  fi

  if [[ "$code" != "200" ]]; then
    echo "Unexpected HTTP $code while checking style ${style_name}" >&2
    cat /tmp/geoserver_rest.out >&2 || true
    exit 1
  fi

  code="$(curl -sS "${curl_common[@]}" -o /tmp/geoserver_rest.out -w "%{http_code}" "${auth[@]}" -H "Content-Type: application/vnd.ogc.sld+xml" -X PUT "${style_url}" --data-binary "@${sld_path}")"
  expect_ok "$code" "update style ${style_name}"
  echo "Style updated: ${style_name}"
}

set_layer_default_style() {
  local layer_name="$1"
  local style_name="$2"

  local payload
  payload="$(cat <<JSON
{
  "layer": {
    "defaultStyle": {
      "name": "${style_name}"
    }
  }
}
JSON
)"

  local code
  code="$(curl_status PUT "${GEOSERVER_URL}/rest/layers/${GEOSERVER_WORKSPACE}:${layer_name}.json" "$payload")"
  expect_ok "$code" "set default style ${style_name} on layer ${layer_name}"
  echo "Default style set: ${layer_name} -> ${style_name}"
}

ensure_workspace() {
  local ws_url="${GEOSERVER_URL}/rest/workspaces/${GEOSERVER_WORKSPACE}.json"
  local code
  code="$(curl_status GET "$ws_url")"
  if [[ "$code" == "200" ]]; then
    echo "Workspace exists: ${GEOSERVER_WORKSPACE}"
    return
  fi
  if [[ "$code" != "404" ]]; then
    echo "Unexpected HTTP $code while checking workspace ${GEOSERVER_WORKSPACE}" >&2
    cat /tmp/geoserver_rest.out >&2 || true
    exit 1
  fi

  local payload
  payload="$(cat <<JSON
{
  "workspace": {
    "name": "${GEOSERVER_WORKSPACE}"
  }
}
JSON
)"
  code="$(curl_status POST "${GEOSERVER_URL}/rest/workspaces" "$payload")"
  expect_ok "$code" "create workspace ${GEOSERVER_WORKSPACE}"
  echo "Workspace created: ${GEOSERVER_WORKSPACE}"
}

ensure_coveragestore() {
  local store_name="$1"
  local file_name="$2"

  local cs_url="${GEOSERVER_URL}/rest/workspaces/${GEOSERVER_WORKSPACE}/coveragestores/${store_name}.json"
  local code
  code="$(curl_status GET "$cs_url")"

  local payload
  payload="$(cat <<JSON
{
  "coverageStore": {
    "name": "${store_name}",
    "type": "ArcGrid",
    "enabled": true,
    "url": "file:${GEOSERVER_RASTER_BASE}/${file_name}",
    "workspace": {
      "name": "${GEOSERVER_WORKSPACE}"
    }
  }
}
JSON
)"

  if [[ "$code" == "404" ]]; then
    code="$(curl_status POST "${GEOSERVER_URL}/rest/workspaces/${GEOSERVER_WORKSPACE}/coveragestores" "$payload")"
    expect_ok "$code" "create coveragestore ${store_name}"
    echo "Coveragestore created: ${store_name}"
    return
  fi

  if [[ "$code" != "200" ]]; then
    echo "Unexpected HTTP $code while checking coveragestore ${store_name}" >&2
    cat /tmp/geoserver_rest.out >&2 || true
    exit 1
  fi

  code="$(curl_status PUT "$cs_url" "$payload")"
  expect_ok "$code" "update coveragestore ${store_name}"
  echo "Coveragestore updated: ${store_name}"
}

ensure_coverage() {
  local store_name="$1"
  local layer_name="$2"

  local cov_url="${GEOSERVER_URL}/rest/workspaces/${GEOSERVER_WORKSPACE}/coveragestores/${store_name}/coverages/${layer_name}.json"
  local code
  code="$(curl_status GET "$cov_url")"

  local payload
  payload="$(cat <<JSON
{
  "coverage": {
    "name": "${layer_name}",
    "nativeName": "${layer_name}",
    "title": "${layer_name}",
    "srs": "EPSG:2056",
    "nativeCRS": "EPSG:2056",
    "enabled": true
  }
}
JSON
)"

  if [[ "$code" == "404" ]]; then
    code="$(curl_status POST "${GEOSERVER_URL}/rest/workspaces/${GEOSERVER_WORKSPACE}/coveragestores/${store_name}/coverages" "$payload")"
    expect_ok "$code" "create coverage ${layer_name}"
    echo "Coverage created: ${layer_name}"
  elif [[ "$code" == "200" ]]; then
    echo "Coverage exists: ${layer_name}"
  else
    echo "Unexpected HTTP $code while checking coverage ${layer_name}" >&2
    cat /tmp/geoserver_rest.out >&2 || true
    exit 1
  fi

  # Enforce SRS and recalculate bounds from source each run.
  code="$(curl_status PUT "${cov_url}?recalculate=nativebbox,latlonbbox" "$payload")"
  expect_ok "$code" "recalculate bounds for ${layer_name}"
  echo "Coverage updated: ${layer_name}"
}

healthcheck() {
  local code
  code="$(curl -sS "${curl_common[@]}" -o /tmp/geoserver_rest.out -w "%{http_code}" "${auth[@]}" "${GEOSERVER_URL}/rest/about/status.json")"
  if [[ "$code" != "200" ]]; then
    echo "GeoServer not reachable or credentials invalid: ${GEOSERVER_URL}" >&2
    echo "HTTP $code" >&2
    cat /tmp/geoserver_rest.out >&2 || true
    exit 1
  fi
}

main() {
  local hs_path="$RASTER_SOURCE_DIR/hs_latest.asc"
  local danger_path="$RASTER_SOURCE_DIR/danger_latest.asc"
  local hs_sld="$ROOT_DIR/infra/geoserver_data/styles/${HS_STYLE}.sld"
  local danger_sld="$ROOT_DIR/infra/geoserver_data/styles/${DANGER_STYLE}.sld"

  if [[ ! -f "$hs_path" ]]; then
    echo "Missing raster: $hs_path" >&2
    echo "Run scripts/publish_latest_rasters.sh first." >&2
    exit 1
  fi
  if [[ ! -f "$danger_path" ]]; then
    echo "Missing raster: $danger_path" >&2
    echo "Run scripts/publish_latest_rasters.sh first." >&2
    exit 1
  fi

  healthcheck
  upload_style "$HS_STYLE" "$hs_sld"
  upload_style "$DANGER_STYLE" "$danger_sld"
  ensure_workspace

  ensure_coveragestore "$HS_STORE" "hs_latest.asc"
  ensure_coverage "$HS_STORE" "$HS_LAYER"
  set_layer_default_style "$HS_LAYER" "$HS_STYLE"

  ensure_coveragestore "$DANGER_STORE" "danger_latest.asc"
  ensure_coverage "$DANGER_STORE" "$DANGER_LAYER"
  set_layer_default_style "$DANGER_LAYER" "$DANGER_STYLE"

  curl -sS "${curl_common[@]}" "${auth[@]}" -X POST "${GEOSERVER_URL}/rest/reload" >/dev/null || true
  clear_mapproxy_cache

  echo "GeoServer publish complete."
  echo "Workspace: ${GEOSERVER_WORKSPACE}"
  echo "Layers: ${GEOSERVER_WORKSPACE}:${HS_LAYER}, ${GEOSERVER_WORKSPACE}:${DANGER_LAYER}"
}

main "$@"
