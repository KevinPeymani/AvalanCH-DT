import "./styles.css";

import { LV95, WGS84 } from "@swissgeo/coordinates";

const {
  Viewer,
  CesiumTerrainProvider,
  ImageryLayer,
  UrlTemplateImageryProvider,
  Rectangle,
  Cesium3DTileset,
} = window.Cesium;

async function setupCesium() {
  const viewer = new Viewer("map", {
    animation: false,
    timeline: false,
    baseLayerPicker: false,
    infoBox: false,
    selectionIndicator: false,
    fullscreenButton: false,
    navigationHelpButton: false,
    homeButton: false,
    sceneModePicker: false,
    geocoder: false,

    terrainProvider: await CesiumTerrainProvider.fromUrl(
      "https://3d.geo.admin.ch/ch.swisstopo.terrain.3d/v1/"
    ),
    baseLayer: new ImageryLayer(
      new UrlTemplateImageryProvider({
        url: "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.swisstlm3d-karte-farbe.3d/default/current/3857/{z}/{x}/{y}.jpeg",
        minimumLevel: 8,
        maximumLevel: 17,
        rectangle: Rectangle.fromDegrees(...LV95.getBoundsAs(WGS84).flatten),
      })
    ),
  });
  // Terrain is opaque (nothing should go through)
  viewer.scene.globe.depthTestAgainstTerrain = true;

  // Add buildings
  const swissBuildings = await Cesium3DTileset.fromUrl(
    "https://3d.geo.admin.ch/ch.swisstopo.swissbuildings3d.3d/v1/tileset.json"
  );
  viewer.scene.primitives.add(swissBuildings);

  viewer.camera.setView({
    destination: Cesium.Cartesian3.fromDegrees(8.67, 46.72, 4500),
    orientation: {
      pitch: Cesium.Math.toRadians(-20),
    },
  });
}

setupCesium();
