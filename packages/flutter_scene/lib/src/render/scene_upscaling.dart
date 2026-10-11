import 'dart:ui' show Size;

/// Spatial reconstruction of reduced screen views, after display colour/AA.
/// Native and supersampled views, and offscreen render textures, bypass it.
enum SceneUpscaling { none, fsr1 }

/// Frame dimensions shared by rendering, pacing, and allocation.
class SceneFrameSize {
  const SceneFrameSize(this.internal, this.output);
  factory SceneFrameSize.resolve({
    required Size logical,
    required double dpr,
    required double scale,
    double adaptiveScale = 1,
    required SceneUpscaling mode,
    required bool available,
  }) {
    // Preserve the original renderer's multiplication/rounding order.
    final effectiveScale = dpr * scale * adaptiveScale;
    final internal = Size(
      (logical.width * effectiveScale).ceilToDouble(),
      (logical.height * effectiveScale).ceilToDouble(),
    );
    final display = Size(
      (logical.width * dpr).ceilToDouble(),
      (logical.height * dpr).ceilToDouble(),
    );
    final reduced =
        internal.width > 0 &&
        internal.height > 0 &&
        internal.width <= display.width &&
        internal.height <= display.height &&
        internal != display;
    return SceneFrameSize(
      internal,
      mode == SceneUpscaling.fsr1 && available && reduced ? display : internal,
    );
  }
  final Size internal;
  final Size output;
  bool get upscaling => internal != output;
}
