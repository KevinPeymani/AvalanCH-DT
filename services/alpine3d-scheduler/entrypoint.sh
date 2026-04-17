#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
RUN_SCRIPT_REL="${RUN_SCRIPT_REL:-scripts/run_alpine3d_publish_geoserver.sh}"
RUN_SCRIPT="${WORKSPACE_DIR}/${RUN_SCRIPT_REL}"
CACHE_DIR="${ALPINE3D_RUNTIME_CACHE:-/runtime-cache}"
STATUS_FILE="${STATUS_FILE:-${WORKSPACE_DIR}/Alpine3D/output/scheduler/alpine3d_publish_status.json}"
LOG_DIR="${LOG_DIR:-${WORKSPACE_DIR}/Alpine3D/output/scheduler/logs}"
TRIGGER_FILE="${TRIGGER_FILE:-${WORKSPACE_DIR}/Alpine3D/output/scheduler/manual_run.request}"
SCHEDULE_TIME_UTC="${SCHEDULE_TIME_UTC:-03:00}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-120}"
STATION="${STATION:-ZER2}"
DAYS="${DAYS:-7}"
PREDICT_DAYS="${PREDICT_DAYS:-${DAYS}}"
DEFAULT_NP="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
NP="${NP:-${DEFAULT_NP}}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10800}"
NO_PNG="${NO_PNG:-false}"
SKIP_BUILD="${SKIP_BUILD:-true}"

if [[ ! -f "$RUN_SCRIPT" ]]; then
  echo "Run script not found: $RUN_SCRIPT" >&2
  exit 2
fi

if [[ ! "$SCHEDULE_TIME_UTC" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "SCHEDULE_TIME_UTC must be HH:MM (UTC), got: $SCHEDULE_TIME_UTC" >&2
  exit 2
fi

mkdir -p "$(dirname "$STATUS_FILE")" "$(dirname "$TRIGGER_FILE")" "$LOG_DIR" "$CACHE_DIR"

compute_next_run() {
  python3 - "$SCHEDULE_TIME_UTC" <<'PY'
import sys
from datetime import datetime, timezone, timedelta

hh, mm = [int(x) for x in sys.argv[1].split(":")]
now = datetime.now(timezone.utc)
target = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if target <= now:
    target += timedelta(days=1)
print(int(target.timestamp()))
print(target.isoformat().replace("+00:00", "Z"))
PY
}

write_status() {
  local state="$1"
  local updated_at="$2"
  local next_run_at="$3"
  local started_at="$4"
  local ended_at="$5"
  local duration_sec="$6"
  local exit_code="$7"
  local log_file="$8"
  local trigger_reason="$9"

  STATUS_STATE="$state" \
  STATUS_UPDATED_AT="$updated_at" \
  STATUS_NEXT_RUN_AT="$next_run_at" \
  STATUS_STARTED_AT="$started_at" \
  STATUS_ENDED_AT="$ended_at" \
  STATUS_DURATION_SEC="$duration_sec" \
  STATUS_EXIT_CODE="$exit_code" \
  STATUS_LOG_FILE="$log_file" \
  STATUS_TRIGGER_REASON="$trigger_reason" \
  STATUS_FILE_PATH="$STATUS_FILE" \
  STATUS_LOG_TAIL_LINES="$LOG_TAIL_LINES" \
  STATUS_STATION="$STATION" \
  STATUS_DAYS="$DAYS" \
  STATUS_PREDICT_DAYS="$PREDICT_DAYS" \
  STATUS_NP="$NP" \
  STATUS_TIMEOUT_SEC="$TIMEOUT_SEC" \
  STATUS_NO_PNG="$NO_PNG" \
  STATUS_SKIP_BUILD="$SKIP_BUILD" \
  STATUS_SCHEDULE_TIME="$SCHEDULE_TIME_UTC" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

def maybe_int(raw):
    if raw in ("", "null", None):
        return None
    try:
        return int(raw)
    except ValueError:
        return None

def maybe_float(raw):
    if raw in ("", "null", None):
        return None
    try:
        return float(raw)
    except ValueError:
        return None

def maybe_bool(raw):
    return str(raw).strip().lower() in {"1", "true", "yes", "on"}

status_file = Path(os.environ["STATUS_FILE_PATH"])
log_file = os.environ.get("STATUS_LOG_FILE", "")
log_tail_lines = maybe_int(os.environ.get("STATUS_LOG_TAIL_LINES")) or 120
log_tail = []

if log_file and Path(log_file).exists():
    with Path(log_file).open("r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    log_tail = [line.rstrip("\n") for line in lines[-log_tail_lines:]]

payload = {
    "service": "alpine3d-scheduler",
    "state": os.environ["STATUS_STATE"],
    "updatedAt": os.environ["STATUS_UPDATED_AT"],
    "schedule": {
        "timeUtc": os.environ["STATUS_SCHEDULE_TIME"],
        "interval": "daily"
    },
    "nextRunAt": os.environ.get("STATUS_NEXT_RUN_AT") or None,
    "runConfig": {
        "station": os.environ["STATUS_STATION"],
        "days": maybe_int(os.environ["STATUS_DAYS"]),
        "predictDays": maybe_int(os.environ["STATUS_PREDICT_DAYS"]),
        "np": maybe_int(os.environ["STATUS_NP"]),
        "timeoutSec": maybe_int(os.environ["STATUS_TIMEOUT_SEC"]),
        "noPng": maybe_bool(os.environ["STATUS_NO_PNG"]),
        "skipBuild": maybe_bool(os.environ["STATUS_SKIP_BUILD"])
    },
    "lastRun": {
        "startedAt": os.environ.get("STATUS_STARTED_AT") or None,
        "endedAt": os.environ.get("STATUS_ENDED_AT") or None,
        "durationSec": maybe_float(os.environ.get("STATUS_DURATION_SEC")),
      "exitCode": maybe_int(os.environ.get("STATUS_EXIT_CODE")),
      "trigger": os.environ.get("STATUS_TRIGGER_REASON") or None
    },
    "lastLog": {
        "file": log_file or None,
        "tail": log_tail
    }
}

status_file.parent.mkdir(parents=True, exist_ok=True)
tmp_file = status_file.with_suffix(status_file.suffix + ".tmp")
with tmp_file.open("w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
os.replace(tmp_file, status_file)
PY
}

run_once() {
  local next_run_at="$1"
  local trigger_reason="$2"
  local started_at
  local ended_at
  local start_epoch
  local end_epoch
  local duration_sec
  local exit_code

  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  start_epoch="$(date -u +%s)"
  local log_file="${LOG_DIR}/run-$(date -u +"%Y%m%dT%H%M%SZ").log"

  write_status "running" "$started_at" "$next_run_at" "$started_at" "" "" "" "$log_file" "$trigger_reason"

  cmd=(
    bash "$RUN_SCRIPT"
    --cache-dir "$CACHE_DIR"
    --station "$STATION"
    --days "$DAYS"
    --predict-days "$PREDICT_DAYS"
    --np "$NP"
    --timeout "$TIMEOUT_SEC"
  )

  if [[ "$NO_PNG" == "true" ]]; then
    cmd+=(--no-png)
  fi

  if [[ "$SKIP_BUILD" == "true" ]]; then
    cmd+=(--skip-build)
  fi

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting daily Alpine3D run" | tee -a "$log_file"

  set +e
  "${cmd[@]}" > >(tee -a "$log_file") 2>&1
  exit_code=$?
  set -e

  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  end_epoch="$(date -u +%s)"
  duration_sec="$((end_epoch - start_epoch))"

  if [[ "$exit_code" -eq 0 ]]; then
    write_status "success" "$ended_at" "" "$started_at" "$ended_at" "$duration_sec" "$exit_code" "$log_file" "$trigger_reason"
  else
    write_status "failed" "$ended_at" "" "$started_at" "$ended_at" "$duration_sec" "$exit_code" "$log_file" "$trigger_reason"
  fi

  return "$exit_code"
}

cd "$WORKSPACE_DIR"

while true; do
  mapfile -t next_run_data < <(compute_next_run)
  next_run_epoch="${next_run_data[0]}"
  next_run_iso="${next_run_data[1]}"

  write_status "idle" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$next_run_iso" "" "" "" "" "" ""

  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Next run at $next_run_iso"

  trigger_reason="scheduled"
  while true; do
    if [[ -f "$TRIGGER_FILE" ]]; then
      trigger_reason="manual"
      rm -f "$TRIGGER_FILE"
      break
    fi

    now_epoch="$(date -u +%s)"
    if (( now_epoch >= next_run_epoch )); then
      break
    fi

    remaining_sec="$((next_run_epoch - now_epoch))"
    sleep_chunk=30
    if (( remaining_sec < sleep_chunk )); then
      sleep_chunk="$remaining_sec"
    fi
    sleep "$sleep_chunk"
  done

  if run_once "$next_run_iso" "$trigger_reason"; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Run finished successfully"
  else
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Run failed" >&2
  fi

done
