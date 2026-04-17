# Alpine3D Worker Service

RabbitMQ worker that runs the full Alpine3D + avalanche grid prediction pipeline:

1. `Alpine3D/run_alpine3d_pipeline.py`
2. `Alpine3D/predict_grid.py`

The service is intended to be portable across developer machines and servers.

## Queue

- Queue name: `alpine3d_queue` (configurable with `ALPINE_QUEUE`)

## Expected payload

```json
{
  "station": "ZER2",
  "days": 2,
  "np": 2,
  "predict_days": 7,
  "no_png": false
}
```

## Notes

- The worker image includes Alpine3D directly and does not depend on host Docker or a host `.venv`.
- Python ML/runtime packages are bootstrapped on first start into a venv. By default this lives inside the container; set `ALPINE3D_RUNTIME_CACHE` to persist it on the host.
- The worker acks only when both pipeline and prediction succeed.

## Prerequisites

1. Docker Engine installed
2. Docker Compose plugin available (`docker compose`)
3. Sufficient writable disk space for:
  - Alpine3D outputs in the repository workspace
  - Python runtime cache (TensorFlow and ML dependencies, optional — only needed if `ALPINE3D_RUNTIME_CACHE` is set)

## Runtime cache path

By default the worker builds the Python venv **inside the container** at `/app/alpine3d-venv`. The venv is rebuilt on each container start, which is fine for occasional or CI use.

To persist the venv across restarts and avoid slow reinstalls, set `ALPINE3D_RUNTIME_CACHE` to a host directory before starting the service. Docker will bind-mount that directory to `/runtime-cache` inside the container and the venv will be stored there.

Choose any path suitable for your environment, for example:

- Linux server: `/srv/alpine3d/runtime-cache`
- Local development: `./.alpine3d-runtime-cache`
- External volume: `/mnt/data/alpine3d-runtime-cache`

## Run with main compose

Start the worker service (no persistent cache — venv lives in-container):

```bash
docker compose up --build -d worker-alpine3d
```

Or with a persistent host cache:

```bash
export ALPINE3D_RUNTIME_CACHE=/path/to/alpine3d-runtime-cache
docker compose up --build -d worker-alpine3d
```

## Queue a job

```bash
python services/alpine3d-worker/send_job.py
```

## Smoke test (one command)

Run this after deploying or updating the worker. It will:

1. Start `rabbitmq` and `worker-alpine3d`
2. Purge `alpine3d_queue`
3. Submit a test job with a unique `job_id`
4. Wait until the worker logs `Job completed job_id=...`

```bash
# With cache (faster subsequent starts):
export ALPINE3D_RUNTIME_CACHE=/path/to/alpine3d-runtime-cache
services/alpine3d-worker/smoke_test.sh

# Without cache (ephemeral venv, no host directory needed):
services/alpine3d-worker/smoke_test.sh
```

Optional knobs:

- `SMOKE_STATION` (default `ZER2`)
- `SMOKE_DAYS` (default `1`)
- `SMOKE_PREDICT_DAYS` (default `1`)
- `SMOKE_TIMEOUT_SEC` (default `3600`)
- `SMOKE_NO_PNG` (default `true`)

Example:

```bash
ALPINE3D_RUNTIME_CACHE=/path/to/alpine3d-runtime-cache \
SMOKE_DAYS=1 SMOKE_PREDICT_DAYS=1 SMOKE_TIMEOUT_SEC=2400 \
services/alpine3d-worker/smoke_test.sh
```

## Deploy on another machine

Current portability is high, with these prerequisites:

1. Docker + Docker Compose plugin installed
2. Enough writable disk on the host filesystem mounted as `/workspace` (Alpine3D writes outputs there)
3. A persistent runtime cache path for Python deps (`ALPINE3D_RUNTIME_CACHE`), preferably on a large disk/SSD
4. Ability to build the worker image from this repo

Important notes:

- The worker does not require a host Python `.venv`.
- The worker does not require mounting the host Docker socket.
- The worker Docker build now compiles Alpine3D from source automatically, so no separate `alpine3d:local` pre-build is required.
- First startup is heavy (TensorFlow download/install), so plan for time and disk.
- If local disk is limited, map `ALPINE3D_RUNTIME_CACHE` to a larger mounted volume.
