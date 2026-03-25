from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field


class SourceRef(BaseModel):
    source_type: str
    source_id: str
    source_name: Optional[str] = None


class CaptureInfo(BaseModel):
    captured_at: str
    captured_at_utc: Optional[str] = None
    date: Optional[str] = None
    time: Optional[str] = None


class ImageInfo(BaseModel):
    image_id: str
    raw_path: str
    raw_image_width: int
    raw_image_height: int
    cloud_url: Optional[str] = None


class TileInfo(BaseModel):
    index: int
    count: Optional[int] = None
    path: str
    x0: int
    y0: int
    x1: int
    y1: int
    width: int
    height: int
    overlap_px: Optional[int] = None


class GeometryInfo(BaseModel):
    angle_center: Optional[float] = None
    angle_start: Optional[float] = None
    angle_end: Optional[float] = None
    reference_north_deg: Optional[float] = None
    fov_deg: Optional[float] = None


class DetectionItem(BaseModel):
    class_id: int
    class_name: str
    confidence: float
    bbox_tile_xyxy: List[float]
    bbox_global_xyxy: List[float]
    extra: Dict[str, Any] = Field(default_factory=dict)


class DownloadTileMessage(BaseModel):
    job_id: str
    message_type: str

    source: SourceRef
    capture: CaptureInfo
    image: ImageInfo
    tile: TileInfo
    geometry: Optional[GeometryInfo] = None

    metadata: Dict[str, Any] = Field(default_factory=dict)


class DetectionResultMessage(BaseModel):
    job_id: str
    message_type: str = "tile_detection_result"

    source: SourceRef
    capture: CaptureInfo
    image: ImageInfo
    tile: TileInfo
    geometry: Optional[GeometryInfo] = None

    detections: List[DetectionItem]
    has_detection: bool

    metadata: Dict[str, Any] = Field(default_factory=dict)
