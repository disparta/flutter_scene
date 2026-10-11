# Optional FSR 1 reconstruction

`scene.upscaling = SceneUpscaling.fsr1` requests spatial reconstruction on
native Android (including TV), Windows and Linux. The default is `none`.
`Scene.initializeFsr1Resources()` optionally awaits readiness;
`Scene.fsr1Available` and `Scene.fsr1Failure` report capability status.
Initialization is lazy, single flight, and failure is sticky for the process.
The separate `fsr1` bundle, vertex buffer, pipelines and tiny capability draws
are created only when requested. Missing bundles, unsupported platforms,
allocation/pipeline errors or unsuccessful GPU submissions disable FSR and
report once. Failed synchronous FSR frames retry the existing rendering path;
asynchronous GPU failure uses it on the next frame. A failed graph capture
reports an error so a caller can recapture the fallback frame.

Screen views retain their existing geometry, lighting, effects, tone mapping
and anti-aliasing dimensions. FSR runs only when the integer internal dimensions
are smaller than physical display dimensions (including viewport and DPR).
Render textures, native-resolution and supersampled screen frames bypass it.
EASU reconstructs the final display-color image into a physical-display-sized
RGBA8 target; RCAS writes the equally sized swapchain at 0.5 stops attenuation.
Flutter composites UI afterward. No additional resolution multiplier is applied
at presentation. No frame-rate, adaptive-quality or resolution budget changes.

Custom sharpening effects should set `PostEffect.bypassWhenUpscaling = true`.
The graph skips those effects only when FSR actually executes: bypassed or
failed FSR frames retain their previous effects. Anti-aliasing selection is
unchanged. The built-in display chain and outlines run before reconstruction.

Shaders use the unmodified FP32 algorithms from AMD FidelityFX FSR 1.0.2,
revision `a21ffb8f6c13233ba336352bdff293894c706575`. The headers retain their
MIT license; `shaders/FSR1_LICENSE.txt` supplies standalone attribution.
The wrappers implement EASU gather callbacks using explicit level-zero,
clamped texel reads. No compute, FP16 or texture-gather support is required.
Premultiplied scene RGB is unpremultiplied for reconstruction/sharpening;
alpha is bilinearly reconstructed in EASU and copied, never sharpened, by RCAS.
Each output is repremultiplied for Flutter compositing.

Surface working sets are keyed by both internal and output dimensions and
keep two recent size pairs. Repeated frames reuse the display-sized image
only when both sizes match. A resize, DPR change or adaptive-size change gets
a matching working set. Capture `pixelWidth/pixelHeight` and view stats
`width/height` remain internal sizes; their new `outputWidth/outputHeight`
fields describe presentation. Old serialized captures default output to internal.

## Validation

From `packages/flutter_scene`:

```sh
flutter test test/fsr1_test.dart test/render_stats_test.dart \
  test/render_graph_observer_test.dart test/post_process_test.dart
```

From `examples/smoke_render`:

```sh
flutter test integration_test/fsr_test.dart -d macos --enable-flutter-gpu
```

The integration test can also run on the three native target platforms. On
macOS it overrides platform eligibility just for resource initialization,
exercising portable shaders on Metal. Shipping Apple rendering remains unchanged.
It covers pass order, legacy-effect restoration, internal/output dimensions,
resize/DPR, changing render scale, bounded resource reuse, repeated-frame
presentation and injected resource failure.

From the repository root on macOS:

```sh
python3 tool/fsr1/validate_macos.py /path/to/flutter/bin/cache/artifacts/engine/darwin-x64/impellerc
```

This compiles Vulkan, GLES 3.0, Metal desktop and Metal iOS bundles, then uses
CGL on the host GPU to compare explicit-texel EASU with AMD's hardware-gather
reference callbacks. Fifteen combinations exercise diagonal edges, checkerboards,
color ramps, all-black/all-white values and clamped boundaries; transparent
ramps verify bilinear alpha, premultiplication and unchanged RCAS alpha.
The RCAS comparison also uses AMD's reference constant setup at 0.5 stops.
On Apple M4 Pro the maximum EASU reference error was 2.98e-7 per channel;
after RCAS it was 5.37e-7.
This is shader correctness evidence, not a Windows/Linux/Android performance result.

The portable EASU callbacks share each RGBA texel across the reference's R/G/B
callbacks (which are ordered by the pinned AMD header). This reduces the
compiled GLES shader from 37 to 13 texel reads without changing reference
output. The conformance tool checks the compiled read count as well as pixels.
This optimization was prompted by Pixel 6 thermal/performance testing; target
hardware acceptance remains the application's release responsibility.
