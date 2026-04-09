<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
  xmlns="http://www.opengis.net/sld"
  xmlns:ogc="http://www.opengis.net/ogc"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.opengis.net/sld http://schemas.opengis.net/sld/1.0.0/StyledLayerDescriptor.xsd">
  <NamedLayer>
    <Name>hs_latest</Name>
    <UserStyle>
      <Title>Snow Height (m)</Title>
      <FeatureTypeStyle>
        <Rule>
          <RasterSymbolizer>
            <ChannelSelection>
              <GrayChannel>
                <SourceChannelName>1</SourceChannelName>
              </GrayChannel>
            </ChannelSelection>
            <ColorMap type="ramp">
              <!-- NoData: transparent -->
              <ColorMapEntry color="#000000" quantity="-999" label="NoData" opacity="0.0"/>
              <!-- 0m: transparent white -->
              <ColorMapEntry color="#ffffff" quantity="0.0" label="0 m" opacity="0.0"/>
              <!-- 0.5m: very pale blue -->
              <ColorMapEntry color="#ddeeff" quantity="0.5" label="0.5 m" opacity="0.85"/>
              <!-- 2m: light blue -->
              <ColorMapEntry color="#88bbee" quantity="2.0" label="2 m" opacity="0.9"/>
              <!-- 4m: medium blue -->
              <ColorMapEntry color="#2277cc" quantity="4.0" label="4 m" opacity="0.95"/>
              <!-- 6m: deep blue -->
              <ColorMapEntry color="#003a8c" quantity="6.0" label="6 m" opacity="1.0"/>
              <!-- 8m+: navy -->
              <ColorMapEntry color="#00144d" quantity="8.0" label="8 m" opacity="1.0"/>
            </ColorMap>
          </RasterSymbolizer>
        </Rule>
      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>
