shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never;

uniform sampler3D NoiseTex;
uniform sampler3D DetailNoiseTex;
uniform sampler2D WeatherMap;
uniform sampler2D BlueNoise;

uniform sampler2D _MainTex : hint_screen_texture;
uniform sampler2D _CameraDepthTexture : hint_depth_texture;

uniform vec4 params;
uniform vec3 mapSize;
uniform float densityMultiplier;
uniform float densityOffset;
uniform float scale;
uniform float detailNoiseScale;
uniform float detailNoiseWeight;
uniform vec4 detailWeights;
uniform vec4 shapeNoiseWeights;
uniform vec4 phaseParams;

// March settings
uniform int numStepsLight;
uniform float rayOffsetStrength;

uniform vec3 boundsMin;
uniform vec3 boundsMax;

uniform vec3 shapeOffset;
uniform vec3 detailOffset;

// Light settings
uniform float lightAbsorptionTowardSun;
uniform float lightAbsorptionThroughCloud;
uniform float darknessThreshold;
uniform vec4 _LightColor0;
uniform vec4 colA;
uniform vec4 colB;

// Animation settings
uniform float timeScale;
uniform float baseSpeed;
uniform float detailSpeed;

// Debug settings:
uniform int debugViewMode; // 0 = off; 1 = shape tex; 2 = detail tex; 3 = weathermap
uniform int debugGreyscale;
uniform int debugShowAllChannels;
uniform float debugNoiseSliceDepth;
uniform vec4 debugChannelWeight;
uniform float debugTileAmount;
uniform float viewerSize;

float remap(float v, float minOld, float maxOld, float minNew, float maxNew) {
    return minNew + (v-minOld) * (maxNew - minNew) / (maxOld-minOld);
}

vec2 squareUV(vec2 uv, vec2 viewport_size) {
    float width = viewport_size.x;
    float height = viewport_size.y;
    //float minDim = min(width, height);
    float s = 1000.;
    float x = uv.x * width;
    float y = uv.y * height;
    return vec2 (x/s, y/s);
}

// Returns (dstToBox, dstInsideBox). If ray misses box, dstInsideBox will be zero
vec2 rayBoxDst(vec3 i_boundsMin, vec3 i_boundsMax, vec3 rayOrigin, vec3 invRaydir) {
    // Adapted from: http://jcgt.org/published/0007/03/04/
    vec3 t0 = (i_boundsMin - rayOrigin) * invRaydir;
    vec3 t1 = (i_boundsMax - rayOrigin) * invRaydir;
    vec3 tmin = min(t0, t1);
    vec3 tmax = max(t0, t1);
    
    float dstA = max(max(tmin.x, tmin.y), tmin.z);
    float dstB = min(tmax.x, min(tmax.y, tmax.z));

    // CASE 1: ray intersects box from outside (0 <= dstA <= dstB)
    // dstA is dst to nearest intersection, dstB dst to far intersection

    // CASE 2: ray intersects box from inside (dstA < 0 < dstB)
    // dstA is the dst to intersection behind the ray, dstB is dst to forward intersection

    // CASE 3: ray misses box (dstA > dstB)

    float dstToBox = max(0, dstA);
    float dstInsideBox = max(0, dstB - dstToBox);
    return vec2(dstToBox, dstInsideBox);
}

// Henyey-Greenstein
float hg(float a, float g) {
    float g2 = g*g;
    return (1.-g2) / (4. * PI * pow(1.+g2-2.*g*(a), 1.5));
}

float phase(float a) {
    float blend = .5;
    float hgBlend = hg(a,phaseParams.x) * (1.-blend) + hg(a,-phaseParams.y) * blend;
    return phaseParams.z + hgBlend*phaseParams.w;
}

float beer(float d) {
    float beer = exp(-d);
    return beer;
}

float remap01(float v, float low, float high) {
    return (v-low)/(high-low);
}

float sampleDensity(vec3 rayPos) {
    // Constants:
    const int mipLevel = 0;
    const float baseScale = 1./1000.0;
    const float offsetSpeed = 1./100.0;

    // Calculate texture sample positions
    float time = 0.;
    vec3 size = boundsMax - boundsMin;
    vec3 boundsCentre = (boundsMin+boundsMax) * .5;
    vec3 uvw = (size * .5 + rayPos) * baseScale * scale;
    vec3 shapeSamplePos = uvw + shapeOffset * offsetSpeed + vec3(time,time*0.1,time*0.2) * baseSpeed;

    // Calculate falloff at along x/z edges of the cloud container
    const float containerEdgeFadeDst = 50.;
    float dstFromEdgeX = min(containerEdgeFadeDst, min(rayPos.x - boundsMin.x, boundsMax.x - rayPos.x));
    float dstFromEdgeZ = min(containerEdgeFadeDst, min(rayPos.z - boundsMin.z, boundsMax.z - rayPos.z));
    float edgeWeight = min(dstFromEdgeZ,dstFromEdgeX)/containerEdgeFadeDst;
    
    // Calculate height gradient from weather map
    //vec2 weatherUV = (size.xz * .5 + (rayPos.xz-boundsCentre.xz)) / max(size.x,size.z);
    //float weatherMap = WeatherMap.SampleLevel(samplerWeatherMap, weatherUV, mipLevel).x;
    float gMin = .2;
    float gMax = .7;
    float heightPercent = (rayPos.y - boundsMin.y) / size.y;
    float heightGradient = clamp(remap(heightPercent, 0.0, gMin, 0., 1.), 0., 1.) * clamp(remap(heightPercent, 1., gMax, 0., 1.), 0., 1.);
    heightGradient *= edgeWeight;

    // Calculate base shape density
    vec4 shapeNoise = texture(NoiseTex, shapeSamplePos);
    vec4 normalizedShapeWeights = shapeNoiseWeights / dot(shapeNoiseWeights, vec4(1.));
    float shapeFBM = dot(shapeNoise, normalizedShapeWeights) * heightGradient;
    float baseShapeDensity = shapeFBM + densityOffset * .1;

    // Save sampling from detail tex if shape density <= 0
    if (baseShapeDensity > 0.) {
        // Sample detail noise
        vec3 detailSamplePos = uvw*detailNoiseScale + detailOffset * offsetSpeed + vec3(time*.4,-time,time*0.1)*detailSpeed;
        vec4 detailNoise = texture(DetailNoiseTex, detailSamplePos);
        vec4 normalizedDetailWeights = detailWeights / dot(detailWeights, vec4(1.));
        float detailFBM = dot(detailNoise, normalizedDetailWeights);

        // Subtract detail noise from base shape (weighted by inverse density so that edges get eroded more than centre)
        float oneMinusShape = 1. - shapeFBM;
        float detailErodeWeight = oneMinusShape * oneMinusShape * oneMinusShape;
        float cloudDensity = baseShapeDensity - (1. - detailFBM) * detailErodeWeight * detailNoiseWeight;

        return cloudDensity * densityMultiplier * 0.1;
    }
    return 0.;
}

// Calculate proportion of light that reaches the given point from the lightsource
float lightmarch(vec3 position, vec3 light_pos) {
    vec3 dirToLight = light_pos.xyz;
    float dstInsideBox = rayBoxDst(boundsMin, boundsMax, position, 1. / dirToLight).y;
    
    float stepSize = dstInsideBox / float(numStepsLight);
    float totalDensity = 0.;

    for (int step = 0; step < numStepsLight; step ++) {
        position += dirToLight * stepSize;
        totalDensity += max(0, sampleDensity(position) * stepSize);
    }

    float transmittance = exp(-totalDensity * lightAbsorptionTowardSun);
    return darknessThreshold + transmittance * (1. - darknessThreshold);
}

vec4 debugDrawNoise(vec2 uv) {

    vec4 channels = vec4(0);
    vec3 samplePos = vec3(uv.x,uv.y, debugNoiseSliceDepth);

    if (debugViewMode == 1) {
        channels = texture(NoiseTex, samplePos);
    }
    else if (debugViewMode == 2) {
        channels = texture(DetailNoiseTex, samplePos);
    }
    //else if (debugViewMode == 3) {
        //channels = texture(samplerWeatherMap, samplePos.xy);
    //}

    //if (debugShowAllChannels) {
        //return channels;
    //}
    //else {
    vec4 maskedChannels = (channels*debugChannelWeight);
    if (debugGreyscale == 1 || debugChannelWeight.w == 1.0) {
        return vec4(dot(maskedChannels, vec4(1.0)));
    }
    else {
        return maskedChannels;
    }
    //}
}


void fragment()
{
    // Create ray
	vec3 camera_position = CAMERA_POSITION_WORLD;
	
	vec3 ray_origin = camera_position.xyz;
	vec3 ray_direction = (INV_VIEW_MATRIX * (-vec4(VIEW, 0.))).xyz;
	
    vec3 rayPos = ray_origin;
	vec3 viewVector = ray_direction;
    float viewLength = length(viewVector);
    vec3 rayDir = viewVector / viewLength;
    
    // Depth and cloud container intersection info:
    float nonlin_depth = texture(_CameraDepthTexture, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, nonlin_depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float depth = -view.z;
    vec2 rayToContainerInfo = rayBoxDst(boundsMin, boundsMax, rayPos, vec3(1.)/rayDir);
    float dstToBox = rayToContainerInfo.x;
    float dstInsideBox = rayToContainerInfo.y;

    // point of intersection with the cloud container
    vec3 entryPoint = rayPos + rayDir * dstToBox;

    // random starting offset (makes low-res results noisy rather than jagged/glitchy, which is nicer)
    float randomOffset = texture(BlueNoise, squareUV(SCREEN_UV*vec2(3.), vec2(0.))).r;
    randomOffset *= rayOffsetStrength;
    
    // Phase function makes clouds brighter around sun
    //float cosAngle = dot(rayDir, _WorldSpaceLightPos0.xyz);
    //float phaseVal = phase(cosAngle);
	float phaseVal = 1.;

    float dstTravelled = randomOffset;
    float dstLimit = min(depth-dstToBox, dstInsideBox);
    
    
    
    const float stepSize = 11.;

    // March through volume:
    float transmittance = 1.;
    vec3 lightEnergy = vec3(0.);

    while (dstTravelled < dstLimit) {
        rayPos = entryPoint + rayDir * dstTravelled;
        float density = sampleDensity(rayPos);
        
        if (density > 0.) {
            float lightTransmittance = lightmarch(rayPos, vec3(0.));
            lightEnergy += density * stepSize * transmittance * lightTransmittance * phaseVal;
            transmittance *= exp(-density * stepSize * lightAbsorptionThroughCloud);
        
            // Exit early if T is close to zero as further samples won't affect the result much
            if (transmittance < 0.01) {
                break;
            }
        }
        dstTravelled += stepSize;
    }

    // Add clouds to background
    vec3 backgroundCol = texture(_MainTex, SCREEN_UV).rgb;
    vec3 cloudCol = lightEnergy * _LightColor0.rgb;
    vec3 col = backgroundCol * transmittance + cloudCol;
    ALBEDO = col;

}
