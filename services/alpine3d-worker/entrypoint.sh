#!/usr/bin/env bash
set -euo pipefail

VENV_DIR="${RUNTIME_VENV_DIR:-/runtime-cache/alpine3d-venv}"
REQ_FILE="/app/runtime-requirements.txt"
STAMP_FILE="${VENV_DIR}/.requirements.sha256"
CURRENT_HASH="$(sha256sum "$REQ_FILE" | awk '{print $1}')"

mkdir -p "$VENV_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]] || [[ ! -f "$STAMP_FILE" ]] || [[ "$(cat "$STAMP_FILE" 2>/dev/null || true)" != "$CURRENT_HASH" ]]; then
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel
  "$VENV_DIR/bin/pip" install --no-cache-dir -r /app/requirements.txt
  "$VENV_DIR/bin/pip" install --no-cache-dir -r "$REQ_FILE"
  printf '%s' "$CURRENT_HASH" > "$STAMP_FILE"
fi

export PATH="$VENV_DIR/bin:$PATH"
exec python /app/worker.py
