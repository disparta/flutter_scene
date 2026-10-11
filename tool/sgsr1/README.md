# SGSR 1 evaluation

`SceneUpscaling.sgsr1` is opt-in on Android, Windows and Linux. It lazily loads
`sgsr1.shaderbundle.json`, submits a 1→2 capability draw, then reconstructs
reduced screen views after the tone-map/display/AA chain. Native, supersampled
and offscreen views bypass it. Only successful reconstruction bypasses effects
marked `bypassWhenUpscaling`; allocation/encoding failure retries the legacy
chain, while an asynchronous submission failure disables future reconstruction.
FSR and SGSR have independent readiness and sticky failure state.

The standard Qualcomm mobile shader (not the edge-direction variant) is pinned
from SnapdragonGameStudios/snapdragon-gsr at
`d926f074bcb9d714e179f1ce0fcb9ee2eeb5074e`. The unmodified reference and BSD-3-Clause
license are in `packages/flutter_scene/shaders/sgsr1_mobile_reference.frag` and
`SGSR1_LICENSE.txt`. Defaults remain mode 1, threshold 8/255, sharpness 2.

Changes: Flutter stage I/O and uniform layout; explicit constant green gathers;
GLES 3.0 uses 12 shared explicit reads with clamped coordinates. Vulkan and Metal
retain four gathers. Every path uses one additional bilinear sample. RGB is
processed in premultiplied space, alpha stays bilinear, and output RGB is clamped
to [0, alpha]. This agrees with the opaque reference while preventing opaque
output and invalid premultiplication at transparent boundaries. It is not a
straight-colour reference algorithm for translucent pixels; inspect real edges.

Run `python3 tool/sgsr1/validate_macos.py /path/to/impellerc`. It compiles all four
bundles, audits generated sampling and precision, then compares 21 opaque GPU
fixtures against the independent pinned reference and tests alpha ramps, steps
and zero alpha. CPU alpha comparison permits 0.002 for hardware bilinear weight
quantization; RGB must never exceed the actual filtered alpha. CGL strips ES
precision qualifiers; Metal promotes mediump to float. Neither proves target
mobile precision or performance. Generated shaders remain in the output folder.

Run unit checks with `flutter test packages/flutter_scene/test/fsr1_test.dart`.
From `examples/smoke_render`, run
`flutter test integration_test/sgsr1_test.dart -d macos --enable-flutter-gpu`,
and repeat `fsr_test.dart`. Metal is a portability check; the test overrides the
platform gate. Shipping Apple/Web defaults are unchanged.

Frame stats include effective render scale and both dimensions. The allocation
counter is process-wide. CPU encode/pass timers are not GPU cost; pass attribution
requires an external GPU capture until Flutter GPU exposes timestamp queries.
