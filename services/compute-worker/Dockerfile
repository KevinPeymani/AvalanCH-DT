FROM python:3.10-slim

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gdal-bin \
    libgdal-dev \
    proj-bin \
    libproj-dev \
    libgeos-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Python / GDAL env
ENV VENV=/opt/venv
ENV PATH="${VENV}/bin:${PATH}"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV JOBS_DIR=/data/jobs
ENV WORKER_TYPE=simulation
ENV INGEST_QUEUE=ingestion_queue
ENV SIM_QUEUE=simulation_queue

RUN python -m venv "${VENV}" \
    && pip install --no-cache-dir --upgrade pip setuptools wheel

WORKDIR /app

# Dependencies first for better layer cache
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Application code
COPY app/ /app/app

# Data volume
VOLUME ["/data"]

# Non-root user
RUN useradd -m -u 10001 appuser \
    && mkdir -p /data/jobs \
    && chown -R appuser:appuser /app /data

USER appuser

# This container is a worker, not an HTTP API
CMD ["python", "-m", "app.worker"]
