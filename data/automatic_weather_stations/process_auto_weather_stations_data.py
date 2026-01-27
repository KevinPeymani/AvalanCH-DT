import pandas as pd
# data link : https://opendatadocs.meteoswiss.ch/a-data-groundbased/a1-automatic-weather-stations?metadata=stations
# Load the CSV file to inspect its content
file_path = 'ogd-smn_meta_stations.csv'
df = pd.read_csv(file_path, sep=';', encoding='windows-1252')

# Display the first few rows and column information
print(df.head())
print(df.info())

# Select relevant columns and export to JSON
relevant_columns = [
    'station_abbr', 'station_name', 'station_canton', 
    'station_height_barometer_masl', 'station_coordinates_wgs84_lat', 
    'station_coordinates_wgs84_lon', 'station_url_en'
]

# Create a clean dataframe
clean_df = df[relevant_columns].rename(columns={
    'station_coordinates_wgs84_lat': 'lat',
    'station_coordinates_wgs84_lon': 'lon',
    'station_height_barometer_masl': 'alt'
})

# Save to JSON
clean_df.to_json('stations.json', orient='records', indent=2)
print("File stations.json created successfully.")