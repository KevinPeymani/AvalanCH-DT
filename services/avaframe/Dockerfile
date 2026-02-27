FROM python:3.10-slim

# ---- System deps (AvaFrame + geospatial + git for pip install from git)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gdal-bin libgdal-dev \
    proj-bin libproj-dev \
    libgeos-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# ---- Venv
ENV VENV=/opt/venv
RUN python -m venv $VENV
ENV PATH="$VENV/bin:$PATH"
RUN pip install --no-cache-dir -U pip setuptools wheel

# ---- App workdir
WORKDIR /app

# ---- Install Python deps (best cache layer)
COPY services/avaframe/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# ---- Copy service code
COPY services/avaframe/app/ /app/app/

# ---- Optional: internal shared libs
# COPY libs/common_utils/ /app/libs/common_utils/

# ---- Runtime env
ENV JOBS_DIR=/data/jobs
ENV QUEUE_NAME=simulation_queue
# BROKER_URL should be provided at runtime
# ENV BROKER_URL=amqp://admin:simulation_secure@rabbitmq:5672/

# ---- Data volume (jobs + avaframe inputs/outputs)
VOLUME ["/data"]

# ---- Non-root user (recommended)
RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

# ---- Default: run the API
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
