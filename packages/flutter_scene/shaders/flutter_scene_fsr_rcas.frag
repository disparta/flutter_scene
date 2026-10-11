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

#define FSR_RCAS_F 1
#define FSR_RCAS_PASSTHROUGH_ALPHA 1
#include "ffx_fsr1.h"
AF4 FsrRcasLoadF(ASU2 p) { return loadPixel(p); }
void FsrRcasInputF(inout AF1 r,inout AF1 g,inout AF1 b) {}
void main() {
  // FsrRcasCon(0.5 stops): only con.x is used by the FP32 algorithm.
  // Avoid the reference setup's unused half packing on GLES 3.0.
  uvec4 con = uvec4(floatBitsToUint(exp2(-0.5)),0u,0u,0u);
  uvec2 p = uvec2(min(floor(v_uv * fsr.output_size), fsr.output_size-1.0));
  vec4 c;
  FsrRcasF(c.r,c.g,c.b,c.a,p,con);
  frag_color = vec4(clamp(c.rgb,0.0,1.0)*c.a,c.a);
}
