// Configuration for easy updates

const {
  Viewer,
  CesiumTerrainProvider,
  ImageryLayer,
  UrlTemplateImageryProvider,
  Rectangle,
  Cesium3DTileset,
} = window.Cesium;

const CONFIG = {
  ST_BUILDINGS: 'https://3d.geo.admin.ch/ch.swisstopo.terrain.3d/v1/20250101/layer.json',
  INITIAL_VIEW: {
    lat: 46.9480,
    lon: 7.4474,
    height: 2000
  }
};

const MapApp = {
  viewer: null,

  async init() {
    this.viewer = new Cesium.Viewer('cesiumContainer', {
      terrainProvider: await Cesium.CesiumTerrainProvider({ url: "https://3d.geo.admin.ch/ch.swisstopo.terrain.3d/v1/" }),
      timeline: false,
      animation: false,
    });

    //this.add3DTiles(CONFIG.ST_BUILDINGS);
    this.flyTo(CONFIG.INITIAL_VIEW.lon, CONFIG.INITIAL_VIEW.lat, CONFIG.INITIAL_VIEW.height);
  },

  async add3DTiles(url) {
    try {
      const tileset = await Cesium.Cesium3DTileset.fromUrl(url);
      this.viewer.scene.primitives.add(tileset);
    } catch (error) {
      console.error(`Error loading tileset: ${error}`);
    }
  },

  // Method to add information on top (Labels/Pins)
  addInfoPoint(lon, lat, title, description) {
    this.viewer.entities.add({
      position: Cesium.Cartesian3.fromDegrees(lon, lat, 500), // 500m above ground
      label: {
        text: title,
        font: '14pt sans-serif',
        verticalOrigin: Cesium.VerticalOrigin.BOTTOM,
        pixelOffset: new Cesium.Cartesian2(0, -15)
      },
      point: { pixelSize: 10, color: Cesium.Color.RED }
    });
  },

  flyTo(lon, lat, height) {
    this.viewer.camera.flyTo({
      destination: Cesium.Cartesian3.fromDegrees(lon, lat, height),
      orientation: { pitch: Cesium.Math.toRadians(-30) }
    });
  },

  async addWeatherStations() {
    try {
      const response = await fetch('../../data/automatic_weather_stations/stations.json');
      const stations = await response.json();

      stations.forEach(station => {
        this.viewer.entities.add({
          category: 'weather-station',
          name: station.station_name,
          position: Cesium.Cartesian3.fromDegrees(
            station.lon,
            station.lat,
            station.alt // Uses the altitude from the CSV
          ),
          point: {
            pixelSize: 8,
            color: Cesium.Color.DEEPSKYBLUE,
            outlineColor: Cesium.Color.WHITE,
            outlineWidth: 2,
            heightReference: Cesium.HeightReference
          },
          label: {
            text: station.station_abbr,
            showBackground: true,
            backgroundColor: new Cesium.Color(0,0,0,0.5),
            font: '10pt sans-serif',
            verticalOrigin: Cesium.VerticalOrigin.TOP,
            pixelOffset: new Cesium.Cartesian2(0, 20),
            eyeOffset: new Cesium.Cartesian3(0, 0, -30),
            distanceDisplayCondition: new Cesium.DistanceDisplayCondition(0, 150000),
            disableDepthTestDistance: Number.POSITIVE_INFINITY
          },
          description: `
            <div style="font-family: sans-serif;">
              <p><strong>Canton:</strong> ${station.station_canton}</p>
              <p><strong>Altitude:</strong> ${station.alt} m</p>
              <p><a href="${station.station_url_en}" target="_blank">View Live Data (MeteoSwiss)</a></p>
            </div>
          `
        });
      });
    } catch (error) {
      console.error("Error loading weather stations:", error);
    }
  },
    toggleWeatherLabels(isVisible) {
    const entities = this.viewer.entities.values;
    entities.forEach(entity => {
      // On ne cible que les entités qui ont notre catégorie
      if (entity.category === 'weather-station' && entity.label) {
        entity.label.show = isVisible;
      }
    });
  }

};


// Start the app
await MapApp.init();

// Example: Adding an info point on top
MapApp.addInfoPoint(7.4474, 46.9480, "Bern", "Swiss Capital");
MapApp.addWeatherStations();

document.getElementById('labelToggle').addEventListener('change', (e) => {
  MapApp.toggleWeatherLabels(e.target.checked);
});