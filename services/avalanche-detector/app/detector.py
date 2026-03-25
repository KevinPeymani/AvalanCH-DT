import torch


class AvalancheDetector:
    def __init__(self, settings):
        self.settings = settings

        self.model = torch.hub.load(
            settings.model.repo_path,
            "custom",
            path=settings.model.weights_path,
            source="local",
            device=settings.model.device,
        )

    def predict(self, img_path):
        return self.model(img_path, size=self.settings.inference.imgsz)

    def extract_detections(self, result, x0, y0):
        detections = []

        for *box, conf, cls in result.xyxy[0].tolist():
            x1, y1, x2, y2 = box

            detections.append({
                "class_id": int(cls),
                "class_name": self.model.names[int(cls)],
                "confidence": float(conf),
                "bbox_tile_xyxy": [x1, y1, x2, y2],
                "bbox_global_xyxy": [
                    x1 + x0,
                    y1 + y0,
                    x2 + x0,
                    y2 + y0
                ]
            })

        return detections

    def apply_postprocess(self, detections, tile_w, tile_h):
        cfg = self.settings.postprocess
        out = []

        for d in detections:
            cls = d["class_name"]
            conf = d["confidence"]

            if conf < cfg.class_thresholds.get(cls, 0):
                continue

            sf = cfg.size_filters.get(cls)
            if sf:
                x0, y0, x1, y1 = d["bbox_tile_xyxy"]
                w = x1 - x0
                h = y1 - y0

                if sf.max_width_ratio and w > sf.max_width_ratio * tile_w:
                    continue
                if sf.max_height_ratio and h > sf.max_height_ratio * tile_h:
                    continue

            out.append(d)

        return out
