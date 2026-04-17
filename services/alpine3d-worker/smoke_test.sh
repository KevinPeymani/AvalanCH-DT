#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

QUEUE_NAME="${ALPINE_QUEUE:-alpine3d_queue}"
SMOKE_STATION="${SMOKE_STATION:-ZER2}"
SMOKE_DAYS="${SMOKE_DAYS:-1}"
SMOKE_NP="${SMOKE_NP:-2}"
SMOKE_PREDICT_DAYS="${SMOKE_PREDICT_DAYS:-1}"
SMOKE_NO_PNG="${SMOKE_NO_PNG:-true}"
SMOKE_TIMEOUT_SEC="${SMOKE_TIMEOUT_SEC:-3600}"
SMOKE_POLL_SEC="${SMOKE_POLL_SEC:-10}"

if ! [[ "$SMOKE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || ! [[ "$SMOKE_POLL_SEC" =~ ^[0-9]+$ ]]; then
  echo "[smoke] SMOKE_TIMEOUT_SEC and SMOKE_POLL_SEC must be integers" >&2
  exit 2
fi

if [[ -n "${ALPINE3D_RUNTIME_CACHE:-}" ]]; then
  mkdir -p "$ALPINE3D_RUNTIME_CACHE"
  COMPOSE_PREFIX=(env "ALPINE3D_RUNTIME_CACHE=$ALPINE3D_RUNTIME_CACHE")
  WORKER_PYTHON=/runtime-cache/alpine3d-venv/bin/python
else
  COMPOSE_PREFIX=()
  WORKER_PYTHON=/app/alpine3d-venv/bin/python
fi

compose() {
  "${COMPOSE_PREFIX[@]}" docker compose "$@"
}

JOB_ID="smoke-$(date +%Y%m%d-%H%M%S)-$RANDOM"
SINCE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "[smoke] Starting worker dependencies"
compose up -d rabbitmq worker-alpine3d >/dev/null

echo "[smoke] Waiting for worker readiness"
ready_deadline=$((SECONDS + 600))
while (( SECONDS < ready_deadline )); do
  if compose logs --since "$SINCE_UTC" worker-alpine3d 2>&1 | grep -q "Listening on queue"; then
    break
  fi
  sleep 5
done
if (( SECONDS >= ready_deadline )); then
  echo "[smoke] Worker did not become ready in time" >&2
  exit 1
fi

echo "[smoke] Purging queue $QUEUE_NAME"
compose exec -T rabbitmq rabbitmqctl purge_queue "$QUEUE_NAME" >/dev/null

echo "[smoke] Queueing job_id=$JOB_ID"
compose exec -T worker-alpine3d "$WORKER_PYTHON" - <<PY
import json
import pika

payload = {
    "job_id": "${JOB_ID}",
    "station": "${SMOKE_STATION}",
    "days": int("${SMOKE_DAYS}"),
    "np": int("${SMOKE_NP}"),
    "predict_days": int("${SMOKE_PREDICT_DAYS}"),
    "no_png": str("${SMOKE_NO_PNG}").lower() in {"1", "true", "yes", "y"},
}

conn = pika.BlockingConnection(pika.URLParameters("amqp://admin:simulation_secure@swiss_broker:5672/"))
ch = conn.channel()
ch.queue_declare(queue="${QUEUE_NAME}", durable=True)
ch.basic_publish(
    exchange="",
    routing_key="${QUEUE_NAME}",
    body=json.dumps(payload).encode("utf-8"),
    properties=pika.BasicProperties(delivery_mode=2),
)
conn.close()
print(f"queued: {payload}")
PY

echo "[smoke] Waiting for job completion (timeout=${SMOKE_TIMEOUT_SEC}s)"
deadline=$((SECONDS + SMOKE_TIMEOUT_SEC))
while (( SECONDS < deadline )); do
  logs="$(compose logs --since "$SINCE_UTC" worker-alpine3d 2>&1 || true)"

  if grep -q "Job completed job_id=${JOB_ID}" <<<"$logs"; then
    latest_grid="$(ls -1t Alpine3D/output/grid_predictions/*_danger.asc 2>/dev/null | head -n 1 || true)"
    echo "[smoke] SUCCESS: job completed for job_id=${JOB_ID}"
    if [[ -n "$latest_grid" ]]; then
      echo "[smoke] Latest danger grid: $latest_grid"
    fi
    exit 0
  fi

  if grep -q "Job failed job_id=${JOB_ID}" <<<"$logs"; then
    echo "[smoke] FAILURE: worker reported job failure for job_id=${JOB_ID}" >&2
    compose logs --since "$SINCE_UTC" worker-alpine3d >&2 || true
    exit 1
  fi

  sleep "$SMOKE_POLL_SEC"
done

echo "[smoke] FAILURE: timeout reached for job_id=${JOB_ID}" >&2
compose logs --since "$SINCE_UTC" worker-alpine3d >&2 || true
exit 1
