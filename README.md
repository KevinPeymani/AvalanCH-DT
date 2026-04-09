# AvalanCH-DT

## GeoServer + MapProxy quick guide (HS + danger)

This project publishes latest Alpine3D rasters into GeoServer and serves them through MapProxy.

### Runtime folders

- GeoServer data directory (catalog/config): `data/geoserver_data`
- GeoServer external raster mount: `data/geoserver_external/rasters`
- Versioned SLD styles: `infra/geoserver_data/styles`

### 1) Start services

```bash
docker compose up -d geoserver mapproxy
```

### 2) Publish latest rasters and GeoServer layers

```bash
bash scripts/publish_latest_rasters.sh --with-geoserver
```

This command does all of the following:

- finds latest Alpine3D outputs (`*_HS.asc` and `*_danger.asc`)
- writes `hs_latest.asc` and `danger_latest.asc` into `data/geoserver_external/rasters`
- writes EPSG:2056 `.prj` sidecars
- creates/updates workspace `avalanch`
- creates/updates ArcGrid stores and layers `hs_latest`, `danger_latest`

Default GeoServer connection:

- URL: `http://localhost:8081/geoserver`
- user: `admin`
- password: `geoserver`

Override example:

```bash
GEOSERVER_URL=http://localhost:8081/geoserver \
GEOSERVER_USER=admin \
GEOSERVER_PASSWORD=geoserver \
bash scripts/publish_latest_rasters.sh --with-geoserver
```

### 3) Validate that it works

GeoServer capabilities should expose both layers:

```bash
curl -s "http://localhost:8081/geoserver/avalanch/wms?SERVICE=WMS&REQUEST=GetCapabilities" | grep -E "hs_latest|danger_latest"
```

MapProxy capabilities should expose both proxied layers:

```bash
curl -s "http://localhost:8080/mapproxy/service?SERVICE=WMS&REQUEST=GetCapabilities" | grep -E "avalanch\.hs_latest|avalanch\.danger_latest"
```

Quick map checks:

```bash
curl -o /tmp/hs_latest.png "http://localhost:8080/mapproxy/service?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=avalanch.hs_latest&STYLES=&FORMAT=image/png&SRS=EPSG:2056&BBOX=2600000,1180000,2620000,1200000&WIDTH=512&HEIGHT=512"
curl -o /tmp/danger_latest.png "http://localhost:8080/mapproxy/service?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=avalanch.danger_latest&STYLES=&FORMAT=image/png&SRS=EPSG:2056&BBOX=2600000,1180000,2620000,1200000&WIDTH=512&HEIGHT=512"
```

If both PNG files are non-empty and capabilities list both layers, GeoServer/MapProxy is OK.

