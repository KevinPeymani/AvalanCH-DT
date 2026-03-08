from .init_project import run as init_project
from .operational_simulation import run as operational_simulation
from .analysis import run as analysis

JOB_REGISTRY = {
    "init": init_project,
    "operational_simulation": operational_simulation,
    "simulation": operational_simulation,  # alias
    "analysis": analysis,
}
