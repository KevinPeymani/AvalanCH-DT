#!/usr/bin/env bash
set -euo pipefail

: "${DEM_PATH:?DEM_PATH is required}"
: "${SMET_TEMPLATE:?SMET_TEMPLATE is required}"
: "${SNO_TEMPLATE:?SNO_TEMPLATE is required}"
: "${INI_TEMPLATE:?INI_TEMPLATE is required}"
: "${OUTPUT_ROOT:?OUTPUT_ROOT is required}"

THREADS="${THREADS:-4}"
STRIDE="${STRIDE:-1}"
FEATURE_COLUMNS="${FEATURE_COLUMNS:-prediction/feature_columns.json}"
FEATURES_CSV="${FEATURES_CSV:-snowpack_features.csv}"
CELL_SIZE_ARG=""
END_TIME_ARG=""
SNOWPACK_BIN_ARG=""
MAX_CELLS_ARG=""

if [[ -n "${CELL_SIZE:-}" ]]; then
  CELL_SIZE_ARG="--cell-size ${CELL_SIZE}"
fi
if [[ -n "${END_TIME:-}" ]]; then
  END_TIME_ARG="--end-time ${END_TIME}"
fi
if [[ -n "${SNOWPACK_BIN:-}" ]]; then
  SNOWPACK_BIN_ARG="--snowpack-bin ${SNOWPACK_BIN}"
fi
if [[ -n "${MAX_CELLS:-}" ]]; then
  MAX_CELLS_ARG="--max-cells ${MAX_CELLS}"
fi

exec /usr/local/bin/grid_snowpack_service \
  --dem "${DEM_PATH}" \
  --smet-template "${SMET_TEMPLATE}" \
  --sno-template "${SNO_TEMPLATE}" \
  --ini-template "${INI_TEMPLATE}" \
  --output-root "${OUTPUT_ROOT}" \
  --threads "${THREADS}" \
  --stride "${STRIDE}" \
  --feature-columns "${FEATURE_COLUMNS}" \
  --features-csv "${FEATURES_CSV}" \
  ${CELL_SIZE_ARG} \
  ${END_TIME_ARG} \
  ${SNOWPACK_BIN_ARG} \
  ${MAX_CELLS_ARG}
