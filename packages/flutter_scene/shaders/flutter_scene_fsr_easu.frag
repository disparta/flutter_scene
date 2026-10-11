// AMD FidelityFX FSR 1.0.2, MIT; see ffx_fsr1.h and FSR1_LICENSE.txt.
// Only the FP32 reference path is enabled. No gather, compute or FP16.
precision highp float;
precision highp int;
#define A_GPU 1
#define A_GLSL 1
#include "ffx_a.h"
uniform FsrInfo { vec2 input_size; vec2 output_size; } fsr;
uniform highp sampler2D input_color;
in vec2 v_uv;
out vec4 frag_color;

vec4 loadPixel(ivec2 p) {
  // texelFetch outside the texture is undefined even with a clamp sampler.
  vec4 c = texelFetch(input_color, clamp(p, ivec2(0), ivec2(fsr.input_size)-1), 0);
  // Scene display colour is premultiplied. Reconstruct straight colour,
  // filter coverage separately, and premultiply again only at the output.
  c.rgb = c.a > 0.0 ? c.rgb / c.a : vec3(0.0);
  return c;
}

#define FSR_EASU_F 1
#include "ffx_fsr1.h"
// GLSL gather order is bottom-left, bottom-right, top-right, top-left.
// The pinned reference calls R, G, then B for each of its four gather groups.
// Cache full RGBA texels in R and reuse them in G/B: relying on driver CSE
// produced 37 texture reads per output pixel on the original portable path.
// Unused lanes in the first/last group are removed by the shader compiler.
vec4 gather0, gather1, gather2, gather3;
void cacheGather(vec2 uv) {
  ivec2 p = ivec2(floor(uv * fsr.input_size - 0.5));
  gather0 = loadPixel(p+ivec2(0,1));
  gather1 = loadPixel(p+ivec2(1,1));
  gather2 = loadPixel(p+ivec2(1,0));
  gather3 = loadPixel(p);
}
AF4 FsrEasuRF(AF2 p) { cacheGather(p); return vec4(gather0.r,gather1.r,gather2.r,gather3.r); }
AF4 FsrEasuGF(AF2 p) { return vec4(gather0.g,gather1.g,gather2.g,gather3.g); }
AF4 FsrEasuBF(AF2 p) { return vec4(gather0.b,gather1.b,gather2.b,gather3.b); }
void main() {
  uvec4 c0, c1, c2, c3;
  FsrEasuCon(c0,c1,c2,c3, fsr.input_size.x,fsr.input_size.y,
    fsr.input_size.x,fsr.input_size.y,fsr.output_size.x,fsr.output_size.y);
  uvec2 p = uvec2(min(floor(v_uv * fsr.output_size), fsr.output_size-1.0));
  vec3 rgb;
  FsrEasuF(rgb,p,c0,c1,c2,c3);
  vec2 source = (vec2(p)+0.5)*fsr.input_size/fsr.output_size-0.5;
  ivec2 lo = ivec2(floor(source));
  vec2 f = fract(source);
  float alpha = mix(mix(loadPixel(lo).a,loadPixel(lo+ivec2(1,0)).a,f.x),
                    mix(loadPixel(lo+ivec2(0,1)).a,loadPixel(lo+ivec2(1,1)).a,f.x),f.y);
  frag_color = vec4(clamp(rgb,0.0,1.0)*alpha,alpha);
}
