// Adapted from Qualcomm's standard SGSR 1 mobile shader (not edge-direction).
// Copyright (c) 2025, Qualcomm Innovation Center, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause. See SGSR1_LICENSE.txt.
// Upstream d926f074bcb9d714e179f1ce0fcb9ee2eeb5074e; unmodified reference
// retained in sgsr1_mobile_reference.frag. Arithmetic remains mediump, with
// highp coordinates and viewport data as in the reference.
precision mediump float;
precision highp int;
#define OperationMode 1
#define EdgeThreshold (8.0/255.0)
#define EdgeSharpness 2.0
uniform SgsrInfo { highp vec2 input_size; highp vec2 output_size; } sgsr;
uniform mediump sampler2D input_color;
in highp vec2 v_uv;
out vec4 frag_color;

// Bundled shaders have backend defines. GLES 3.0 has no core textureGather.
// Test overrides exercise both implementations on the same reference fixtures.
#if !defined(IMPELLER_TARGET_VULKAN) && !defined(IMPELLER_TARGET_METAL) && !defined(SGSR_TEST_GATHER)
float greenAt(ivec2 p) {
  return texelFetch(input_color, clamp(p, ivec2(0), ivec2(sgsr.input_size)-1), 0).g;
}
vec4 gatherGreen(highp vec2 uv) {
  ivec2 p = ivec2(floor(uv * sgsr.input_size - 0.5));
  // Four explicit reads shared across all lanes; no per-channel re-fetches.
  return vec4(greenAt(p+ivec2(0,1)), greenAt(p+ivec2(1,1)),
              greenAt(p+ivec2(1,0)), greenAt(p));
}
vec2 gatherUp(highp vec2 uv) {
  ivec2 p = ivec2(floor(uv * sgsr.input_size - 0.5));
  return vec2(greenAt(p), greenAt(p+ivec2(1,0)));
}
vec2 gatherDown(highp vec2 uv) {
  ivec2 p = ivec2(floor(uv * sgsr.input_size - 0.5));
  return vec2(greenAt(p+ivec2(1,1)), greenAt(p+ivec2(0,1)));
}
#else
vec4 gatherGreen(highp vec2 uv) { return textureGather(input_color, uv, 1); }
vec2 gatherUp(highp vec2 uv) { return textureGather(input_color, uv, 1).wz; }
vec2 gatherDown(highp vec2 uv) { return textureGather(input_color, uv, 1).yx; }
#endif

float fastLanczos2(float x)
{
	float wA = x-4.0;
	float wB = x*wA-wA;
	wA *= wA;
	return wB*wA;
}
vec2 weightY(float dx, float dy,float c, float std)
{
	float x = ((dx*dx)+(dy* dy))* 0.55 + clamp(abs(c)*std, 0.0, 1.0);
	float w = fastLanczos2(x);
	return vec2(w, w * c);	
}

void main()
{
	int mode = OperationMode;
	float edgeThreshold = EdgeThreshold;
	float edgeSharpness = EdgeSharpness;

	// Filter premultiplied display colour; retain bilinear coverage separately.
    vec4 color = textureLod(input_color, v_uv, 0.0);
    float alpha = color.a;

	highp float xCenter;
	xCenter = abs(v_uv.x+-0.5);
	highp float yCenter;
	yCenter = abs(v_uv.y+-0.5);

	//todo: config the SR region based on needs
	//if ( mode!=4 && xCenter*xCenter+yCenter*yCenter<=0.4 * 0.4)
	if ( mode!=4)
	{
		highp vec2 imgCoord = ((v_uv*sgsr.input_size)+vec2(-0.5,0.5));
		highp vec2 imgCoordPixel = floor(imgCoord);
		highp vec2 coord = (imgCoordPixel*(1.0 / sgsr.input_size));
		vec2 pl = (imgCoord+(-imgCoordPixel));
		vec4  left = gatherGreen(coord);

		float edgeVote = abs(left.z - left.y) + abs(color[mode] - left.y)  + abs(color[mode] - left.z) ;
		if(edgeVote > edgeThreshold)
		{
			coord.x += (1.0 / sgsr.input_size.x);

			vec4 right = gatherGreen(coord + vec2(1.0 / sgsr.input_size.x, 0.0));
			vec4 upDown;
			upDown.xy = gatherUp(coord - vec2(0.0, 1.0 / sgsr.input_size.y));
			upDown.zw  = gatherDown(coord + vec2(0.0, 1.0 / sgsr.input_size.y));

			float mean = (left.y+left.z+right.x+right.w)*0.25;
			left = left - vec4(mean);
			right = right - vec4(mean);
			upDown = upDown - vec4(mean);
			color.w =color[mode] - mean;

			float sum = (((((abs(left.x)+abs(left.y))+abs(left.z))+abs(left.w))+(((abs(right.x)+abs(right.y))+abs(right.z))+abs(right.w)))+(((abs(upDown.x)+abs(upDown.y))+abs(upDown.z))+abs(upDown.w)));				
			float std = 2.181818/sum;
			
			vec2 aWY = weightY(pl.x, pl.y+1.0, upDown.x,std);				
			aWY += weightY(pl.x-1.0, pl.y+1.0, upDown.y,std);
			aWY += weightY(pl.x-1.0, pl.y-2.0, upDown.z,std);
			aWY += weightY(pl.x, pl.y-2.0, upDown.w,std);			
			aWY += weightY(pl.x+1.0, pl.y-1.0, left.x,std);
			aWY += weightY(pl.x, pl.y-1.0, left.y,std);
			aWY += weightY(pl.x, pl.y, left.z,std);
			aWY += weightY(pl.x+1.0, pl.y, left.w,std);
			aWY += weightY(pl.x-1.0, pl.y-1.0, right.x,std);
			aWY += weightY(pl.x-2.0, pl.y-1.0, right.y,std);
			aWY += weightY(pl.x-2.0, pl.y, right.z,std);
			aWY += weightY(pl.x-1.0, pl.y, right.w,std);

			float finalY = aWY.y/aWY.x;

			float maxY = max(max(left.y,left.z),max(right.x,right.w));
			float minY = min(min(left.y,left.z),min(right.x,right.w));
			finalY = clamp(edgeSharpness*finalY, minY, maxY);
					
			float deltaY = finalY -color.w;	
			
			//smooth high contrast input
			deltaY = clamp(deltaY, -23.0 / 255.0, 23.0 / 255.0);

			color.x = clamp((color.x+deltaY),0.0,1.0);
			color.y = clamp((color.y+deltaY),0.0,1.0);
			color.z = clamp((color.z+deltaY),0.0,1.0);
		}
	}

	// Reference forces opaque alpha. Flutter composites premultiplied colour:
    // never sharpen alpha or allow RGB to exceed coverage at transparent edges.
    frag_color = vec4(clamp(color.rgb, vec3(0.0), vec3(alpha)), alpha);
}
