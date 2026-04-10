import os
import json
from pathlib import Path
from datetime import datetime, timezone
from typing import Any, Dict, List

JOBS_DIR = Path(os.getenv("JOBS_DIR", "/data/jobs"))


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def job_root(job_id: str) -> Path:
    return JOBS_DIR / job_id


def avalanche_dir(job_id: str) -> Path:
    return job_root(job_id) / "ava"


def job_meta_path(job_id: str) -> Path:
    return job_root(job_id) / "job.json"


def ensure_job_dirs(job_id: str) -> None:
    job_root(job_id).mkdir(parents=True, exist_ok=True)
    avalanche_dir(job_id).mkdir(parents=True, exist_ok=True)


def _jsonable(value: Any) -> Any:
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    return value


def write_json(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(_jsonable(data), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    tmp.replace(path)


def read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def init_job(job_id: str, request_payload: Dict[str, Any]) -> Dict[str, Any]:
    ensure_job_dirs(job_id)
    meta = {
        "job_id": job_id,
        "status": "queued",
        "created_at": now_iso(),
        "started_at": None,
        "finished_at": None,
        "error": None,
        "request": request_payload,
        "result": None,
        "outputs_dir": str(avalanche_dir(job_id) / "Outputs"),
        "paths": {
            "job_dir": str(job_root(job_id)),
            "avalanche_dir": str(avalanche_dir(job_id)),
        },
    }
    write_json(job_meta_path(job_id), meta)
    return meta


def update_job(job_id: str, **patch) -> Dict[str, Any]:
    path = job_meta_path(job_id)
    meta = read_json(path) if path.exists() else {"job_id": job_id}
    meta.update(patch)
    write_json(path, meta)
    return meta


def get_job(job_id: str) -> Dict[str, Any]:
    path = job_meta_path(job_id)
    if not path.exists():
        raise FileNotFoundError(job_id)
    return read_json(path)


def list_artifacts(job_id: str) -> List[str]:
    base = avalanche_dir(job_id)
    out_root = base / "Outputs"
    if not out_root.exists():
        return []
    files: List[str] = []
    for p in out_root.rglob("*"):
        if p.is_file():
            files.append(str(p.relative_to(base)))
    return sorted(files)


def resolve_artifact_path(job_id: str, relpath: str) -> Path:
    base = avalanche_dir(job_id).resolve()
    target = (base / relpath).resolve()
    if not str(target).startswith(str(base)):
        raise ValueError("invalid path")
    return target