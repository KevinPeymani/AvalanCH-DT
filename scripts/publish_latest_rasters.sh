#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: publish_latest_rasters.sh [--with-geoserver]

Options:
  --with-geoserver   After copying latest rasters, publish/update GeoServer layers via REST API.
  -h, --help         Show this help.
EOF
}

with_geoserver=0
for arg in "$@"; do
  case "$arg" in
    --with-geoserver)
      with_geoserver=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_HS_DIR="$ROOT_DIR/Alpine3D/output"
SRC_DANGER_DIR="$ROOT_DIR/Alpine3D/output/grid_predictions"
DEST_DIR="${GEOSERVER_RASTER_SOURCE_DIR:-$ROOT_DIR/data/geoserver_external/rasters}"

convert_ascii_grid_to_lv95() {
  local src="$1"
  local dest="$2"

  LC_ALL=C awk '
    BEGIN {
      x_offset = 2000000.0
      y_offset = 1000000.0
    }
    NR == 3 && tolower($1) == "xllcorner" {
      val = $2
      gsub(/,/, ".", val)
      printf "%s %.3f\n", $1, val + x_offset
      next
    }
    NR == 4 && tolower($1) == "yllcorner" {
      val = $2
      gsub(/,/, ".", val)
      printf "%s %.3f\n", $1, val + y_offset
      next
    }
    { print }
  ' "$src" > "$dest"
}

mkdir -p "$DEST_DIR"

latest_hs="$(ls -1 "$SRC_HS_DIR"/*_HS.asc 2>/dev/null | sort | tail -n 1 || true)"
latest_danger="$(ls -1 "$SRC_DANGER_DIR"/*_danger.asc 2>/dev/null | sort | tail -n 1 || true)"

if [[ -z "$latest_hs" ]]; then
  echo "No HS raster found in $SRC_HS_DIR"
  exit 1
fi

if [[ -z "$latest_danger" ]]; then
  echo "No danger raster found in $SRC_DANGER_DIR"
  exit 1
fi

convert_ascii_grid_to_lv95 "$latest_hs" "$DEST_DIR/hs_latest.asc"
convert_ascii_grid_to_lv95 "$latest_danger" "$DEST_DIR/danger_latest.asc"

# EPSG:2056 (CH1903+ / LV95) for Arc/ASCII Grid sidecar PRJ.
cat > "$DEST_DIR/hs_latest.prj" <<'EOF'
PROJCS["CH1903+ / LV95",GEOGCS["CH1903+",DATUM["CH1903+",SPHEROID["Bessel 1841",6377397.155,299.1528128]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Hotine_Oblique_Mercator_Azimuth_Center"],PARAMETER["latitude_of_center",46.95240555555556],PARAMETER["longitude_of_center",7.439583333333333],PARAMETER["azimuth",90],PARAMETER["rectified_grid_angle",90],PARAMETER["scale_factor",1],PARAMETER["false_easting",2600000],PARAMETER["false_northing",1200000],UNIT["metre",1],AUTHORITY["EPSG","2056"]]
EOF

cp "$DEST_DIR/hs_latest.prj" "$DEST_DIR/danger_latest.prj"

echo "Published latest rasters to: $DEST_DIR"
echo "  HS:      $(basename "$latest_hs") -> hs_latest.asc"
echo "  Danger:  $(basename "$latest_danger") -> danger_latest.asc"
echo "  Header translation: LV03 -> LV95 applied to xllcorner/yllcorner"

if [[ "$with_geoserver" -eq 1 ]]; then
  "$ROOT_DIR/scripts/publish_geoserver_layers.sh"
fi
