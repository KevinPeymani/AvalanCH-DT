FROM ubuntu:22.04 AS alpine3d-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    gfortran \
    libopenmpi-dev \
    openmpi-bin \
    libeigen3-dev \
    zlib1g-dev \
    libbz2-dev \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone https://git.wsl.ch/snow-models/meteoio.git \
 && git clone https://git.wsl.ch/snow-models/snowpack.git \
 && git clone https://git.wsl.ch/snow-models/alpine3d.git

WORKDIR /build/meteoio
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/alpine3d && \
    make -j"$(nproc)" && make install

WORKDIR /build/snowpack
RUN mkdir build && cd build && \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/alpine3d \
      -DCMAKE_PREFIX_PATH=/opt/alpine3d && \
    make -j"$(nproc)" && make install

WORKDIR /build/alpine3d
RUN mkdir build && cd build && \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/alpine3d \
      -DCMAKE_PREFIX_PATH=/opt/alpine3d \
      -DOPENMP=ON \
      -DMPI=ON && \
    make -j"$(nproc)" && make install

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV RUNTIME_VENV_DIR=/runtime-cache/alpine3d-venv
ENV PATH="/opt/alpine3d/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/alpine3d/lib:${LD_LIBRARY_PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-pip \
    libopenmpi-dev \
    openmpi-bin \
    libgomp1 \
    ca-certificates \
    tini \
    bash \
    && rm -rf /var/lib/apt/lists/*

COPY --from=alpine3d-builder /opt/alpine3d /opt/alpine3d

WORKDIR /app
COPY requirements.txt /app/requirements.txt
COPY runtime-requirements.txt /app/runtime-requirements.txt
COPY worker.py /app/worker.py
COPY entrypoint.sh /app/entrypoint.sh

RUN useradd -m -u 1001 alpine \
    && chmod +x /app/entrypoint.sh \
    && mkdir -p /runtime-cache \
    && chown -R alpine:alpine /opt/alpine3d /app /runtime-cache

USER alpine

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
