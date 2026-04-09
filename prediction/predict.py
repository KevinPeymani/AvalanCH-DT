import numpy as np
import pandas as pd
import pickle
import json
import requests
from tensorflow.keras.models import load_model

from run_pipeline import setup_snowpack_files, run_snowpack
from parse_profile import extract_all_features

URL_MEASUREMENT = "https://measurement-api.slf.ch/public/api/imis/station/{station_code}/measurements"


def fetch_station_measurements_hourly(station_code="DAV3", period_in_days=7):
    response = requests.get(
        URL_MEASUREMENT.format(station_code=station_code),
        params={"period_in_days": period_in_days},
        timeout=30,
    )
    response.raise_for_status()

    data = response.json()
    if not data:
        raise ValueError(f"No IMIS data returned for station {station_code}")

    df = pd.DataFrame(data)
    if "measure_date" not in df.columns:
        raise ValueError("IMIS response does not contain 'measure_date'")

    df["measure_date"] = pd.to_datetime(df["measure_date"], utc=True, errors="coerce")
    df = df.dropna(subset=["measure_date"]).sort_values("measure_date")
    df = df.set_index("measure_date")

    for col in df.columns:
        if col != "station_code":
            df[col] = pd.to_numeric(df[col], errors="coerce")

    numeric_cols = [c for c in df.columns if c != "station_code"]
    hourly = df[numeric_cols].resample("1h").mean().ffill()

    if hourly.empty:
        raise ValueError(f"Hourly aggregation returned no data for station {station_code}")

    return hourly


def build_live_features_from_hourly(hourly_df):
    latest = hourly_df.iloc[-1]

    hs_series = hourly_df["HS"].ffill() if "HS" in hourly_df.columns else pd.Series(dtype=float)
    hs_diff = hs_series.diff().clip(lower=0) if not hs_series.empty else pd.Series(dtype=float)

    hn24 = hs_diff.tail(24).sum() if len(hs_diff) >= 1 else 0.0
    hn72 = hs_diff.tail(72).sum() if len(hs_diff) >= 1 else 0.0
    hn168 = hs_diff.tail(168).sum() if len(hs_diff) >= 1 else 0.0

    live_imis = {
        "TA": float(latest.get("TA_30MIN_MEAN", -1.0)),
        "RH": float(latest.get("RH_30MIN_MEAN", 85.0)),
        "VW": float(latest.get("VW_30MIN_MEAN", 8.0)),
        "DW": float(latest.get("DW_30MIN_MEAN", 270.0)),
        "ISWR": float(latest.get("RSWR_30MIN_MEAN", 450.0)),
        "HS_meas": float(latest.get("HS", 250.0)),
        "TSG": float(latest.get("TS0_30MIN_MEAN", -0.5)),
        "HN24": float(hn24),
        "HN72_24": float(max(hn72 - hn24, 0.0)),
        "HN24_7d": float(hn168),
        "ILWR": float(latest.get("RSWR_30MIN_MEAN", 0.0)),
    }

    return live_imis


def build_snowpack_forcing_from_hourly(hourly_df):
    forcing = pd.DataFrame(index=hourly_df.index)
    forcing["TA"] = hourly_df.get("TA_30MIN_MEAN", pd.Series(-1.0, index=hourly_df.index))
    forcing["RH"] = hourly_df.get("RH_30MIN_MEAN", pd.Series(85.0, index=hourly_df.index))
    forcing["VW"] = hourly_df.get("VW_30MIN_MEAN", pd.Series(8.0, index=hourly_df.index))
    forcing["DW"] = hourly_df.get("DW_30MIN_MEAN", pd.Series(270.0, index=hourly_df.index))
    forcing["ISWR"] = hourly_df.get("RSWR_30MIN_MEAN", pd.Series(150.0, index=hourly_df.index))
    forcing["HS_meas"] = hourly_df.get("HS", pd.Series(250.0, index=hourly_df.index))
    forcing["TSG"] = hourly_df.get("TS0_30MIN_MEAN", pd.Series(-0.5, index=hourly_df.index))
    forcing["ILWR"] = hourly_df.get("RSWR_30MIN_MEAN", pd.Series(0.0, index=hourly_df.index))
    return forcing.ffill().bfill()

def predict_danger(station_code="DAV3"):
    # 1. LIVE DATA FROM IMIS (last 7 days, hourly)
    hourly_forcing = None
    try:
        hourly_imis = fetch_station_measurements_hourly(station_code=station_code, period_in_days=7)
        live_imis = build_live_features_from_hourly(hourly_imis)
        hourly_forcing = build_snowpack_forcing_from_hourly(hourly_imis)
        print(f"Fetched IMIS measurements for station {station_code}: {len(hourly_imis)} hourly rows")
    except Exception as exc:
        print(f"⚠️ Could not fetch IMIS data ({exc}). Falling back to default values.")
        live_imis = {
            "TA": -1.0,
            "RH": 85.0,
            "VW": 8.0,
            "DW": 270.0,
            "ISWR": 450.0,
            "HS_meas": 250.0,
            "TSG": -0.5,
            "HN24": 0.0,
            "HN72_24": 0.0,
            "HN24_7d": 0.0,
            "ILWR": 0.0,
        }

    # 2. RUN MODEL
    end_time = setup_snowpack_files(live_imis, hourly_weather_df=hourly_forcing, station_code=station_code)
    run_snowpack(end_time)

    # 3. PARSE
    parsed_pro = extract_all_features(f"output/{station_code}_IMIS_LIVE.pro", f"output/{station_code}_IMIS_LIVE.smet")
    
    # Merge dictionaries
    combined_data = {**live_imis, **parsed_pro}

    print("\n--- DIAGNOSTIC: WHAT THE MODEL IS SEEING ---")
    for key, val in combined_data.items():
        print(f"{key}: {val}")
    print("--------------------------------------------\n")

    # 4. LOAD & PREDICT
    model = load_model('avalanche_model.h5')
    with open('imis_scaler.pkl', 'rb') as f:
        scaler = pickle.load(f)
    with open('feature_columns.json', 'r') as f:
        feature_cols = json.load(f)

    # Assemble using pandas to prevent the sklearn warning
    live_df = pd.DataFrame([combined_data], columns=feature_cols)
    live_scaled = scaler.transform(live_df)
    
    prediction_probs = model.predict(live_scaled)[0]
    predicted_level = np.argmax(prediction_probs) + 1
    
    print("="*50)
    print(f"🏔️  REAL-TIME PREDICTION  🏔️")
    print(f"Predicted Danger Level: {predicted_level} / 5")
    print(f"Confidence: {np.max(prediction_probs)*100:.1f}%")
    print("="*50)

if __name__ == "__main__":
    predict_danger("ZER2")