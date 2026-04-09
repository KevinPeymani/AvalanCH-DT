<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
  xmlns="http://www.opengis.net/sld"
  xmlns:ogc="http://www.opengis.net/ogc"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.opengis.net/sld http://schemas.opengis.net/sld/1.0.0/StyledLayerDescriptor.xsd">
  <NamedLayer>
    <Name>danger_latest</Name>
    <UserStyle>
      <Title>Avalanche Danger</Title>
      <FeatureTypeStyle>
        <Rule>
          <RasterSymbolizer>
            <ChannelSelection>
              <GrayChannel>
                <SourceChannelName>1</SourceChannelName>
              </GrayChannel>
            </ChannelSelection>
            <ColorMap type="values">
              <!-- 1 = Low: green -->
              <ColorMapEntry color="#50b14b" quantity="1" label="1 Low" opacity="1.0"/>
              <!-- 2 = Moderate: yellow -->
              <ColorMapEntry color="#ffe500" quantity="2" label="2 Moderate" opacity="1.0"/>
              <!-- 3 = Considerable: orange -->
              <ColorMapEntry color="#f8821a" quantity="3" label="3 Considerable" opacity="1.0"/>
              <!-- 4 = High: red -->
              <ColorMapEntry color="#e5052a" quantity="4" label="4 High" opacity="1.0"/>
              <!-- 5 = Very High: dark red -->
              <ColorMapEntry color="#7b0014" quantity="5" label="5 Very High" opacity="1.0"/>
              <!-- NoData: transparent -->
              <ColorMapEntry color="#000000" quantity="-999" label="NoData" opacity="0.0"/>
            </ColorMap>
          </RasterSymbolizer>
        </Rule>
      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>
