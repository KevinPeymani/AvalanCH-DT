FROM python:3.10-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gdal-bin libgdal-dev \
    proj-bin libproj-dev \
    libgeos-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

ENV VENV=/opt/venv
RUN python -m venv $VENV
ENV PATH="$VENV/bin:$PATH"
RUN pip install --no-cache-dir -U pip setuptools wheel

WORKDIR /app

# deps
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# service code
COPY app/ /app/app

ENV JOBS_DIR=/data/jobs
ENV QUEUE_NAME=simulation_queue

VOLUME ["/data"]

RUN useradd -m -u 10001 appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
