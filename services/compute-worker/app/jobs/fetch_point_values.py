from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Union

import numpy as np

from avaframe.in3Utils import cfgUtils, logUtils
import avaframe.in3Utils.fileHandlerUtils as fU
import avaframe.in2Trans.transfromFields as tF
import avaframe.out3Plot.outTransformPlots as oT


Number = Union[int, float]


def _to_np_array(v: Union[Number, List[Number], np.ndarray]) -> np.ndarray:
    if isinstance(v, np.ndarray):
        return v.astype(float)
    if isinstance(v, (int, float)):
        return np.asarray([float(v)])
    return np.asarray([float(x) for x in v])


def run(
    avalanche_dir: str | Path,
    *,
    x: Union[Number, List[Number], np.ndarray],
    y: Union[Number, List[Number], np.ndarray],
    res_type: str = "pfv",
    module: str = "com1DFA",
    interp_method: str = "bilinear",
    plot: bool = False,
    plot_x_param: str = "relTh0",
    scenario: str = "simTypeActual",
    out_name: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Fetch point values from simulation result fields using interpolation.

    Parameters
    ----------
    avalanche_dir : str | Path
        AvaFrame avalanche directory.
    x, y : number | list[number] | np.ndarray
        Coordinates in the simulation CRS/units (same as result rasters).
        Can be single value or arrays (multiple points).
    res_type : str
        Result type to sample (e.g., 'pfv' in the original script).
    module : str
        Simulation module folder (default 'com1DFA').
    interp_method : str
        Interpolation method passed to AvaFrame (default 'bilinear').
    plot : bool
        If True, creates a plot using outTransformPlots.plotFetchedValues.
    plot_x_param : str
        Parameter name used for x-axis in the plot (default 'relTh0').
    scenario : str
        Scenario label used by the plotter.
    out_name : Optional[str]
        Output plot name. If None, uses f"pointValues_{res_type}".

    Returns
    -------
    dict
        JSON-friendly result with the sampled values per simulation.
    """
    avalanche_dir = Path(avalanche_dir)
    if not avalanche_dir.exists():
        raise FileNotFoundError(f"avalanche_dir not found: {avalanche_dir}")

    log = logUtils.initiateLogger(str(avalanche_dir), "FetchPointValues")
    log.info("JOB fetch_point_values start")
    log.info("avalanche_dir=%s res_type=%s module=%s", avalanche_dir, res_type, module)

    xy_point = {"x": _to_np_array(x), "y": _to_np_array(y)}
    if xy_point["x"].shape != xy_point["y"].shape:
        raise ValueError(f"x and y must have same shape, got {xy_point['x'].shape} vs {xy_point['y'].shape}")

    # Load config params for all simulations
    simDF = cfgUtils.createConfigurationInfo(str(avalanche_dir))

    # List simulations and their result files for given module
    inputsDF, _resTypeList = fU.makeSimFromResDF(str(avalanche_dir), module)

    # Merge: add config params as columns to dataDF
    dataDF = inputsDF.merge(simDF, left_on="simName", right_on="simName", how="left")

    # Fetch interpolated values at point(s)
    dataDF = tF.fetchPointValuesFromField(
        dataDF,
        xy_point,
        res_type,
        interpMethod=interp_method,
    )

    # Optional plot
    plot_path = None
    if plot:
        if out_name is None:
            out_name = f"pointValues_{res_type}"
        oT.plotFetchedValues(
            str(avalanche_dir),
            dataDF,
            f"pointValues_{res_type}",
            plot_x_param,
            out_name,
            scenario=scenario,
        )
        # AvaFrame plotters usually write into Outputs/plots or similar; we return the intended name
        plot_path = out_name

    # Return JSON-friendly payload
    # Note: dataframe can be big; keep it compact by selecting key columns if you want.
    records = dataDF.to_dict(orient="records")

    return {
        "avalancheDir": str(avalanche_dir),
        "module": module,
        "resType": res_type,
        "interpMethod": interp_method,
        "points": {
            "x": xy_point["x"].tolist(),
            "y": xy_point["y"].tolist(),
        },
        "plot": plot,
        "plotName": plot_path,
        "rows": records,
    }
