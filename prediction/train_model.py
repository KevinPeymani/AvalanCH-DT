import pandas as pd
import numpy as np
import pickle
import json
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense, Dropout
from tensorflow.keras.utils import to_categorical

def train_avalanche_model(csv_path="data_rf2_tidy.csv"):
    df = pd.read_csv(csv_path)
    
    # Only keep the core features that are available from the live IMIS data and the parsed snowpack profile, which are the ones we can use for real-time prediction. This also prevents issues with missing features during prediction.
    core_features = [
        'TA',          # Air Temp
        'RH',          # Relative Humidity
        'VW',          # Wind Velocity
        'DW',          # Wind Direction
        'ISWR',        # Solar Radiation
        'HS_meas',     # Snow Height
        'TSG',         # Ground Temp
        'sk38_pwl',    # Skier Stability
        'sn38_pwl',    # Natural Stability
        'Sd',          # Deformation Stability
        'ccl_pwl',     # Critical Cut Length
        'HN24',         # New Snow 24h
        'HN72_24',      # New Snow 72h-24h
        'HN24_7d',      # New Snow 24h-7d
    ]
    
    top_features = [
    'HN24', 'HN72_24', 'HN24_7d',          # New snow sums (The "Memory")
    'Pen_depth', 'min_ccl_pen',             # Physical penetration depth
    'wind_trans24', 'wind_trans24_3d',      # Wind drifted snow
    'TA', 'RH', 'VW', 'DW', 'ISWR',         # Standard weather
    'pAlbedo', 'Qw',                        # Energy balance
    'MS_Snow', 'SWE',                       # Mass and Water Equivalent
    'TS1', 'TS2',                           # Internal snow temperatures
    'S4', 'Sn', 'ccl_pwl', 'sk38_pwl',      # Advanced stability indices
    'LWR_net', 'ILWR'                       # Radiation
]
    
    # Check if they exist in the CSV, keep only those
    features_to_keep = [f for f in top_features if f in df.columns]
    
    X = df[features_to_keep]
    y = df['dangerLevel']
    
    # Save this specific list
    with open('feature_columns.json', 'w') as f:
        json.dump(features_to_keep, f)
        
    X = X.fillna(X.median())
    y_encoded = to_categorical(y - 1, num_classes=5)
    
    X_train, X_test, y_train, y_test = train_test_split(X, y_encoded, test_size=0.2, random_state=42)
    
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)
    
    with open('imis_scaler.pkl', 'wb') as f:
        pickle.dump(scaler, f)
        
    # Build a slightly smaller network since we have fewer features
    model = Sequential([
        Dense(64, activation='relu', input_shape=(len(features_to_keep),)),
        Dropout(0.2),
        Dense(32, activation='relu'),
        Dropout(0.1),
        Dense(5, activation='softmax')
    ])
    
    model.compile(optimizer='adam', loss='categorical_crossentropy', metrics=['accuracy'])
    model.fit(X_train_scaled, y_train, validation_data=(X_test_scaled, y_test), epochs=30, batch_size=64)
    model.save('avalanche_model.h5')
    print(f"Trained on {len(features_to_keep)} core features!")

if __name__ == "__main__":
    train_avalanche_model()