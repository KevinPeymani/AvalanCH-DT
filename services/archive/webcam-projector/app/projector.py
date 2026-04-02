from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

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


class SwissProjector:
    def __init__(self, swiss_epsg: int, min_range_m: float, max_range_m: float, earth_radius_m: float):
        self._to_lv95 = Transformer.from_crs("EPSG:4326", f"EPSG:{swiss_epsg}", always_xy=True)
        self.min_range_m = min_range_m
        self.max_range_m = max_range_m
        self.earth_radius_m = earth_radius_m

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

        return {
            "detection_id": detection.get("id"),
            "class_name": detection["class_name"],
            "confidence": detection["confidence"],
            "image_center_px": {"x": center_x, "y": center_y},
            "azimuth_deg": azimuth_deg,
            "range_m": range_m,
            "wgs84": {"latitude": target_lat, "longitude": target_lon},
            "lv95": {"easting": east_lv95, "northing": north_lv95},
            "uncertainty_m": uncertainty_m,
            "bbox_xyxy": bbox,
        }
