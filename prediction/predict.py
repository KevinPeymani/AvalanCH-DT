import numpy as np
import pandas as pd
import pickle
import json
from tensorflow.keras.models import load_model

from run_pipeline import setup_snowpack_files, run_snowpack
from parse_profile import extract_stability_indices

def predict_danger():
    # 1. LIVE DATA (Try changing TA to 5.0 and VW to 30.0 to see the prediction change!)
    live_imis = {
        'TA': 5.0,
        'RH': 85.0,
        'VW': 30.0,
        'DW': 270.0,
        'ISWR': 450.0,
        'HS_meas': 120.0,
        'TSG': -0.5,
    }

    # 2. RUN MODEL
    end_time = setup_snowpack_files(live_imis)
    run_snowpack(end_time)

    # 3. PARSE
    parsed_pro = extract_stability_indices("output/DAV3_IMIS_LIVE.pro")
    
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
    predict_danger()