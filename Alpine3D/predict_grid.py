from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import joblib
import numpy as np
from tensorflow.keras.layers import Dense
from tensorflow.keras.models import load_model


ROOT = Path(__file__).resolve().parents[1]
PREDICTION_DIR = ROOT / "prediction"
ALPINE_OUTPUT_DIR = ROOT / "Alpine3D" / "output"
GRID_PRED_DIR = ALPINE_OUTPUT_DIR / "grid_predictions"

if str(PREDICTION_DIR) not in sys.path:
	sys.path.insert(0, str(PREDICTION_DIR))

from parse_profile import extract_all_features  # noqa: E402
from predict import (  # noqa: E402
	build_live_features_from_hourly,
	build_snowpack_forcing_from_hourly,
	fetch_station_measurements_hourly,
)
from run_pipeline import run_snowpack, setup_snowpack_files  # noqa: E402


@dataclass
class AscGrid:
	header_lines: list[str]
	data: np.ndarray
	nodata: float


class DenseCompat(Dense):
	@classmethod
	def from_config(cls, config):
		patched = dict(config)
		patched.pop("quantization_config", None)
		return super().from_config(patched)


def load_model_compat(model_path: Path):
	try:
		return load_model(model_path, compile=False)
	except (TypeError, ValueError) as exc:
		message = str(exc)
		if "quantization_config" not in message:
			raise
		return load_model(model_path, custom_objects={"Dense": DenseCompat}, compile=False)


def read_asc_grid(path: Path) -> AscGrid:
	with path.open("r", encoding="utf-8") as f:
		header = [next(f).rstrip("\n") for _ in range(6)]
		data = np.loadtxt(f)

	nodata = -999.0
	for line in header:
		parts = line.split()
		if len(parts) >= 2 and parts[0].lower() == "nodata_value":
			try:
				nodata = float(parts[1])
			except ValueError:
				pass

	return AscGrid(header_lines=header, data=data, nodata=nodata)


def write_asc_grid(path: Path, header_lines: list[str], data: np.ndarray) -> None:
	with path.open("w", encoding="utf-8") as f:
		for line in header_lines:
			f.write(f"{line}\n")
		np.savetxt(f, data, fmt="%.3f")


def discover_triplets(output_dir: Path) -> list[str]:
	pattern = re.compile(r"^(?P<stamp>.+)_(HS|SWE|TSG)\.asc$")
	grouped: dict[str, set[str]] = {}
	for file_path in output_dir.glob("*.asc"):
		match = pattern.match(file_path.name)
		if not match:
			continue
		stamp = match.group("stamp")
		grouped.setdefault(stamp, set()).add(file_path.name.rsplit("_", 1)[1].split(".")[0])

	complete = [stamp for stamp, params in grouped.items() if {"HS", "SWE", "TSG"}.issubset(params)]
	return sorted(complete)


def parse_snowpack_features(station_code: str, period_in_days: int) -> dict[str, float]:
	hourly = fetch_station_measurements_hourly(station_code=station_code, period_in_days=period_in_days)
	live_features = build_live_features_from_hourly(hourly)
	hourly_forcing = build_snowpack_forcing_from_hourly(hourly)

	current_dir = os.getcwd()
	try:
		os.chdir(PREDICTION_DIR)
		cleanup_prediction_outputs(station_code)
		end_time = setup_snowpack_files(
			live_features,
			hourly_weather_df=hourly_forcing,
			station_code=station_code,
		)
		run_snowpack_with_fallback(end_time)

		pro_path = PREDICTION_DIR / "output" / f"{station_code}_IMIS_LIVE.pro"
		smet_path = PREDICTION_DIR / "output" / f"{station_code}_IMIS_LIVE.smet"
		extra_features = extract_all_features(str(pro_path), str(smet_path))
	finally:
		os.chdir(current_dir)

	return {**live_features, **extra_features}


def cleanup_prediction_outputs(station_code: str) -> None:
	output_dir = PREDICTION_DIR / "output"
	if not output_dir.exists():
		return

	for suffix in ("*.smet", "*.pro", "*.haz", "*.sno", "*.ini"):
		for path in output_dir.glob(f"{station_code}_IMIS_LIVE{suffix[1:]}"):
			path.unlink(missing_ok=True)


def run_snowpack_with_fallback(end_time: str) -> None:
	try:
		run_snowpack(end_time)
		return
	except RuntimeError as exc:
		message = str(exc)
		fallback_markers = [
			"undefined symbol",
			"No such file or directory",
			"not found",
			"exit 127",
		]
		if not any(marker in message for marker in fallback_markers):
			raise

	print("Local snowpack binary failed, retrying with dockerized snowpack...")
	repo_root = str(ROOT)
	docker_host = os.environ.get("DOCKER_HOST", "unix:///home/laura/.docker/desktop/docker.sock")

	command = [
		"docker",
		"run",
		"--rm",
		"--entrypoint",
		"/opt/alpine3d/bin/snowpack",
		"-v",
		f"{repo_root}:{repo_root}",
		"-w",
		f"{repo_root}/prediction",
		"alpine3d:local",
		"-c",
		"cfgfiles/io.ini",
		"-e",
		end_time,
	]

	env = os.environ.copy()
	env["DOCKER_HOST"] = docker_host
	subprocess.run(command, check=True, env=env)


def maybe_kelvin_to_celsius(values: np.ndarray) -> np.ndarray:
	if np.nanmean(values) > 150.0:
		return values - 273.15
	return values


def build_prediction_matrix(
	hs_grid: np.ndarray,
	swe_grid: np.ndarray,
	tsg_grid: np.ndarray,
	valid_mask: np.ndarray,
	global_features: dict[str, float],
	feature_cols: list[str],
	scaler_means: np.ndarray,
	hs_new_24: np.ndarray,
	hs_new_7d: np.ndarray,
) -> np.ndarray:
	valid_count = int(valid_mask.sum())
	X = np.tile(scaler_means, (valid_count, 1))

	for idx, col in enumerate(feature_cols):
		value = global_features.get(col)
		if value is None:
			continue
		if isinstance(value, (int, float)) and np.isfinite(value):
			X[:, idx] = float(value)

	hs_cm = hs_grid[valid_mask] * 100.0
	swe_vals = swe_grid[valid_mask]
	tsg_vals = maybe_kelvin_to_celsius(tsg_grid[valid_mask])
	hn24_vals = hs_new_24[valid_mask] * 100.0
	hn7d_vals = hs_new_7d[valid_mask] * 100.0

	for idx, col in enumerate(feature_cols):
		if col == "HS_meas":
			X[:, idx] = hs_cm
		elif col == "SWE":
			X[:, idx] = swe_vals
		elif col == "TSG":
			X[:, idx] = tsg_vals
		elif col == "HN24":
			X[:, idx] = hn24_vals
		elif col == "HN24_7d":
			X[:, idx] = hn7d_vals
		elif col == "HN72_24":
			X[:, idx] = np.maximum(hn7d_vals - hn24_vals, 0.0)

	return X


def save_png_map(path: Path, grid: np.ndarray, nodata: float) -> None:
	try:
		import matplotlib.pyplot as plt
	except ImportError:
		return

	display_grid = np.where(grid == nodata, np.nan, grid)
	plt.figure(figsize=(9, 6))
	cmap = plt.get_cmap("YlOrRd", 5)
	im = plt.imshow(display_grid, cmap=cmap, vmin=1, vmax=5)
	plt.colorbar(im, ticks=[1, 2, 3, 4, 5], label="Danger Level")
	plt.title(path.stem)
	plt.axis("off")
	plt.tight_layout()
	plt.savefig(path, dpi=180)
	plt.close()


def run_grid_prediction(station_code: str, period_in_days: int, save_png: bool) -> None:
	model_path = PREDICTION_DIR / "avalanche_model.h5"
	scaler_path = PREDICTION_DIR / "imis_scaler.pkl"
	cols_path = PREDICTION_DIR / "feature_columns.json"

	if not model_path.exists() or not scaler_path.exists() or not cols_path.exists():
		raise FileNotFoundError("Missing one or more model artifacts in prediction/.")

	with cols_path.open("r", encoding="utf-8") as f:
		feature_cols = json.load(f)

	scaler = joblib.load(scaler_path)
	model = load_model_compat(model_path)
	global_features = parse_snowpack_features(station_code=station_code, period_in_days=period_in_days)

	stamps = discover_triplets(ALPINE_OUTPUT_DIR)
	if not stamps:
		raise RuntimeError("No complete HS/SWE/TSG ASC triplets found in Alpine3D/output.")

	GRID_PRED_DIR.mkdir(parents=True, exist_ok=True)

	hs_history: list[np.ndarray] = []

	for stamp in stamps:
		hs = read_asc_grid(ALPINE_OUTPUT_DIR / f"{stamp}_HS.asc")
		swe = read_asc_grid(ALPINE_OUTPUT_DIR / f"{stamp}_SWE.asc")
		tsg = read_asc_grid(ALPINE_OUTPUT_DIR / f"{stamp}_TSG.asc")

		valid_mask = (hs.data != hs.nodata) & (swe.data != swe.nodata) & (tsg.data != tsg.nodata)
		if not valid_mask.any():
			continue

		if hs_history:
			hs_new_24 = np.maximum(hs.data - hs_history[-1], 0.0)
		else:
			hs_new_24 = np.zeros_like(hs.data)

		hs_history.append(hs.data.copy())
		window = hs_history[-7:]
		hs_new_7d = np.zeros_like(hs.data)
		for i in range(1, len(window)):
			hs_new_7d += np.maximum(window[i] - window[i - 1], 0.0)

		X = build_prediction_matrix(
			hs_grid=hs.data,
			swe_grid=swe.data,
			tsg_grid=tsg.data,
			valid_mask=valid_mask,
			global_features=global_features,
			feature_cols=feature_cols,
			scaler_means=np.asarray(scaler.mean_),
			hs_new_24=hs_new_24,
			hs_new_7d=hs_new_7d,
		)

		X_scaled = scaler.transform(X)
		probs = model.predict(X_scaled, verbose=0)
		levels = np.argmax(probs, axis=1) + 1

		pred_grid = np.full(hs.data.shape, hs.nodata, dtype=float)
		pred_grid[valid_mask] = levels.astype(float)

		asc_out = GRID_PRED_DIR / f"{stamp}_danger.asc"
		write_asc_grid(asc_out, hs.header_lines, pred_grid)

		if save_png:
			png_out = GRID_PRED_DIR / f"{stamp}_danger.png"
			save_png_map(png_out, pred_grid, hs.nodata)

		print(f"Wrote {asc_out}")


def main() -> None:
	parser = argparse.ArgumentParser(description="Run avalanche danger prediction on Alpine3D ASC grids.")
	parser.add_argument("--station", default="ZER2", help="IMIS station code used for Snowpack feature extraction")
	parser.add_argument("--days", type=int, default=7, help="IMIS period_in_days for forcing/Snowpack")
	parser.add_argument("--no-png", action="store_true", help="Disable PNG map export")
	args = parser.parse_args()

	run_grid_prediction(station_code=args.station, period_in_days=args.days, save_png=not args.no_png)


if __name__ == "__main__":
	main()
