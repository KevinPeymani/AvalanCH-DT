import os
import datetime
import subprocess
import json
import pandas as pd


DEFAULT_STATION_META = {
    "station_abbr": "DAV3",
    "station_name": "DAV3",
    "alt": 2500.0,
    "lat": 46.8,
    "lon": 9.8,
}


def _find_station_catalog_path():
    base_dir = os.path.dirname(__file__)
    candidates = [
        os.path.join(base_dir, "..", "data", "stations.json"),
        os.path.join(base_dir, "..", "data", "automatic_weather_stations", "stations.json"),
        os.path.join(base_dir, "..", "app", "public", "stations.json"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    print("⚠️ Warning: Could not find station catalog in expected locations.")
    return None


def get_station_metadata(station_code):
    station_code = station_code.upper().rstrip('0123456789') # remove the number part if present, e.g. DAV3 -> DAV
    metadata = DEFAULT_STATION_META.copy()
    metadata["station_abbr"] = station_code
    metadata["station_name"] = station_code

    catalog_path = _find_station_catalog_path()
    if not catalog_path:
        return metadata

    with open(catalog_path, "r") as f:
        stations = json.load(f)

    match = next(
        (
            station for station in stations
            if str(station.get("station_abbr", "")).upper() == str(station_code).upper()
        ),
        None,
    )

    if not match:
        return metadata

    metadata.update(match)
    metadata["station_name"] = match.get("station_name") or station_code
    metadata["lat"] = match.get("lat") if match.get("lat") is not None else DEFAULT_STATION_META["lat"]
    metadata["lon"] = match.get("lon") if match.get("lon") is not None else DEFAULT_STATION_META["lon"]
    metadata["alt"] = match.get("alt") if match.get("alt") is not None else DEFAULT_STATION_META["alt"]
    return metadata

def setup_snowpack_files(live_weather_data, hourly_weather_df=None, station_code="DAV3"):
    os.makedirs("input", exist_ok=True)
    os.makedirs("cfgfiles", exist_ok=True)
    os.makedirs("output", exist_ok=True)
    station_meta = get_station_metadata(station_code)

    if hourly_weather_df is not None and not hourly_weather_df.empty:
        forcing_df = hourly_weather_df.copy().sort_index()
        if forcing_df.index.tz is not None:
            forcing_df.index = forcing_df.index.tz_convert(None)

        start_time = forcing_df.index[0].strftime('%Y-%m-%dT%H:%M:%S')
        end_time = forcing_df.index[-1].strftime('%Y-%m-%dT%H:%M:%S')
    else:
        now = datetime.datetime.now(datetime.timezone.utc)
        start_time = (now - datetime.timedelta(days=3)).strftime('%Y-%m-%dT%H:%M:%S')
        end_time = now.strftime('%Y-%m-%dT%H:%M:%S')
    
    # 1. INITIAL STATE (.sno)
    sno_content = f"""SMET 1.1 ASCII
[HEADER]
station_id       = {station_code}
station_name     = {station_meta.get('station_name', station_code)}
station_abbr     = {station_meta.get('station_abbr', station_code)}
latitude         = {float(station_meta.get('lat', 46.8))}
longitude        = {float(station_meta.get('lon', 9.8))}
altitude         = {float(station_meta.get('alt', 2500.0))}
nodata           = -999
tz               = 1
ProfileDate      = {start_time}
HS_Last          = 0.0000
SlopeAngle       = 38.0
SlopeAzi         = 0.0
nSoilLayerData   = 0
nSnowLayerData   = 0
SoilAlbedo       = 0.09
BareSoil_z0      = 0.02
CanopyHeight     = 0.00
CanopyLeafAreaIndex = 0.00
CanopyDirectThroughfall = 1.0
WindScalingFactor = 1.0
ErosionLevel     = 0
TimeCountDeltaHS = 0.000000
fields           = timestamp Layer_Thick  T  Vol_Frac_I  Vol_Frac_W  Vol_Frac_V  Vol_Frac_S Rho_S Concen_m  Sp  rg  rb  dd  sp  mk  mass_hoar  ne  CDot  metamo
[DATA]
"""
    with open(f"input/{station_code}.sno", 'w') as f: f.write(sno_content)
    
    # 2. WEATHER DATA (.smet)
    if hourly_weather_df is not None and not hourly_weather_df.empty:
        hourly_required = ["TA", "RH", "VW", "DW", "ISWR", "HS_meas", "TSG"]
        for column in hourly_required:
            if column not in forcing_df.columns:
                forcing_df[column] = live_weather_data.get(column, 0.0)

        forcing_df = forcing_df[hourly_required].ffill().bfill().fillna(0.0)
        smet_rows = []
        for timestamp, row in forcing_df.iterrows():
            ta_k = float(row["TA"]) + 273.15
            rh_frac = float(row["RH"]) / 100.0
            vw_ms = float(row["VW"])
            dw_deg = float(row["DW"])
            iswr = float(row["ISWR"])
            hs_m = float(row["HS_meas"]) / 100.0
            tsg_k = float(row["TSG"]) + 273.15
            smet_rows.append(
                f"{timestamp.strftime('%Y-%m-%dT%H:%M:%S')} {ta_k:.2f} {rh_frac:.2f} {vw_ms:.2f} {dw_deg:.1f} {iswr:.1f} {hs_m:.2f} {tsg_k:.2f} 0.00"
            )
    else:
        ta_k = live_weather_data.get('TA', -4.5) + 273.15
        rh_frac = live_weather_data.get('RH', 85) / 100.0
        vw_ms = live_weather_data.get('VW', 5.0)
        dw_deg = live_weather_data.get('DW', 270)
        iswr = live_weather_data.get('ISWR', 150)
        hs_m = live_weather_data.get('HS_meas', 120) / 100.0
        tsg_k = live_weather_data.get('TSG', -0.5) + 273.15
        smet_rows = [
            f"{start_time} {ta_k:.2f} {rh_frac:.2f} {vw_ms:.2f} {dw_deg:.1f} {iswr:.1f} {hs_m:.2f} {tsg_k:.2f} 0.00",
            f"{end_time} {ta_k:.2f} {rh_frac:.2f} {vw_ms:.2f} {dw_deg:.1f} {iswr:.1f} {hs_m:.2f} {tsg_k:.2f} 0.00",
        ]

    smet_content = f"""SMET 1.1 ASCII
[HEADER]
station_id       = {station_code}
station_name     = {station_meta.get('station_name', station_code)}
station_abbr     = {station_meta.get('station_abbr', station_code)}
latitude         = {float(station_meta.get('lat', 46.8))}
longitude        = {float(station_meta.get('lon', 9.8))}
altitude         = {float(station_meta.get('alt', 2500.0))}
nodata           = -999
tz               = 1
fields           = timestamp TA RH VW DW ISWR HS TSG PSUM
[DATA]
{chr(10).join(smet_rows)}
"""
    with open(f"input/{station_code}.smet", 'w') as f: f.write(smet_content)

    # 3. CONFIGURATION (io.ini)
    ini_content = f"""[General]
BUFF_CHUNK_SIZE = 370
BUFF_BEFORE = 1.5
[Input]
COORDSYS = CH1903
TIME_ZONE = 1
METEOPATH = ./input
METEO = SMET
STATION1 = {station_code}.smet
SNOWPATH = ./input
[Output]
COORDSYS = CH1903
TIME_ZONE = 1
EXPERIMENT = IMIS_LIVE
METEOPATH = ./output
OUT_STAB = TRUE
OUT_PRO = TRUE
PROF_WRITE = TRUE
PROF_FORMAT = PRO
TS_WRITE = TRUE
TS_FORMAT = SMET
OUT_METEO = FALSE
BACKUP_DAYS_BETWEEN = 365.0
FIRST_BACKUP = 400.0
TS_DAYS_BETWEEN = 0.04166667
PROF_DAYS_BETWEEN = 0.04166667
[Snowpack]
CALCULATION_STEP_LENGTH = 60.0
ROUGHNESS_LENGTH = 0.002
HEIGHT_OF_METEO_VALUES = 4.5
HEIGHT_OF_WIND_VALUE = 4.5
ENFORCE_MEASURED_SNOW_HEIGHTS = TRUE
SW_MODE = INCOMING
ATMOSPHERIC_STABILITY = MO_MICHLMAYR
CANOPY = FALSE
SNP_SOIL = FALSE
MEAS_TSS = FALSE
MEAS_EXACT_PTS = FALSE
ALBEDO = PARAMETERIZED
CHANGE_BC = FALSE
MEAS_INCOMING_LONGWAVE = FALSE
WATER_LAYER = FALSE
[SnowpackAdvanced]
ASSUME_RESPONSIBILITY = AGREE
VARIANT = DEFAULT
"""
    with open("cfgfiles/io.ini", 'w') as f: f.write(ini_content)
    return end_time

def run_snowpack(end_time):
    print(f"Running SNOWPACK simulation up to {end_time}...")
    result = subprocess.run(
        ["snowpack", "-c", "cfgfiles/io.ini", "-e", end_time],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"SNOWPACK failed (exit {result.returncode})\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )
    print("SNOWPACK simulation completed!")