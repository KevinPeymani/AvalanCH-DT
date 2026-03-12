from enum import Enum
from typing import Optional, Dict, Any
from pydantic import BaseModel, Field, HttpUrl


# -----------------------
# Enums métier
# -----------------------

class AvalancheType(str, Enum):
    dry = "dry"
    wet = "wet"
    powder = "powder"
    custom = "custom"


class SimulationQuality(str, Enum):
    fast = "fast"
    default = "default"
    high = "high"


# -----------------------
# Inputs
# -----------------------

class AvalancheInputs(BaseModel):
    """
    Physical inputs required to run the simulation.
    """
    dem_uri: str  # local path, s3, http, etc.
    rel_uri: str  # release area file


# -----------------------
# Simulation profile
# -----------------------

class AvalancheSimulationConfig(BaseModel):
    """
    High-level simulation parameters exposed by the API.
    These map internally to AvaFrame INI overrides.
    """

    avalanche_type: AvalancheType

    quality: SimulationQuality = SimulationQuality.default

    # Physical properties
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

    # Release behaviour
    release_thickness_m: Optional[float] = Field(
        None,
        gt=0,
        description="Uniform release thickness if not provided by REL file"
    )

    # Auto init always true by design but still configurable if needed
    auto_init: bool = True

    # Advanced generic parameters (mapped later)
    extra_params: Dict[str, Any] = Field(default_factory=dict)


# -----------------------
# INI Overrides
# -----------------------

class IniOverrides(BaseModel):
    """
    Direct INI overrides.
    Structure:
    {
        "GENERAL": {"rho": 230},
        "PHYSICS": {"mu": 0.25}
    }
    """
    sections: Dict[str, Dict[str, Any]] = Field(default_factory=dict)


class AvalancheConfigOverrides(BaseModel):
    """
    Allows overriding specific AvaFrame configuration files.
    Example:
    {
        "com1DFA": {
            "GENERAL": {"rho": 230}
        }
    }
    """
    modules: Dict[str, Dict[str, Dict[str, Any]]] = Field(default_factory=dict)


# -----------------------
# Final request model
# -----------------------

class AvalancheJobRequest(BaseModel):
    """
    Request model for avalanche simulation.
    """

    inputs: AvalancheInputs

    simulation: AvalancheSimulationConfig

    config_overrides: Optional[AvalancheConfigOverrides] = None

    metadata: Dict[str, Any] = Field(default_factory=dict)
