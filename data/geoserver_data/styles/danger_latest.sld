<?xml version="1.0" encoding="UTF-8"?><sld:StyledLayerDescriptor xmlns:sld="http://www.opengis.net/sld" xmlns="http://www.opengis.net/sld" xmlns:gml="http://www.opengis.net/gml" xmlns:ogc="http://www.opengis.net/ogc" version="1.0.0">
  <sld:NamedLayer>
    <sld:Name>Default Styler</sld:Name>
    <sld:UserStyle>
      <sld:Name>Default Styler</sld:Name>
      <sld:Title>Avalanche Danger</sld:Title>
      <sld:FeatureTypeStyle>
        <sld:Name>name</sld:Name>
        <sld:Rule>
          <sld:RasterSymbolizer>
            <sld:ChannelSelection>
              <sld:GrayChannel>
                <sld:SourceChannelName>1</sld:SourceChannelName>
                <sld:ContrastEnhancement>
                  <sld:GammaValue>1.0</sld:GammaValue>
                </sld:ContrastEnhancement>
              </sld:GrayChannel>
            </sld:ChannelSelection>
            <sld:ColorMap type="values">
              <sld:ColorMapEntry color="#50b14b" opacity="1.0" quantity="1" label="1 Low"/>
              <sld:ColorMapEntry color="#ffe500" opacity="1.0" quantity="2" label="2 Moderate"/>
              <sld:ColorMapEntry color="#f8821a" opacity="1.0" quantity="3" label="3 Considerable"/>
              <sld:ColorMapEntry color="#e5052a" opacity="1.0" quantity="4" label="4 High"/>
              <sld:ColorMapEntry color="#7b0014" opacity="1.0" quantity="5" label="5 Very High"/>
              <sld:ColorMapEntry color="#000000" opacity="0.0" quantity="-999" label="NoData"/>
            </sld:ColorMap>
            <sld:ContrastEnhancement/>
          </sld:RasterSymbolizer>
        </sld:Rule>
      </sld:FeatureTypeStyle>
    </sld:UserStyle>
  </sld:NamedLayer>
</sld:StyledLayerDescriptor>

