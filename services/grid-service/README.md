# Grid Snowpack Service (C++)

Run SNOWPACK for every DEM cell (or every `n`-th cell) and store only compact per-cell feature values in one CSV.

## What it does

1. Reads a DEM GeoTIFF (`--dem`) using GDAL.
2. Computes per-cell:
   - `altitude` (DEM value)
   - `latitude`, `longitude` (transformed to WGS84)
   - `SlopeAngle`, `SlopeAzi` (Horn gradient on 3x3 neighborhood)
3. Reuses one temporary Snowpack working directory per thread (inputs/outputs are overwritten each cell).
4. Runs Snowpack for each cell in a thread pool.
5. Extracts only final/instant feature values and writes a single CSV (default `snowpack_features.csv`) with:
   - topology fields: `altitude`, `latitude`, `longitude`, `slope_angle`, `slope_azi`
   - selected model feature columns from `prediction/feature_columns.json`

## Build

From repository root:

```bash
cmake -S services/grid-service -B services/grid-service/build
cmake --build services/grid-service/build -j
```

Requirements:
- C++17 compiler
- GDAL development package (headers + libraries)
- Snowpack executable available in `PATH` or provided via `--snowpack-bin`

## Templates

You can reuse existing files in this repository as templates:

- `prediction/input/DAV3.smet`
- `prediction/input/DAV3.sno`
- `prediction/cfgfiles/io.ini`

The service will patch these fields per cell automatically:

- SMET/SNO headers: `latitude`, `longitude`, `altitude`
- SNO headers: `SlopeAngle`, `SlopeAzi`
- INI keys: `[Input] STATION1`, `[Input] METEOPATH`, `[Input] SNOWPATH`, `[Output] METEOPATH`, `[Output] EXPERIMENT`

Station metadata (`station_id`, `station_name`, `station_abbr`) is preserved from templates.

Optional placeholders are also supported in templates, e.g. `{{STATION_ID}}`, `{{LATITUDE}}`, `{{LONGITUDE}}`, `{{ALTITUDE}}`, `{{SLOPE_ANGLE}}`, `{{SLOPE_AZI}}`.

## Run

Example:

```bash
./services/grid-service/build/grid_snowpack_service \
  --dem prediction/swissalti3d_2024_2610-1092_2_2056_5728.tif \
  --smet-template prediction/input/DAV3.smet \
  --sno-template prediction/input/DAV3.sno \
  --ini-template prediction/cfgfiles/io.ini \
  --output-root prediction/grid_runs/run_001 \
  --threads 12 \
  --stride 2 \
   --feature-columns prediction/feature_columns.json \
   --features-csv snowpack_features.csv \
  --end-time 2026-03-12T00:00:00 \
  --cell-size 5.0
```

Useful options:

- `--dry-run`: generate all per-cell inputs without running Snowpack
- `--max-cells N`: quick test on first `N` valid cells
- `--min-alt` / `--max-alt`: altitude filtering
- `--snowpack-bin /path/to/snowpack`: explicit Snowpack binary
- `--keep-workdirs`: keep thread workdirs for debugging (default deletes them)

## Docker (Batch Mode)

Files:

- `services/grid-service/Dockerfile`
- `services/grid-service/docker-compose.grid.yml`
- `services/grid-service/run-grid.sh`

Run once in batch mode:

```bash
docker compose -f services/grid-service/docker-compose.grid.yml up --build
```

Notes:

- The repository is mounted into `/workspace` inside the container.
- Snowpack is embedded in the image from `services/grid-service/snowpack-runtime`.
- No host Snowpack mount is required for batch mode.
- Images are optimized for smaller size: multi-stage build, Release binary, runtime-only GDAL libs, non-root user.

## Docker (RabbitMQ Worker Mode)

Files:

- `services/grid-service/Dockerfile.worker`
- `services/grid-service/docker-compose.grid-worker.yml`
- `services/grid-service/worker.py`
- `services/grid-service/grid_job_example.json`

Start broker + worker:

```bash
docker compose -f services/grid-service/docker-compose.grid-worker.yml up --build
```

This worker image is also optimized for smaller size and follows the same runtime constraints (non-root, runtime libs only).

Publish a job (example):

```bash
python - <<'PY'
import json
import pika

with open('services/grid-service/grid_job_example.json', 'r', encoding='utf-8') as f:
   payload = json.load(f)

conn = pika.BlockingConnection(pika.URLParameters('amqp://admin:simulation_secure@localhost:5673/'))
ch = conn.channel()
ch.queue_declare(queue='grid_queue', durable=True)
ch.basic_publish(
   exchange='',
   routing_key='grid_queue',
   body=json.dumps(payload).encode('utf-8'),
   properties=pika.BasicProperties(delivery_mode=2),
)
conn.close()
print('Job queued on grid_queue')
PY
```

## Outputs

- `prediction/grid_runs/run_001/snowpack_features.csv`

By default, temporary work folders are removed after the run to minimize disk usage.
