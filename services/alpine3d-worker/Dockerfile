FROM alpine3d:local

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV RUNTIME_VENV_DIR=/runtime-cache/alpine3d-venv

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-pip \
    ca-certificates \
    tini \
    bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
COPY runtime-requirements.txt /app/runtime-requirements.txt
COPY worker.py /app/worker.py
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh \
    && mkdir -p /runtime-cache \
    && chown -R alpine:alpine /app /runtime-cache

USER alpine

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
