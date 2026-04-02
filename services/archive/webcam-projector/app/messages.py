from __future__ import annotations

from typing import Any


def get_nested(data: dict[str, Any], *keys: str, default: Any = None) -> Any:
    current = data
    for key in keys:
        if not isinstance(current, dict):
            return default
        current = current.get(key)
        if current is None:
            return default
    return current


def coalesce(*values):
    for value in values:
        if value is not None:
            return value
    return None


def normalize_detection(item: dict[str, Any], fallback_class: str) -> dict[str, Any]:
    bbox = (
        item.get("bbox")
        or item.get("xyxy")
        or item.get("box")
        or item.get("bbox_xyxy")
        or {}
    )

    if isinstance(bbox, list) and len(bbox) == 4:
        x0, y0, x1, y1 = bbox
    elif isinstance(bbox, dict):
        x0 = coalesce(bbox.get("x0"), bbox.get("xmin"), bbox.get("x_min"), bbox.get("left"))
        y0 = coalesce(bbox.get("y0"), bbox.get("ymin"), bbox.get("y_min"), bbox.get("top"))
        x1 = coalesce(bbox.get("x1"), bbox.get("xmax"), bbox.get("x_max"), bbox.get("right"))
        y1 = coalesce(bbox.get("y1"), bbox.get("ymax"), bbox.get("y_max"), bbox.get("bottom"))
    else:
        raise ValueError(f"Unsupported bbox format: {bbox!r}")

    if None in (x0, y0, x1, y1):
        raise ValueError(f"Incomplete bbox: {bbox!r}")

    label = (
        item.get("class_name")
        or item.get("label")
        or item.get("class")
        or fallback_class
    )
    confidence = item.get("confidence")
    if confidence is None:
        confidence = item.get("score")
    if confidence is None:
        confidence = item.get("conf")
    if confidence is None:
        confidence = 1.0

    return {
        "id": item.get("id"),
        "class_name": label,
        "confidence": float(confidence),
        "bbox_xyxy": {
            "x0": float(x0),
            "y0": float(y0),
            "x1": float(x1),
            "y1": float(y1),
        },
        "raw": item,
    }


def extract_detections(message: dict[str, Any], fallback_class: str) -> list[dict[str, Any]]:
    candidates = (
        message.get("detections")
        or get_nested(message, "result", "detections")
        or get_nested(message, "prediction", "detections")
        or []
    )

    normalized = []
    for item in candidates:
        if not isinstance(item, dict):
            continue
        normalized.append(normalize_detection(item, fallback_class=fallback_class))
    return normalized
