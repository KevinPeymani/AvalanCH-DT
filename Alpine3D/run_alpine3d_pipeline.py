#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pandas as pd
import requests


URL_MEASUREMENT = "https://measurement-api.slf.ch/public/api/imis/station/{station_code}/measurements"

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
BASE_IO_INI = SCRIPT_DIR / "io.ini"
RUNTIME_IO_INI = SCRIPT_DIR / "io.runtime.ini"
INPUT_DIR = SCRIPT_DIR / "input"
OUTPUT_DIR = SCRIPT_DIR / "output"
STATIONS_JSON = REPO_ROOT / "clients" / "web" / "public" / "stations.json"

DEFAULT_STATION_META = {
	"station_abbr": "ZER",
	"station_name": "Zermatt",
	"alt": 1640.0,
	"lat": 46.029272,
	"lon": 7.752433,
	"x": 2624297.24,
	"y": 1097573.81,
}

RUNTIME_PATH_KEYS = {
	"METEOPATH": str(INPUT_DIR),
	"GRID2DPATH": str(SCRIPT_DIR / "prep" / "surface_grids"),
	"DEMFILE": str(SCRIPT_DIR / "prep" / "surface_grids" / "dem_50m.asc"),
	"LANDUSEFILE": str(SCRIPT_DIR / "prep" / "surface_grids" / "landuse_50m.asc"),
	"SNOWPATH": str(INPUT_DIR),
}

OUTPUT_PATH_KEYS = {
	"GRID2DPATH": str(OUTPUT_DIR),
	"METEOPATH": str(OUTPUT_DIR),
}
STEFAN_BOLTZMANN = 5.670374419e-8


def derive_ilwr_from_components(ta_c, rh_pct, rswr_wm2):
	ta = np.asarray(ta_c, dtype=float)
	rh = np.clip(np.asarray(rh_pct, dtype=float), 1.0, 100.0)
	rswr = np.clip(np.asarray(rswr_wm2, dtype=float), 0.0, 1200.0)

	tk = ta + 273.15
	es_kpa = 0.611 * np.exp((17.27 * ta) / (ta + 237.3))
	ea_kpa = (rh / 100.0) * es_kpa

	eps_clear = 1.24 * np.power(np.maximum(ea_kpa, 1e-6) / np.maximum(tk, 1.0), 1.0 / 7.0)
	eps_clear = np.clip(eps_clear, 0.62, 0.98)

	daylight_fraction = np.clip(rswr / 800.0, 0.0, 1.0)
	cloudiness = 1.0 - daylight_fraction
	eps_effective = np.clip(eps_clear + 0.25 * cloudiness, 0.65, 1.0)

	ilwr = eps_effective * STEFAN_BOLTZMANN * np.power(tk, 4)
	ilwr = np.clip(ilwr, 180.0, 420.0)

	if ilwr.size == 1:
		return float(ilwr.item())
	return ilwr


def derive_ilwr_series(hourly_df: pd.DataFrame) -> pd.Series:
	ta = hourly_df.get("TA_30MIN_MEAN", pd.Series(-1.0, index=hourly_df.index))
	rh = hourly_df.get("RH_30MIN_MEAN", pd.Series(85.0, index=hourly_df.index))
	rswr = hourly_df.get("RSWR_30MIN_MEAN", pd.Series(150.0, index=hourly_df.index))
	values = derive_ilwr_from_components(ta.to_numpy(), rh.to_numpy(), rswr.to_numpy())
	return pd.Series(values, index=hourly_df.index, dtype=float)


def fetch_station_measurements_hourly(station_code: str, period_in_days: int) -> pd.DataFrame:
	request_days = 1 if period_in_days <= 1 else 3 if period_in_days <= 3 else 7
	query_codes = [station_code]
	base_station = station_code.upper().rstrip("0123456789")
	if base_station and base_station not in query_codes:
		query_codes.append(base_station)

	response = None
	last_error: Exception | None = None
	for query_code in query_codes:
		response = requests.get(
			URL_MEASUREMENT.format(station_code=query_code),
			params={"period_in_days": request_days},
			timeout=30,
		)
		try:
			response.raise_for_status()
			break
		except requests.HTTPError as exc:
			last_error = exc
			if response.status_code != 422 or query_code == query_codes[-1]:
				raise
			continue

	if response is None:
		raise RuntimeError(f"Could not query IMIS measurements for station {station_code}: {last_error}")

	data = response.json()
	if not data:
		raise ValueError(f"No IMIS data returned for station {station_code}")

	frame = pd.DataFrame(data)
	if "measure_date" not in frame.columns:
		raise ValueError("IMIS response does not contain 'measure_date'")

	frame["measure_date"] = pd.to_datetime(frame["measure_date"], utc=True, errors="coerce")
	frame = frame.dropna(subset=["measure_date"]).sort_values("measure_date")
	frame = frame.set_index("measure_date")

	for column in frame.columns:
		if column != "station_code":
			frame[column] = pd.to_numeric(frame[column], errors="coerce")

	numeric_columns = [column for column in frame.columns if column != "station_code"]
	hourly = frame[numeric_columns].resample("1h").mean().ffill()
	if period_in_days > 0:
		cutoff = hourly.index.max() - pd.Timedelta(days=period_in_days)
		hourly = hourly[hourly.index >= cutoff]
	if hourly.empty:
		raise ValueError(f"Hourly aggregation returned no data for station {station_code}")
	return hourly


def _find_station_metadata(station_code: str) -> dict:
	station_abbr = station_code.upper().rstrip("0123456789")
	metadata = DEFAULT_STATION_META.copy()
	metadata["station_abbr"] = station_abbr
	metadata["station_name"] = station_abbr

	if STATIONS_JSON.exists():
		with STATIONS_JSON.open() as handle:
			stations = json.load(handle)
		match = next(
			(
				station
				for station in stations
				if str(station.get("station_abbr", "")).upper() == station_abbr
			),
			None,
		)
		if match:
			metadata.update(match)
			metadata["station_name"] = match.get("station_name") or station_abbr
			metadata["lat"] = match.get("lat") if match.get("lat") is not None else metadata["lat"]
			metadata["lon"] = match.get("lon") if match.get("lon") is not None else metadata["lon"]
			metadata["alt"] = match.get("alt") if match.get("alt") is not None else metadata["alt"]

	return metadata


def write_alpine3d_smet(station_code: str, hourly_df: pd.DataFrame, metadata: dict) -> Path:
	INPUT_DIR.mkdir(parents=True, exist_ok=True)
	output_path = INPUT_DIR / f"{station_code}.smet"

	hs_series = hourly_df.get("HS", pd.Series(0.0, index=hourly_df.index)).astype(float) / 100.0
	hs_increase = hs_series.diff().clip(lower=0).fillna(0.0)
	# The IMIS endpoint does not expose gridded snowfall forcing here, so use positive
	# snow-height increments as a simple SWE proxy to avoid zero-snow Alpine3D runs.
	derived_psum = hs_increase * 100.0

	forcing = pd.DataFrame(index=hourly_df.index)
	forcing["TA"] = hourly_df.get("TA_30MIN_MEAN", pd.Series(-1.0, index=hourly_df.index)) + 273.15
	forcing["RH"] = hourly_df.get("RH_30MIN_MEAN", pd.Series(85.0, index=hourly_df.index)) / 100.0
	forcing["VW"] = hourly_df.get("VW_30MIN_MEAN", pd.Series(2.0, index=hourly_df.index))
	forcing["DW"] = hourly_df.get("DW_30MIN_MEAN", pd.Series(180.0, index=hourly_df.index))
	forcing["ISWR"] = hourly_df.get("RSWR_30MIN_MEAN", pd.Series(150.0, index=hourly_df.index))
	derived_ilwr = derive_ilwr_series(hourly_df)
	forcing["ILWR"] = hourly_df.get("ILWR_30MIN_MEAN", derived_ilwr).fillna(derived_ilwr)
	forcing["HS"] = hs_series
	forcing["TSG"] = hourly_df.get("TS0_30MIN_MEAN", pd.Series(-0.5, index=hourly_df.index)) + 273.15
	forcing["PSUM"] = hourly_df.get("PSUM", derived_psum).fillna(derived_psum)
	forcing = forcing.ffill().bfill().fillna(0.0)

	rows = []
	for timestamp, row in forcing.iterrows():
		local_time = timestamp.tz_convert(None) if timestamp.tzinfo is not None else timestamp
		rows.append(
			"{time} {ta:.2f} {rh:.3f} {vw:.2f} {dw:.1f} {iswr:.1f} {ilwr:.1f} {hs:.3f} {tsg:.2f} {psum:.3f}".format(
				time=local_time.strftime("%Y-%m-%dT%H:%M:%S"),
				ta=float(row["TA"]),
				rh=float(row["RH"]),
				vw=float(row["VW"]),
				dw=float(row["DW"]),
				iswr=float(row["ISWR"]),
				ilwr=float(row["ILWR"]),
				hs=float(row["HS"]),
				tsg=float(row["TSG"]),
				psum=float(row["PSUM"]),
			)
		)

	content = "\n".join(
		[
			"SMET 1.1 ASCII",
			"[HEADER]",
			f"station_id       = {station_code}",
			f"station_name     = {metadata['station_name']}",
			f"station_abbr     = {metadata['station_abbr']}",
			f"latitude         = {float(metadata['lat'])}",
			f"longitude        = {float(metadata['lon'])}",
			f"altitude         = {float(metadata['alt'])}",
			"nodata           = -999",
			"tz               = 1",
			"fields           = timestamp TA RH VW DW ISWR ILWR HS TSG PSUM",
			"[DATA]",
			*rows,
			"",
		]
	)
	output_path.write_text(content)
	return output_path


def write_alpine3d_poi(station_code: str, metadata: dict) -> Path:
	poi_path = INPUT_DIR / f"{station_code}.poi"
	content = "\n".join(
		[
			"SMET 1.1 ASCII",
			"[HEADER]",
			f"station_id       = {station_code}",
			"comment          = Point of interest for Alpine3D profile outputs",
			"epsg             = 2056",
			"nodata           = -999",
			"fields           = easting northing altitude",
			"[DATA]",
			f"{float(metadata['x']):.2f} {float(metadata['y']):.2f} {float(metadata['alt']):.1f}",
			"",
		]
	)
	poi_path.write_text(content)
	return poi_path


def write_initial_snow_restarts(hourly_df: pd.DataFrame, metadata: dict) -> list[Path]:
	profile_time = hourly_df.index[0]
	profile_arg = profile_time.tz_convert(None).strftime("%Y-%m-%dT%H:%M:%S") if profile_time.tzinfo is not None else profile_time.strftime("%Y-%m-%dT%H:%M:%S")
	initial_hs = max(float(hourly_df.get("HS", pd.Series([0.0])).iloc[0]) / 100.0, 0.05)
	initial_temp = float(hourly_df.get("TS0_30MIN_MEAN", pd.Series([-0.5])).iloc[0]) + 273.15

	content = "\n".join(
		[
			"SMET 1.1 ASCII",
			"[HEADER]",
			"station_id       = NO_EXP",
			"station_name     = Synthetic_Initial_Snowpack",
			f"latitude         = {float(metadata['lat'])}",
			f"longitude        = {float(metadata['lon'])}",
			f"altitude         = {float(metadata['alt'])}",
			"nodata           = -999",
			"tz               = 1",
			f"ProfileDate      = {profile_arg}",
			f"HS_Last          = {initial_hs:.6f}",
			"SlopeAngle       = 0.00",
			"SlopeAzi         = 0.00",
			"nSoilLayerData   = 0",
			"nSnowLayerData   = 1",
			"SoilAlbedo       = 0.09",
			"BareSoil_z0      = 0.020",
			"CanopyHeight     = 0.000",
			"CanopyLeafAreaIndex = 0.000000",
			"CanopyDirectThroughfall = 1.00",
			"SoilEmissivity   = 0.95",
			"ErosionLevel     = 0",
			"TimeCountDeltaHS = 0.000000",
			"fields           = timestamp Layer_Thick  T  Vol_Frac_I  Vol_Frac_W  Vol_Frac_V  Vol_Frac_S Rho_S Conduc_S HeatCapac_S  rg  rb  dd  sp  mk mass_hoar ne CDot metamo",
			"[DATA]",
			f"{profile_arg}     {initial_hs:.6f}   {initial_temp:.6f}     0.350000     0.000000     0.650000     0.000000       0.0     0.000          0.0    0.300000   0.200000   0.000000   1.000000     12      0.000000    1    -2000.000000        0.000000",
			"",
		]
	)

	written_paths: list[Path] = []
	for path in sorted(INPUT_DIR.glob("NO_EXP_*.sno")):
		path.write_text(content)
		written_paths.append(path)

	return written_paths


def write_runtime_io_ini(station_code: str, poi_path: Path | None) -> Path:
	lines = BASE_IO_INI.read_text().splitlines()
	output_lines: list[str] = []
	inserted_poi = poi_path is None
	in_output = False
	output_replaced = {"PROF_ID_OR_MK": False, "OUT_METEO": False, "EXPERIMENT": False, "METEOPATH": False, "TS_WRITE": False}

	for line in lines:
		stripped = line.strip()
		if "=" in stripped and not stripped.startswith(";"):
			key, _, _ = stripped.partition("=")
			config_key = key.strip()
			if in_output and config_key in OUTPUT_PATH_KEYS:
				output_lines.append(f"{config_key} = {OUTPUT_PATH_KEYS[config_key]}")
				if config_key == "METEOPATH":
					output_replaced["METEOPATH"] = True
				continue
			if not in_output and config_key in RUNTIME_PATH_KEYS:
				output_lines.append(f"{config_key} = {RUNTIME_PATH_KEYS[config_key]}")
				continue
		if stripped.startswith("[") and stripped.endswith("]"):
			if not inserted_poi and stripped == "[InputEditing]" and poi_path is not None:
				output_lines.extend([
					f"POI = SMET",
					f"POIFILE = {poi_path}",
				])
				inserted_poi = True
			in_output = stripped == "[Output]"
			output_lines.append(line)
			continue

		if stripped.startswith("POI =") or stripped.startswith("POIFILE ="):
			continue

		if in_output:
			if stripped.startswith("TS_WRITE"):
				output_lines.append("TS_WRITE = FALSE")
				output_replaced["TS_WRITE"] = True
				continue
			if stripped.startswith("PROF_ID_OR_MK"):
				output_lines.append("PROF_ID_OR_MK = MK")
				output_replaced["PROF_ID_OR_MK"] = True
				continue
			if stripped.startswith("OUT_METEO"):
				output_lines.append("OUT_METEO = FALSE")
				output_replaced["OUT_METEO"] = True
				continue
			if stripped.startswith("EXPERIMENT"):
				output_lines.append("EXPERIMENT = NO_EXP")
				output_replaced["EXPERIMENT"] = True
				continue
			if stripped.startswith("METEOPATH"):
				output_lines.append(f"METEOPATH = {OUTPUT_DIR}")
				output_replaced["METEOPATH"] = True
				continue

		output_lines.append(line)

	if poi_path is not None and not inserted_poi:
		raise RuntimeError("Failed to inject POI settings into runtime Alpine3D config")

	if "[Output]" in output_lines:
		output_index = output_lines.index("[Output]") + 1
		extras = []
		if not output_replaced["METEOPATH"]:
			extras.append(f"METEOPATH = {OUTPUT_DIR}")
		if not output_replaced["EXPERIMENT"]:
			extras.append("EXPERIMENT = NO_EXP")
		if not output_replaced["PROF_ID_OR_MK"]:
			extras.append("PROF_ID_OR_MK = MK")
		if not output_replaced["OUT_METEO"]:
			extras.append("OUT_METEO = FALSE")
		if not output_replaced["TS_WRITE"]:
			extras.append("TS_WRITE = FALSE")
		for extra in reversed(extras):
			output_lines.insert(output_index, extra)

	RUNTIME_IO_INI.write_text("\n".join(output_lines) + "\n")
	return RUNTIME_IO_INI


def cleanup_partial_special_point_outputs() -> None:
	for pattern in ("*.pro", "*.haz", "*.sno", "*_meteo.smet"):
		for path in OUTPUT_DIR.glob(pattern):
			path.unlink(missing_ok=True)


def run_alpine3d(start_time: pd.Timestamp, end_time: pd.Timestamp, image: str, np_threads: int, binary: str | None = None) -> None:
	start_arg = start_time.tz_convert(None).strftime("%Y-%m-%dT%H:%M:%S") if start_time.tzinfo is not None else start_time.strftime("%Y-%m-%dT%H:%M:%S")
	end_arg = end_time.tz_convert(None).strftime("%Y-%m-%dT%H:%M:%S") if end_time.tzinfo is not None else end_time.strftime("%Y-%m-%dT%H:%M:%S")
	if binary:
		command = [
			binary,
			"-a",
			start_arg,
			"-z",
			end_arg,
			"-i",
			str(RUNTIME_IO_INI),
		]
		env = {**dict(os.environ), "OMP_NUM_THREADS": str(np_threads)}
		cwd = str(SCRIPT_DIR)
	else:
		if shutil.which("docker") is None:
			raise RuntimeError("docker is not available on PATH")
		command = [
			"docker",
			"run",
			"--rm",
			"--entrypoint",
			"/opt/alpine3d/bin/alpine3d",
			"-v",
			f"{REPO_ROOT}:{REPO_ROOT}",
			"-w",
			str(SCRIPT_DIR),
			"-e",
			f"OMP_NUM_THREADS={np_threads}",
			image,
			"-a",
			start_arg,
			"-z",
			end_arg,
			"-i",
			str(RUNTIME_IO_INI),
		]
		env = None
		cwd = None
	result = subprocess.run(command, check=False, capture_output=True, text=True, env=env, cwd=cwd)
	if result.stdout:
		print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
	if result.stderr:
		print(result.stderr, end="" if result.stderr.endswith("\n") else "\n")
	if result.returncode != 0:
		raise subprocess.CalledProcessError(result.returncode, command, output=result.stdout, stderr=result.stderr)


def main() -> None:
	parser = argparse.ArgumentParser(description="Fetch live IMIS data and run Alpine3D for one station.")
	parser.add_argument("--station", default="ZER2", help="IMIS station code to fetch and write as Alpine3D forcing.")
	parser.add_argument("--days", type=int, default=7, help="Number of past days to request from the IMIS API.")
	parser.add_argument("--np", type=int, default=2, help="OMP thread count passed into the Alpine3D container.")
	parser.add_argument("--image", default="alpine3d:local", help="Docker image to use for the Alpine3D run.")
	parser.add_argument("--binary", default=None, help="Optional local Alpine3D binary path. If set, run directly instead of via docker.")
	parser.add_argument("--dry-run", action="store_true", help="Only fetch/write files, do not invoke Docker.")
	args = parser.parse_args()

	OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
	metadata = _find_station_metadata(args.station)
	hourly = fetch_station_measurements_hourly(args.station, args.days)
	smet_path = write_alpine3d_smet(args.station, hourly, metadata)
	poi_path = write_alpine3d_poi(args.station, metadata)
	restart_paths = write_initial_snow_restarts(hourly, metadata)
	runtime_ini = write_runtime_io_ini(args.station, poi_path)

	first_time = hourly.index[0]
	last_time = hourly.index[-1]
	print(f"Fetched IMIS measurements for station {args.station}: {len(hourly)} hourly rows")
	print(f"Wrote forcing SMET: {smet_path}")
	print(f"Wrote POI file: {poi_path}")
	print(f"Seeded {len(restart_paths)} Alpine3D restart snow files")
	print(f"Wrote runtime config: {runtime_ini}")

	if args.dry_run:
		return

	try:
		run_alpine3d(first_time, last_time, args.image, args.np, args.binary)
	except subprocess.CalledProcessError as exc:
		combined_output = f"{exc.output or ''}\n{exc.stderr or ''}"
		if "Date object is undefined" not in combined_output:
			raise
		print("POI-enabled run hit the known Alpine3D special-point SMET writer bug. Retrying without POI outputs.")
		cleanup_partial_special_point_outputs()
		write_runtime_io_ini(args.station, None)
		run_alpine3d(first_time, last_time, args.image, args.np, args.binary)


if __name__ == "__main__":
	main()
