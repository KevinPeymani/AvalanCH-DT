import os

def extract_stability_indices(pro_filepath="output/DAV3_IMIS_LIVE.pro"):
    if not os.path.exists(pro_filepath):
        return None

    codes = {'sk38': None, 'sn38': None, 'sdef': None, 'ccl': None}
    
    data = {'sk38': [], 'sn38': [], 'sdef': [], 'ccl': []}

    with open(pro_filepath, 'r') as file:
        for line in file:
            parts = line.strip().split(',')
            if not parts: continue
            

            lower_line = line.lower()
            if "sk38" in lower_line and not codes['sk38'] and parts[0].isdigit(): codes['sk38'] = parts[0]
            if "sn38" in lower_line and not codes['sn38'] and parts[0].isdigit(): codes['sn38'] = parts[0]
            if "sdef" in lower_line and not codes['sdef'] and parts[0].isdigit(): codes['sdef'] = parts[0]
            if "critical cut length" in lower_line and not codes['ccl'] and parts[0].isdigit(): codes['ccl'] = parts[0]


            if len(parts) > 2 and parts[0].isdigit():
                for key, code in codes.items():
                    if parts[0] == code:
                        for v in parts[2:]:
                            try:
                                val = float(v.strip())
                                if val != -999 and val > 0: data[key].append(val)
                            except ValueError: pass

    # Return minimum (weakest) values or safe defaults if flat/empty
    return {
        'sk38_pwl': min(data['sk38']) if data['sk38'] else 6.0,
        'sn38_pwl': min(data['sn38']) if data['sn38'] else 6.0,
        'Sd': min(data['sdef']) if data['sdef'] else 6.0,  # Sdef mapped to Sd
        'ccl_pwl': min(data['ccl']) if data['ccl'] else 3.0
    }