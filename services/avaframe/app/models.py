from pydantic import BaseModel, Field
from typing import Optional, Dict, Any, Literal


AvalancheType = Literal["dry", "wet"]
QualityType = Literal["fast", "default", "high"]


class AvalancheJobRequest(BaseModel):
    """
    Request model for creating an avalanche simulation job.
    """

    dem_uri: str
    rel_uri: str
    avalanche_type: AvalancheType
    quality: Optional[QualityType] = "default"
    params: Dict[str, Any] = Field(default_factory=dict)


class AvalancheJob(BaseModel):
    """
    Model representing an avalanche job.
    """

    job_id: str
    status: str
    created_at: str
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    error: Optional[str] = None
    outputs_dir: str
