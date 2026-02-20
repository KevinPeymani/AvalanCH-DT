import os
import datetime
import subprocess

def setup_snowpack_files(live_weather_data):
    os.makedirs("input", exist_ok=True)
    os.makedirs("cfgfiles", exist_ok=True)
    os.makedirs("output", exist_ok=True)
    
    now = datetime.datetime.now(datetime.timezone.utc)
    # Start the simulation 3 days ago
    start_time = (now - datetime.timedelta(days=3)).strftime('%Y-%m-%dT%H:%M:%S')
    end_time = now.strftime('%Y-%m-%dT%H:%M:%S')
    
    # 1. INITIAL STATE (.sno)
    sno_content = f"""SMET 1.1 ASCII
[HEADER]
station_id       = DAV3
latitude         = 46.8
longitude        = 9.8
altitude         = 2500
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
    with open("input/DAV3.sno", 'w') as f: f.write(sno_content)
    
    # 2. WEATHER DATA (.smet) - Forcing 3 days of constant weather 
    ta_k = live_weather_data.get('TA', -4.5) + 273.15 
    rh_frac = live_weather_data.get('RH', 85) / 100.0   
    vw_ms = live_weather_data.get('VW', 5.0)       
    dw_deg = live_weather_data.get('DW', 270)       
    iswr = live_weather_data.get('ISWR', 150)  
    hs_m = live_weather_data.get('HS_meas', 120) / 100.0 
    tsg_k = live_weather_data.get('TSG', -0.5) + 273.15
    psum = 0.00

    smet_content = f"""SMET 1.1 ASCII
[HEADER]
station_id       = DAV3
latitude         = 46.8
longitude        = 9.8
altitude         = 2500
nodata           = -999
tz               = 1
fields           = timestamp TA RH VW DW ISWR HS TSG PSUM
[DATA]
{start_time} {ta_k:.2f} {rh_frac:.2f} {vw_ms:.2f} {dw_deg:.1f} {iswr:.1f} {hs_m:.2f} {tsg_k:.2f} {psum:.2f}
{end_time} {ta_k:.2f} {rh_frac:.2f} {vw_ms:.2f} {dw_deg:.1f} {iswr:.1f} {hs_m:.2f} {tsg_k:.2f} {psum:.2f}
"""
    with open("input/DAV3.smet", 'w') as f: f.write(smet_content)

    # 3. CONFIGURATION (io.ini)
    ini_content = """[General]
BUFF_CHUNK_SIZE = 370
BUFF_BEFORE = 1.5
[Input]
COORDSYS = CH1903
TIME_ZONE = 1
METEOPATH = ./input
METEO = SMET
STATION1 = DAV3.smet
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
    print(f"Running 3-Day SNOWPACK simulation up to {end_time}...")
    subprocess.run(["snowpack", "-c", "cfgfiles/io.ini", "-e", end_time], capture_output=True, text=True, check=True)
    print("SNOWPACK simulation completed!")