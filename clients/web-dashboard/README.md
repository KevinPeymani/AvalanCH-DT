# AvalanCH Web Dashboard

Frontend + API service for visualizing:

- today's avalanche danger and snow height from local project rasters
- current snow profile via niViz
- last 7 days meteorological station stats
- historical snow height and danger evolution

Note: the Today map colorizes danger/snow overlays directly in the dashboard from latest raster outputs so grayscale source assets can still be used by Godot.

## Run locally

```bash
npm install
npm run build
npm run start
```

The service runs on port `8090` by default.

## Important environment variables

- `GEOSERVER_BASE_URL` default `http://localhost:8081/geoserver`
- `GEOSERVER_WORKSPACE` default `avalanch`
- `GEOSERVER_HS_LAYER` default `hs_latest`
- `GEOSERVER_DANGER_LAYER` default `danger_latest`
- `GEOSERVER_HS_STYLE` optional WMS style name used to colorize snow-height raster
- `GEOSERVER_DANGER_STYLE` optional WMS style name used to colorize avalanche-danger raster
- `DEM_TILES_URL` optional terrain-rgb tile URL for true 3D terrain in maplibre
- `DEM_ASC_FILE` default `/workspace/Alpine3D/prep/surface_grids/dem_50m.asc`
- `MAP_BOUNDS` default `7.45,45.85,8.15,46.2`
- `ALPINE_OUTPUT_DIR` default `/workspace/Alpine3D/output`
- `DANGER_OUTPUT_DIR` default `/workspace/Alpine3D/output/grid_predictions`
- `GEOSERVER_EXTERNAL_RASTERS_DIR` default `/workspace/data/geoserver_external/rasters` (Today page overlays)
- `TODAY_DANGER_OUTPUT_DIR` optional override for Today danger raster source
- `TODAY_HS_OUTPUT_DIR` optional override for Today HS raster source
- `SMET_FILE` default `/workspace/Alpine3D/input/ZER2.smet`
- `PROFILE_DIR` default `/workspace/prediction/output`
- `ALPINE3D_STATUS_FILE` default `/workspace/Alpine3D/output/scheduler/alpine3d_publish_status.json` (used by Runs page)
- `ALPINE3D_TRIGGER_FILE` default `/workspace/Alpine3D/output/scheduler/manual_run.request` (Run Now button writes this)

## niViz integration

The Snow Profile page opens:
`https://run.niviz.org/?file=<absolute_url_to_latest_pro_file>`

The API exposes profile files under `/profiles/*` with permissive CORS so niViz can fetch them.
