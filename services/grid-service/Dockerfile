FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    libgdal-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

RUN cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /src/build -j \
    && strip /src/build/grid_snowpack_service || true

FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgdal34t64 \
    bash \
    ca-certificates \
    tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY --from=builder /src/build/grid_snowpack_service /usr/local/bin/grid_snowpack_service
COPY run-grid.sh /usr/local/bin/run-grid.sh
COPY snowpack-runtime /opt/snowpack
RUN chmod +x /usr/local/bin/run-grid.sh

ENV PATH="/opt/snowpack/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV LD_LIBRARY_PATH="/opt/snowpack/lib"

RUN useradd -m -u 10001 appuser \
    && chown -R appuser:appuser /workspace

USER appuser

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/run-grid.sh"]
