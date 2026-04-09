# AvalanCH

## File structure

- app: the client's code (essentially the CesiumJS-based map)

## GeoServer + MapProxy integration (HS + danger)

This repository now includes:

- MapProxy layers for latest snow height and avalanche danger.
- A helper script that publishes the latest generated Arc/ASCII rasters into the GeoServer mounted folder.
- A REST automation script that creates/updates GeoServer workspace, stores, and layers.

### 1) Fully automated publish (recommended)

Run one command:

```bash
bash scripts/publish_latest_rasters.sh --with-geoserver
```

This will:

- copy latest Alpine3D outputs to `infra/geoserver_data/rasters/`
- write EPSG:2056 `.prj` files
- create/update GeoServer workspace `avalanch`
- create/update ArcGrid stores + layers `hs_latest` and `danger_latest`

Default GeoServer connection settings:

- URL: `http://localhost:8081/geoserver`
- user: `admin`
- password: `geoserver`

Override with environment variables if needed:

```bash
GEOSERVER_URL=http://localhost:8081/geoserver \
GEOSERVER_USER=admin \
GEOSERVER_PASSWORD=geoserver \
bash scripts/publish_latest_rasters.sh --with-geoserver
```

### 2) Raster copy only (without GeoServer REST)

Run:

```bash
bash scripts/publish_latest_rasters.sh
```

This creates/updates:

- `infra/geoserver_data/rasters/hs_latest.asc`
- `infra/geoserver_data/rasters/hs_latest.prj`
- `infra/geoserver_data/rasters/danger_latest.asc`
- `infra/geoserver_data/rasters/danger_latest.prj`

### 3) Optional manual GeoServer publish (UI fallback)

1. Open `http://localhost:8081/geoserver`.
2. Create workspace: `avalanch`.
3. Add Store -> ArcGrid for `hs_latest.asc`, then Publish as layer `hs_latest`.
4. Add Store -> ArcGrid for `danger_latest.asc`, then Publish as layer `danger_latest`.
5. For each layer set:

   - Native SRS: `EPSG:2056`
   - Declared SRS: `EPSG:2056`
   - Compute native and declared bounding boxes.

### 4) Restart MapProxy

```bash
docker compose up -d geoserver mapproxy
docker compose restart mapproxy
```

### 5) Test endpoints

MapProxy capabilities:

```bash
curl -s "http://localhost:8080/mapproxy/service?SERVICE=WMS&REQUEST=GetCapabilities" | grep -E "avalanch\.hs_latest|avalanch\.danger_latest"
```

GeoServer direct WMS (layer published):

```bash
curl -s "http://localhost:8081/geoserver/avalanch/wms?SERVICE=WMS&REQUEST=GetCapabilities" | grep -E "hs_latest|danger_latest"
```

Map image test (MapProxy -> GeoServer -> latest rasters):

```bash
curl -o /tmp/hs_latest.png "http://localhost:8080/mapproxy/service?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=avalanch.hs_latest&STYLES=&FORMAT=image/png&SRS=EPSG:2056&BBOX=2600000,1180000,2620000,1200000&WIDTH=512&HEIGHT=512"
curl -o /tmp/danger_latest.png "http://localhost:8080/mapproxy/service?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=avalanch.danger_latest&STYLES=&FORMAT=image/png&SRS=EPSG:2056&BBOX=2600000,1180000,2620000,1200000&WIDTH=512&HEIGHT=512"
```

If these PNG files are non-empty and capabilities include the two layers, the integration works.

