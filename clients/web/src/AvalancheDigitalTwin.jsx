import React, { useEffect, useRef, useState } from 'react';
import * as Cesium from 'cesium';
import "cesium/Source/Widgets/widgets.css";

const AvalancheDigitalTwin = () => {
  const cesiumContainer = useRef(null);
  const viewerRef = useRef(null);
  const [showStations, setShowStations] = useState(true);

  useEffect(() => {
    const initCesium = async () => {
      if (viewerRef.current) return;
      viewerRef.current = new Cesium.Viewer(cesiumContainer.current, {
        terrainProvider: await Cesium.CesiumTerrainProvider.fromUrl(
          "https://3d.geo.admin.ch/ch.swisstopo.terrain.3d/v1/"
        ),
        timeline: false,
        animation: false,
        sceneMode: Cesium.SceneMode.MORPHING,
        skyBox: false,

      });

      const swissRectangle = Cesium.Rectangle.fromDegrees(
        5.9559,  // Ouest
        45.8179, // Sud
        10.4921, // Est
        47.8084  // Nord
      );
      viewerRef.current.scene.globe.cartographicLimitRectangle = swissRectangle;
      viewerRef.current.scene.globe.baseColor = Cesium.Color.WHITE;
      viewerRef.current.scene.skyAtmosphere.show = false; 
      // Ajout des stations
      await loadWeatherStations();
      flyToSwitzerland(viewerRef.current);
    };

    initCesium();

    return () => {
      if (viewerRef.current) viewerRef.current.destroy();
      viewerRef.current = null;
    };
  }, []);


  useEffect(() => {
    if (!viewerRef.current) return;

    const entities = viewerRef.current.entities.values;
    entities.forEach(entity => {
      if (entity.category === 'weather-station' && entity.label && entity.point) {
        entity.label.show = showStations;
        entity.point.show = showStations;
      }
    });
  }, [showStations]);

  const loadWeatherStations = async () => {
    try {
      const response = await fetch('./stations.json');
      const stations = await response.json();

      stations.forEach(station => {
        viewerRef.current.entities.add({
          category: 'weather-station',
          name: station.station_name,
          position: Cesium.Cartesian3.fromDegrees(
            station.lon,
            station.lat,
            0 // Uses the altitude from the CSV
          ),
          point: {
            pixelSize: 8,
            color: Cesium.Color.DEEPSKYBLUE,
            outlineColor: Cesium.Color.WHITE,
            outlineWidth: 2,
            heightReference: Cesium.HeightReference.CLAMP_TO_GROUND
          },
          label: {
            text: station.station_abbr,
            showBackground: true,
            //backgroundColor: new Cesium.Color(0,0,0,0.5),
            font: '10pt sans-serif',
            verticalOrigin: Cesium.VerticalOrigin.TOP,
            pixelOffset: new Cesium.Cartesian2(0, -50),
            eyeOffset: new Cesium.Cartesian3(0, 0, -10),
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
  };

  const flyToSwitzerland = (viewer = viewerRef.current) => {
    viewer.camera.flyTo({
      destination: Cesium.Cartesian3.fromDegrees(
        8.2275,  // Longitude (Centre de la Suisse)
        45, // Latitude
        150000   // Altitude en mètres (150km pour une vue d'ensemble)
      ),
      orientation: {
        heading: Cesium.Math.toRadians(0.0),   // Regarde vers le Nord
        pitch: Cesium.Math.toRadians(-45.0),  // Inclinaison vers le bas (effet 3D)
        roll: 0.0
      },
      duration: 0 // Durée du vol en secondes
    });
  };

  return (
    <div style={{ position: 'relative', width: '100%', height: '100vh' }}>
      {/* Interface React */}
      <div style={{
        position: 'absolute', top: 10, left: 10, zIndex: 10,
        background: 'gray', padding: '15px', borderRadius: '8px'
      }}>
        <h3 style={{ margin: '0 0 10px 0' }}>AvalanCH-DT</h3>
        <label>
          <input
            type="checkbox"
            checked={showStations}
            onChange={(e) => setShowStations(e.target.checked)}
          />
          Stations météo
        </label>
      </div>

      {/* Container Cesium */}
      <div ref={cesiumContainer} style={{ width: '100%', height: '100%' }} />
    </div>
  );
};

export default AvalancheDigitalTwin;