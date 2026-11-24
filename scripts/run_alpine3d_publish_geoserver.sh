#!/usr/bin/env bash
set -euo pipefail

# Launches the Alpine3D + danger-prediction pipeline via the standard
# docker compose services (worker-alpine3d + geoserver), waits for the
# job to complete, then publishes hs_latest and danger_latest to GeoServer.

usage() {
  cat <<'EOF'
Usage: run_alpine3d_publish_geoserver.sh [options]

Options:
  --cache-dir PATH     Host path for the Alpine3D runtime cache (SSD recommended).
                       Also readable from ALPINE3D_RUNTIME_CACHE env variable.
  --station CODE       IMIS station code. Default: ZER2
  --days N             Days of IMIS forcing for Alpine3D. Default: 7
  --predict-days N     Days of IMIS forcing for danger prediction. Default: same as --days
  --np N               OMP thread count for Alpine3D. Default: detected CPU cores
  --no-png             Disable PNG export for danger grids.
  --skip-build         Skip docker compose build.
  --timeout N          Seconds to wait for pipeline completion. Default: 10800
  -h, --help           Show this help.

Environment overrides:
  ALPINE3D_RUNTIME_CACHE  Same as --cache-dir.
  ALPINE3D_USE_RUNNING_SERVICES  Set to 1 to use the existing Compose services.
  GEOSERVER_URL           Default: http://localhost:8081/geoserver
  GEOSERVER_USER          Default: admin
  GEOSERVER_PASSWORD      Default: geoserver
  GEOSERVER_WORKSPACE     Default: avalanch
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATION="ZER2"
DAYS=7
PREDICT_DAYS=""
DEFAULT_NP="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
NP="$DEFAULT_NP"
NO_PNG="false"
SKIP_BUILD=0
TIMEOUT_SEC=10800
CACHE_DIR="${ALPINE3D_RUNTIME_CACHE:-}"
GEOSERVER_URL="${GEOSERVER_URL:-http://localhost:8081/geoserver}"
GEOSERVER_USER="${GEOSERVER_USER:-admin}"
GEOSERVER_PASSWORD="${GEOSERVER_PASSWORD:-geoserver}"
GEOSERVER_WORKSPACE="${GEOSERVER_WORKSPACE:-avalanch}"
QUEUE_NAME="${ALPINE_QUEUE:-alpine3d_queue}"
CURRENT_UID_VALUE="${CURRENT_UID:-$(id -u)}"
CURRENT_GID_VALUE="${CURRENT_GID:-$(id -g)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-dir)
      CACHE_DIR="${2:-}"
      shift 2
      ;;
    --station)
      STATION="${2:-}"
      shift 2
      ;;
    --days)
      DAYS="${2:-}"
      shift 2
      ;;
    --predict-days)
      PREDICT_DAYS="${2:-}"
      shift 2
      ;;
    --np)
      NP="${2:-}"
      shift 2
      ;;
    --no-png)
      NO_PNG="true"
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --timeout)
      TIMEOUT_SEC="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PREDICT_DAYS" ]]; then
  PREDICT_DAYS="$DAYS"
fi

# Wrapper so every docker compose call gets ALPINE3D_RUNTIME_CACHE forwarded.
compose() {
  ALPINE3D_RUNTIME_CACHE="$CACHE_DIR" \
  CURRENT_UID="$CURRENT_UID_VALUE" \
  CURRENT_GID="$CURRENT_GID_VALUE" \
  docker compose "$@"
}

wait_for_worker_ready() {
  local deadline=$((SECONDS + 600))
  echo "Waiting for worker-alpine3d to be ready..."
  while (( SECONDS < deadline )); do
    if compose exec -T rabbitmq rabbitmqctl -q list_queues name consumers 2>/dev/null |
      awk -v queue="$QUEUE_NAME" '$1 == queue && $2 > 0 { ready = 1 } END { exit !ready }'; then
      return 0
    fi
    sleep 5
  done
  echo "worker-alpine3d did not become ready in time." >&2
  return 1
}

wait_for_geoserver() {
  local max_attempts=60
  local attempt=1
  local status_url="${GEOSERVER_URL}/rest/about/status.json"
  echo "Waiting for GeoServer..."
  while (( attempt <= max_attempts )); do
    if curl -fsS -u "${GEOSERVER_USER}:${GEOSERVER_PASSWORD}" "$status_url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  echo "GeoServer did not become ready at ${GEOSERVER_URL}" >&2
  return 1
}

purge_queue() {
  echo "Purging queue ${QUEUE_NAME}..."
  compose exec -T rabbitmq rabbitmqctl purge_queue "${QUEUE_NAME}" >/dev/null
}

send_job() {
  local job_id="$1"
  compose exec -T worker-alpine3d \
    sh -c 'exec "${RUNTIME_VENV_DIR:-/app/alpine3d-venv}/bin/python" -' <<PY
import json, pika
payload = {
    "job_id":       "${job_id}",
    "station":      "${STATION}",
    "days":         int("${DAYS}"),
    "np":           int("${NP}"),
    "predict_days": int("${PREDICT_DAYS}"),
    "no_png":       str("${NO_PNG}").lower() in {"1", "true"},
}
conn = pika.BlockingConnection(pika.URLParameters("amqp://admin:simulation_secure@swiss_broker:5672/"))
ch = conn.channel()
ch.queue_declare(queue="${QUEUE_NAME}", durable=True)
ch.basic_publish(
    exchange="", routing_key="${QUEUE_NAME}",
    body=json.dumps(payload).encode(),
    properties=pika.BasicProperties(delivery_mode=2),
)
conn.close()
print("Queued:", json.dumps(payload))
PY
}

wait_for_job() {
  local job_id="$1"
  local since="$2"
  local deadline=$((SECONDS + TIMEOUT_SEC))
  echo "Waiting for job_id=${job_id} to complete (timeout=${TIMEOUT_SEC}s)..."
  while (( SECONDS < deadline )); do
    local logs
    logs="$(compose logs --since "$since" worker-alpine3d 2>&1 || true)"
    if grep -q "Job completed job_id=${job_id}" <<<"$logs"; then
      return 0
    fi
    if grep -q "Job failed job_id=${job_id}" <<<"$logs"; then
      echo "Job failed. Worker logs:" >&2
      compose logs --since "$since" worker-alpine3d >&2 || true
      return 1
    fi
    sleep 10
  done
  echo "Timeout waiting for job_id=${job_id}." >&2
  compose logs --since "$since" worker-alpine3d >&2 || true
  return 1
}

main() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required but not found." >&2; exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required but not found." >&2; exit 1
  fi

  cd "$ROOT_DIR"
  if [[ -n "$CACHE_DIR" ]]; then
    mkdir -p "$CACHE_DIR"
    echo "Alpine3D runtime cache: $CACHE_DIR"
  fi

  if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "Building worker-alpine3d..."
    compose build worker-alpine3d
  fi

  local since
  since="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local job_id="run-$(date +%Y%m%d-%H%M%S)-$$"

  if [[ "${ALPINE3D_USE_RUNNING_SERVICES:-0}" != "1" ]]; then
    echo "Starting services (rabbitmq + geoserver)..."
    compose up -d rabbitmq geoserver
    echo "Starting worker-alpine3d..."
    compose up -d worker-alpine3d
  fi
  wait_for_worker_ready
  purge_queue

  echo "Sending job job_id=${job_id}..."
  send_job "$job_id"

  wait_for_job "$job_id" "$since"
  echo "Pipeline complete for job_id=${job_id}."

  wait_for_geoserver

  GEOSERVER_URL="$GEOSERVER_URL" \
  GEOSERVER_USER="$GEOSERVER_USER" \
  GEOSERVER_PASSWORD="$GEOSERVER_PASSWORD" \
  GEOSERVER_WORKSPACE="$GEOSERVER_WORKSPACE" \
  "$ROOT_DIR/scripts/publish_latest_rasters.sh" --with-geoserver

  echo
  echo "Done. Published layers: ${GEOSERVER_WORKSPACE}:hs_latest and ${GEOSERVER_WORKSPACE}:danger_latest"
}

main "$@"
