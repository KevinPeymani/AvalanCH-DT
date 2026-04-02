from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import rasterio
from pyproj import Transformer


@dataclass(frozen=True)
class CameraGeometry:
    latitude: float
    longitude: float
    elevation_m: float
    north_deg: float
    fov_deg: float
    raw_width: int
    raw_height: int
    is_panorama: bool
    focal_length_mm: float | None = None


class DemSampler:
    def __init__(
        self,
        dem_path: str,
        target_epsg: int,
        expected_resolution_m: float,
        nodata_fallback: float | None = None,
        enable_ground_sampling: bool = True,
    ):
        self.dem_path = dem_path
        self.expected_resolution_m = expected_resolution_m
        self.nodata_fallback = nodata_fallback
        self.enable_ground_sampling = enable_ground_sampling

        self._dataset = None
        self._to_dem = None
        self._opened = False
        self._target_epsg = target_epsg
        self.meta: dict[str, Any] = {
            "enabled": False,
            "path": dem_path,
        }

        if dem_path:
            self._open()

    def _open(self) -> None:
        path = Path(self.dem_path)
        if not path.exists():
            raise FileNotFoundError(f"DEM not found: {path}")

        self._dataset = rasterio.open(path)
        self._opened = True
        self.meta = {
            "enabled": True,
            "path": str(path),
            "crs": str(self._dataset.crs),
            "width": int(self._dataset.width),
            "height": int(self._dataset.height),
            "bounds": {
                "left": float(self._dataset.bounds.left),
                "bottom": float(self._dataset.bounds.bottom),
                "right": float(self._dataset.bounds.right),
                "top": float(self._dataset.bounds.top),
            },
            "resolution_m": {
                "x": float(abs(self._dataset.transform.a)),
                "y": float(abs(self._dataset.transform.e)),
            },
            "expected_resolution_m": float(self.expected_resolution_m),
        }

        if self._dataset.crs is None:
            raise ValueError("DEM has no CRS")

        dem_epsg = self._dataset.crs.to_epsg()
        if dem_epsg is not None and int(dem_epsg) == int(self._target_epsg):
            self._to_dem = None
        else:
            self._to_dem = Transformer.from_crs(
                f"EPSG:{self._target_epsg}",
                self._dataset.crs,
                always_xy=True,
            )

    def sample_lv95(self, east: float, north: float) -> dict[str, Any]:
        if not self._opened or self._dataset is None:
            return {
                "available": False,
                "reason": "dem_not_configured",
            }

        if not self.enable_ground_sampling:
            return {
                "available": False,
                "reason": "ground_sampling_disabled",
            }

        x, y = east, north
        if self._to_dem is not None:
            x, y = self._to_dem.transform(east, north)

        row, col = self._dataset.index(x, y)
        inside = 0 <= row < self._dataset.height and 0 <= col < self._dataset.width
        if not inside:
            return {
                "available": False,
                "reason": "outside_dem_extent",
                "dem_x": float(x),
                "dem_y": float(y),
            }

        arr = self._dataset.read(1, window=((row, row + 1), (col, col + 1)))
        if arr.size == 0:
            return {
                "available": False,
                "reason": "empty_sample",
                "dem_x": float(x),
                "dem_y": float(y),
            }

        value = float(arr[0, 0])
        nodata = self._dataset.nodata
        if nodata is not None and math.isclose(value, float(nodata), rel_tol=0.0, abs_tol=1e-9):
            if self.nodata_fallback is None:
                return {
                    "available": False,
                    "reason": "nodata",
                    "dem_x": float(x),
                    "dem_y": float(y),
                }
            value = float(self.nodata_fallback)

        return {
            "available": True,
            "ground_elevation_m": value,
            "dem_x": float(x),
            "dem_y": float(y),
            "row": int(row),
            "col": int(col),
        }


class SwissProjector:
    def __init__(
        self,
        swiss_epsg: int,
        min_range_m: float,
        max_range_m: float,
        earth_radius_m: float,
        dem_path: str = "",
        dem_expected_resolution_m: float = 5.0,
        dem_nodata_fallback: float | None = None,
        dem_enable_ground_sampling: bool = True,
    ):
        self._to_lv95 = Transformer.from_crs("EPSG:4326", f"EPSG:{swiss_epsg}", always_xy=True)
        self.min_range_m = min_range_m
        self.max_range_m = max_range_m
        self.earth_radius_m = earth_radius_m
        self.dem_sampler = DemSampler(
            dem_path=dem_path,
            target_epsg=swiss_epsg,
            expected_resolution_m=dem_expected_resolution_m,
            nodata_fallback=dem_nodata_fallback,
            enable_ground_sampling=dem_enable_ground_sampling,
        )

    @staticmethod
    def _center_xyxy(bbox: dict[str, float]) -> tuple[float, float]:
        return ((bbox["x0"] + bbox["x1"]) / 2.0, (bbox["y0"] + bbox["y1"]) / 2.0)

    @staticmethod
    def _clip(v: float, lo: float, hi: float) -> float:
        return max(lo, min(hi, v))

    def pixel_to_azimuth_deg(self, x_px: float, cam: CameraGeometry) -> float:
        if cam.raw_width <= 0:
            raise ValueError("raw_width must be > 0")
        return (cam.north_deg + (x_px / cam.raw_width) * cam.fov_deg) % 360.0

    def y_to_range_m(self, y_px: float, cam: CameraGeometry) -> float:
        if cam.raw_height <= 0:
            raise ValueError("raw_height must be > 0")
        frac = self._clip(y_px / cam.raw_height, 0.0, 1.0)
        return self.max_range_m - frac * (self.max_range_m - self.min_range_m)

    def offset_latlon(self, lat_deg: float, lon_deg: float, bearing_deg: float, distance_m: float) -> tuple[float, float]:
        brng = math.radians(bearing_deg)
        lat1 = math.radians(lat_deg)
        lon1 = math.radians(lon_deg)
        ang = distance_m / self.earth_radius_m

        lat2 = math.asin(
            math.sin(lat1) * math.cos(ang)
            + math.cos(lat1) * math.sin(ang) * math.cos(brng)
        )
        lon2 = lon1 + math.atan2(
            math.sin(brng) * math.sin(ang) * math.cos(lat1),
            math.cos(ang) - math.sin(lat1) * math.sin(lat2),
        )

        return (math.degrees(lat2), (math.degrees(lon2) + 540.0) % 360.0 - 180.0)

    def latlon_to_lv95(self, lat_deg: float, lon_deg: float) -> tuple[float, float]:
        east, north = self._to_lv95.transform(lon_deg, lat_deg)
        return float(east), float(north)

    def project_detection(
        self,
        detection: dict[str, Any],
        camera: CameraGeometry,
    ) -> dict[str, Any]:
        bbox = detection["bbox_xyxy"]
        center_x, center_y = self._center_xyxy(bbox)

        azimuth_deg = self.pixel_to_azimuth_deg(center_x, camera)
        range_m = self.y_to_range_m(center_y, camera)

        target_lat, target_lon = self.offset_latlon(
            lat_deg=camera.latitude,
            lon_deg=camera.longitude,
            bearing_deg=azimuth_deg,
            distance_m=range_m,
        )
        east_lv95, north_lv95 = self.latlon_to_lv95(target_lat, target_lon)

        box_width_px = max(1.0, bbox["x1"] - bbox["x0"])
        angular_width_deg = (box_width_px / camera.raw_width) * camera.fov_deg
        uncertainty_m = max(20.0, range_m * math.tan(math.radians(max(0.1, angular_width_deg / 2.0))))

        ground = self.dem_sampler.sample_lv95(east_lv95, north_lv95)
        if ground.get("available"):
            height_agl_m = camera.elevation_m - float(ground["ground_elevation_m"])
        else:
            height_agl_m = None

        return {
            "detection_id": detection.get("id"),
            "class_name": detection["class_name"],
            "confidence": detection["confidence"],
            "image_center_px": {"x": center_x, "y": center_y},
            "azimuth_deg": azimuth_deg,
            "range_m": range_m,
            "wgs84": {"latitude": target_lat, "longitude": target_lon},
            "lv95": {"easting": east_lv95, "northing": north_lv95},
            "ground": ground,
            "camera_height_above_ground_m": height_agl_m,
            "uncertainty_m": uncertainty_m,
            "camera_model": {
                "is_panorama": camera.is_panorama,
                "fov_deg": camera.fov_deg,
                "focal_length_mm": camera.focal_length_mm,
            },
            "bbox_xyxy": bbox,
}
