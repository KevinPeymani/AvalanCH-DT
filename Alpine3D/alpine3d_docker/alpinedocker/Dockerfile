FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Dépendances build
RUN apt-get update && apt-get install -y \
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
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone sources
RUN git clone https://git.wsl.ch/snow-models/meteoio.git \
 && git clone https://git.wsl.ch/snow-models/snowpack.git \
 && git clone https://git.wsl.ch/snow-models/alpine3d.git

# ===== MeteoIO =====
WORKDIR /build/meteoio
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/alpine3d && \
    make -j$(nproc) && make install

# ===== Snowpack =====
WORKDIR /build/snowpack
RUN mkdir build && cd build && \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/alpine3d \
      -DCMAKE_PREFIX_PATH=/opt/alpine3d && \
    make -j$(nproc) && make install

# ===== Alpine3D =====
WORKDIR /build/alpine3d
RUN mkdir build && cd build && \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/alpine3d \
      -DCMAKE_PREFIX_PATH=/opt/alpine3d \
      -DOPENMP=ON \
      -DMPI=ON && \
    make -j$(nproc) && make install

# =========================
# Runtime image
# =========================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    libopenmpi-dev \
    openmpi-bin \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/alpine3d /opt/alpine3d

ENV PATH="/opt/alpine3d/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/alpine3d/lib:${LD_LIBRARY_PATH}"

WORKDIR /work

# créer un user non-root
RUN useradd -m -u 1001 alpine

# donner accès aux fichiers installés
RUN chown -R alpine:alpine /opt/alpine3d

USER alpine

ENTRYPOINT ["/bin/bash"]
