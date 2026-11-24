// The resolve pass for the frames that use none of its optional effects:
// exposure, color grading without lift/gamma/gain, the AgX tone mapping
// operator and display encoding. ResolvePass picks it over
// flutter_scene_resolve.frag when the frame has no chromatic aberration,
// bloom, auto exposure, vignette, film grain, grading LUT or debug view.
//
// The full shader spends nine pow() a pixel (grading gamma, the AgX toe and
// the sRGB encode) and carries every disabled effect behind a uniform
// branch, in float32. On a budget GPU that is the largest single cost of a
// frame that draws nothing else: a Mali-G52 MC1 spends 19 ms of a 1080p
// frame in the AgX and grading maths alone. Here the color maths run at
// mediump, the toe's pow() runs only for pixels with a channel in the toe,
// and the display encode is three square roots.
//
// The block is the full shader's, member for member, so packResolveInfo
// serves both.
#define FLUTTER_SCENE_DEFAULT_FLOAT_PRECISION mediump
precision mediump float;
precision highp int;

uniform ResolveInfo {
  float exposure;
  // 0 = PBR Neutral, 1 = ACES, 2 = Reinhard, 3 = linear, 4 = AgX.
  float tone_mapping_mode;
  // 1.0 -> flip V when sampling scene_color. The scene color is a
  // render-to-texture target, and its sampled Y orientation differs by
  // backend (the OpenGL ES backend's FBO is bottom-up); the Dart side
  // sets this so the resolved image is upright everywhere. Flutter GPU
  // exposes no way to do this in the shader (no backend macro).
  float flip_y;
  // 1.0 -> apply the color grading controls below.
  float grading_enabled;

  float brightness;
  float contrast;
  float saturation;
  float temperature;

  float tint;
  float _pad0;
  float _pad1;
  float _pad2;

  // Only the xyz channels are used; w is padding.
  vec4 lift;
  vec4 gamma;
  vec4 gain;

  float chromatic_aberration_enabled;
  float chromatic_aberration_intensity;
  float time;
  float _pad3;

  float vignette_enabled;
  float vignette_intensity;
  float vignette_radius;
  float vignette_smoothness;

  float grain_enabled;
  float grain_intensity;
  float _pad4;
  float _pad5;

  float bloom_enabled;
  float bloom_intensity;
  // Surface debug view. x: 1 when a view is active, so its display-referred
  // pixels copy through untouched (no exposure, tone mapping, or display
  // encoding). y: the split as a fraction of the width, negative for the
  // whole viewport; pixels at or right of it are the view.
  float debug_view_active;
  float debug_view_split;

  vec4 agx_params;

  // x: grading-LUT blend, 0 disables. y: the cube edge length (the strip
  // texture is y*y wide and y tall). zw: reserved.
  vec4 lut_params;
}
resolve_info;

uniform sampler2D scene_color;

in highp vec2 v_uv;

out vec4 frag_color;

// AgX with the AllenWP curve, as AgXToneMapping in tone_mapping.glsl. The
// toe (below the crossover) is the only part that needs pow(); the shoulder
// is rational.
vec3 AgXFast(vec3 color, vec4 params) {
  const float kCrossover = 0.18;
  const float kShoulderMax = 1.0 - kCrossover;
  const mat3 kInset = mat3(
      0.544814746488245, 0.140416948464053, 0.0888104196149096,
      0.373787398372697, 0.754137554567394, 0.178871756420858,
      0.0813978551390581, 0.105445496968552, 0.732317823964232);
  const mat3 kOutset = mat3(
      1.96488741169489, -0.299313364904742, -0.164352742528393,
      -0.855988495690215, 1.32639796461980, -0.238183969428088,
      -0.108898916004672, -0.0270845997150571, 1.40253671195648);
  vec3 x = kInset * max(color, vec3(0.0));
  vec3 s = x - kCrossover;
  vec3 slope_s = params.z * s;
  vec3 curve =
      slope_s * (1.0 + s / params.w) / (1.0 + slope_s / kShoulderMax) +
      kCrossover;
  if (any(lessThan(x, vec3(kCrossover)))) {
    vec3 p = pow(x, vec3(params.x));
    curve = mix(curve, p / (p + params.y), lessThan(x, vec3(kCrossover)));
  }
  return clamp(kOutset * min(curve, vec3(1.0)), 0.0, 1.0);
}

// The sRGB encode without pow(): within a third of an 8-bit step of the
// exact curve above its linear segment, which is kept exact.
vec3 LinearToSRGBFast(vec3 color) {
  vec3 s1 = sqrt(color);
  vec3 s2 = sqrt(s1);
  vec3 s3 = sqrt(s2);
  vec3 curve = 0.585122381 * s1 + 0.783140355 * s2 - 0.368262736 * s3;
  return mix(color * 12.92, curve, step(0.0031308, color));
}

void main() {
  highp vec2 uv =
      resolve_info.flip_y > 0.5 ? vec2(v_uv.x, 1.0 - v_uv.y) : v_uv;
  highp vec4 hdr = texture(scene_color, uv);
  float alpha = hdr.a;
  // The scene color is not pre-exposed: bring it into range in float32
  // before the mediump maths.
  highp vec3 exposed =
      (alpha > 0.0 ? hdr.rgb / alpha : vec3(0.0)) * resolve_info.exposure;
  vec3 color = min(exposed, vec3(1024.0));

  if (resolve_info.grading_enabled > 0.5) {
    // ApplyColorGrading without lift, gamma and gain, which ResolvePass
    // checks are neutral before choosing this shader.
    color *= vec3(1.0 + resolve_info.temperature * 0.2,
                  1.0 + resolve_info.tint * 0.2,
                  1.0 - resolve_info.temperature * 0.2) *
             resolve_info.brightness;
    const float kMidGray = 0.18;
    color = max((color - kMidGray) * resolve_info.contrast + kMidGray,
                vec3(0.0));
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, resolve_info.saturation);
  }

  vec3 mapped =
      LinearToSRGBFast(AgXFast(color, resolve_info.agx_params));
  frag_color = vec4(mapped * alpha, alpha);
}
