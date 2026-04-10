from enum import Enum
from typing import Optional, Dict, Any
from pydantic import BaseModel, Field, model_validator


class AvalancheType(str, Enum):
    dry = "dry"
    wet = "wet"
    powder = "powder"
    custom = "custom"


class SimulationQuality(str, Enum):
    fast = "fast"
    default = "default"
    high = "high"


class AvalancheInputs(BaseModel):
    dem_uri: str
    rel_uri: str


class CoordInput(BaseModel):
    dem_uri: str
    x: float
    y: float
    crs: str = "EPSG:2056"
    crop_radius_m: float = Field(1000.0, gt=0)
    target_resolution_m: float = Field(5.0, gt=0)
    release_radius_m: float = Field(25.0, gt=0)
    release_thickness_m: float = Field(0.8, gt=0)

    @model_validator(mode="after")
    def validate_geometry(self):
        if self.crs.upper() != "EPSG:2056":
            raise ValueError("coord.crs must be EPSG:2056")
        if self.release_radius_m >= self.crop_radius_m:
            raise ValueError("release_radius_m must be smaller than crop_radius_m")
        return self

class AvalancheSimulationConfig(BaseModel):
    avalanche_type: AvalancheType
    quality: SimulationQuality = SimulationQuality.default

    snow_density_kg_m3: float = Field(
        250.0,
        gt=0,
        description="Initial snow density (rho)"
    )

    snow_density_entrained_kg_m3: Optional[float] = Field(
        None,
        gt=0,
        description="Entrained snow density (rhoEnt)"
    )

    release_thickness_m: Optional[float] = Field(
        None,
        gt=0,
        description="Uniform release thickness if not provided by REL file"
    )

    auto_init: bool = True
    extra_params: Dict[str, Any] = Field(default_factory=dict)


class IniOverrides(BaseModel):
    sections: Dict[str, Dict[str, Any]] = Field(default_factory=dict)


class AvalancheConfigOverrides(BaseModel):
    modules: Dict[str, Dict[str, Dict[str, Any]]] = Field(default_factory=dict)


class AvalancheJobRequest(BaseModel):
    inputs: Optional[AvalancheInputs] = None
    coord: Optional[CoordInput] = None
    simulation: AvalancheSimulationConfig
    config_overrides: Optional[AvalancheConfigOverrides] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_entry_mode(self):
        if self.inputs is None and self.coord is None:
            raise ValueError("One of 'inputs' or 'coord' is required")
        if self.inputs is not None and self.coord is not None:
            raise ValueError("Use either 'inputs' or 'coord', not both")
        return self