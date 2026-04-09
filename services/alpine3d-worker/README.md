# Alpine3D Worker Service

RabbitMQ worker that runs the full Alpine3D + avalanche grid prediction pipeline:

1. `Alpine3D/run_alpine3d_pipeline.py`
2. `Alpine3D/predict_grid.py`

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
- Python ML/runtime packages are bootstrapped on first start into a persistent cache mounted at `/runtime-cache`.
- On this machine, use the external SSD to store that cache so the internal disk stays free.
- The worker acks only when both pipeline and prediction succeed.

## Run with main compose

```bash
export ALPINE3D_RUNTIME_CACHE=/media/laura/external-ssd/alpine3d-worker-runtime
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
export ALPINE3D_RUNTIME_CACHE=/media/laura/external-ssd/alpine3d-worker-runtime
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
ALPINE3D_RUNTIME_CACHE=/media/laura/external-ssd/alpine3d-worker-runtime \
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
- First startup is heavy (TensorFlow download/install), so plan for time and disk.
- If your internal disk is small, map `ALPINE3D_RUNTIME_CACHE` to an external SSD path.
