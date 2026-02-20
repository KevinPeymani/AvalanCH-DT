import os

def extract_all_features(pro_filepath="output/DAV3_IMIS_LIVE.pro", smet_filepath="output/DAV3_IMIS_LIVE.smet"):
    features = {}

    # ==========================================
    # 1. PARSE THE .PRO FILE (Stability & Temps)
    # ==========================================
    if not os.path.exists(pro_filepath):
        print(f"⚠️ Warning: Could not find {pro_filepath}")
    else:
        search_map = {
            'sk38': 'sk38',
            'sn38': 'sn38',
            'ccl': 'critical cut length',
            'ts_elements': 'element temperature'
        }
        codes = {key: None for key in search_map.keys()}
        data = {key: [] for key in search_map.keys()}

        with open(pro_filepath, 'r') as file:
            for line in file:
                parts = line.strip().split(',')
                if not parts: continue
                lower_line = line.lower()
                
                if parts[0].isdigit() and len(parts) > 1 and not parts[1].replace('.','').isdigit():
                    for key, search_term in search_map.items():
                        if search_term in lower_line and not codes[key]:
                            codes[key] = parts[0]

                if len(parts) > 2 and parts[0].isdigit():
                    for key, code in codes.items():
                        if parts[0] == code:
                            for v in parts[2:]:
                                try:
                                    val = float(v.strip())
                                    if val != -999: data[key].append(val)
                                except ValueError: pass

        features['sk38_pwl'] = min([v for v in data['sk38'] if v > 0]) if [v for v in data['sk38'] if v > 0] else 6.0
        features['sn38_pwl'] = min([v for v in data['sn38'] if v > 0]) if [v for v in data['sn38'] if v > 0] else 6.0
        features['ccl_pwl']  = min([v for v in data['ccl'] if v > 0]) if [v for v in data['ccl'] if v > 0] else 3.0
        
        temps = data['ts_elements']
        features['TS1'] = temps[-1] if temps else -5.0           
        features['TS2'] = temps[len(temps)//2] if temps else -2.0  

    # ==========================================
    # 2. PARSE THE .SMET FILE (Mass, Energy, Penetration)
    # ==========================================
    if os.path.exists(smet_filepath):
        with open(smet_filepath, 'r') as file:
            lines = file.readlines()
            
        fields = []
        data_lines = []
        in_data = False
        
        for line in lines:
            line = line.strip()
            if line.startswith("fields"):
                fields = line.split('=')[1].strip().split()
            elif line == "[DATA]":
                in_data = True
            elif in_data and line:
                data_lines.append(line)
                
        if fields and data_lines:
            last_row = data_lines[-1].split()
            smet_data = dict(zip(fields, last_row))
            
            def get_val(key, default=0.0):
                for k, v in smet_data.items():
                    if k.lower() == key.lower():
                        try:
                            val = float(v)
                            # -999 is SNOWPACK's code for missing data
                            return val if val != -999 else default
                        except ValueError:
                            return default
                return default

            # --- Map SNOWPACK Outputs to Machine Learning Features ---
            features['SWE'] = get_val('SWE')
            features['MS_Snow'] = get_val('MS_Snow')
            features['Pen_depth'] = get_val('ski_pen')  # Found it! SNOWPACK calls it ski_pen
            features['HN24'] = get_val('HN24')
            features['HN72_24'] = get_val('HN72_24')    # Found it natively!
            features['wind_trans24'] = get_val('wind_trans24')
            
            # Energy & Radiation Variables
            features['pAlbedo'] = get_val('pAlbedo')
            features['Qw'] = get_val('Qw')
            features['LWR_net'] = get_val('LWR_net')
            features['ILWR'] = get_val('ILWR')
            features['S4'] = get_val('S4', 6.0)
            features['Sn'] = get_val('Sn', 6.0)
            
            # Variables not in this specific SMET version get safe defaults
            features['HN24_7d'] = get_val('HN168', 0.0) 
            features['wind_trans24_3d'] = get_val('WIND_TRANS72', 0.0) 
            features['min_ccl_pen'] = get_val('ski_pen') # Good proxy

    return features

# --- Test the Parser ---
if __name__ == "__main__":
    result = extract_all_features("output/DAV3_IMIS_LIVE.pro", "output/DAV3_IMIS_LIVE.smet")
    print("--- EXTRACTED FEATURES ---")
    for k, v in result.items():
        print(f"{k}: {v}")