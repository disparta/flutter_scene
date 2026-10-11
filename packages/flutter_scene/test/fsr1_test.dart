import 'dart:ui';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/scene_upscaling.dart';
import 'package:flutter_scene/src/render/render_graph_capture.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_test/flutter_test.dart';

enum _Status { successful, error }

void main() {
  test('GPU completion works on native and web backends', () {
    expect(gpuSubmissionSucceeded(true), isTrue);
    expect(gpuSubmissionSucceeded(false), isFalse);
    expect(gpuSubmissionSucceeded(_Status.successful), isTrue);
    expect(gpuSubmissionSucceeded(_Status.error), isFalse);
  });
  SceneFrameSize size(
    double scale, {
    double dpr = 2,
    bool available = true,
    SceneUpscaling mode = SceneUpscaling.fsr1,
    Size logical = const Size(800, 450),
  }) => SceneFrameSize.resolve(
    logical: logical,
    dpr: dpr,
    scale: scale,
    mode: mode,
    available: available,
  );

  test(
    'FSR reconstructs physical pixels without changing internal resolution',
    () {
      expect(size(.7).internal, const Size(1120, 630));
      expect(size(.7).output, const Size(1600, 900));
      expect(size(.7).upscaling, isTrue);
      for (final scale in [.5, .7, 1.0, 1.25]) {
        final disabled = size(scale, mode: SceneUpscaling.none);
        expect(disabled.output, disabled.internal);
        expect(size(scale, available: false).output, disabled.output);
      }
    },
  );
  test('SGSR shares size policy, native bypass and unavailable fallback', () {
    for (final logical in [
      const Size(800, 450),
      const Size(391, 853),
      Size.zero,
    ]) {
      for (final scale in [.5, .7, .99999, 1.0, 1.25]) {
        for (final available in [true, false]) {
          final fsr = size(scale, logical: logical, available: available);
          final sgsr = size(
            scale,
            logical: logical,
            available: available,
            mode: SceneUpscaling.sgsr1,
          );
          expect(sgsr.internal, fsr.internal);
          expect(sgsr.output, fsr.output);
        }
      }
    }
  });
  test('disabled adaptive frames retain original resolution rounding', () {
    const logical = Size(391, 853);
    for (final dpr in [1.0, 1.25, 2.0, 3.0]) {
      for (final scale in [.65, .7, 1.0]) {
        for (final adaptive in [.7, .85, 1.0]) {
          final frame = SceneFrameSize.resolve(
            logical: logical,
            dpr: dpr,
            scale: scale,
            adaptiveScale: adaptive,
            mode: SceneUpscaling.none,
            available: true,
          );
          final original = dpr * scale * adaptive;
          expect(
            frame.internal,
            Size(
              (logical.width * original).ceilToDouble(),
              (logical.height * original).ceilToDouble(),
            ),
          );
          expect(frame.output, frame.internal);
        }
      }
    }
  });
  test('native/supersampled/rounded-native frames bypass FSR', () {
    expect(size(1).upscaling, isFalse);
    expect(size(1.25).output, const Size(2000, 1125));
    expect(size(.99999).upscaling, isFalse);
    expect(size(.5, logical: Size.zero).upscaling, isFalse);
  });
  test('resize, DPI and adaptive scale derive independent dimensions', () {
    expect(size(.7, dpr: 1).output, const Size(800, 450));
    expect(size(.7, dpr: 1).internal, const Size(560, 315));
    expect(size(.5).output, size(.7).output);
    expect(size(.5).internal, isNot(size(.7).internal));
    expect(
      size(.7, logical: const Size(401, 225)).output,
      const Size(802, 450),
    );
    expect(
      size(.7, logical: const Size(401, 225)).internal,
      const Size(562, 315),
    );
  });
  test(
    'capture round trips both sizes and reads historical captures',
    () async {
      final capture = RenderGraphCaptureResult(
        passes: [],
        resources: [],
        pixelWidth: 1120,
        pixelHeight: 630,
        outputWidth: 1600,
        outputHeight: 900,
      );
      final copy = RenderGraphCaptureResult.fromJson(
        await capture.toJson(includeImages: false),
      );
      expect(
        [
          copy.pixelWidth,
          copy.pixelHeight,
          copy.outputWidth,
          copy.outputHeight,
        ],
        [1120, 630, 1600, 900],
      );
      final legacy = RenderGraphCaptureResult.fromJson({
        'pixelWidth': 640,
        'pixelHeight': 480,
      });
      expect([legacy.outputWidth, legacy.outputHeight], [640, 480]);
    },
  );
  test(
    'frame stats retain internal dimensions alongside presentation size',
    () {
      final stats = RenderStats()..beginFrame();
      final view = stats.beginView(
        viewIndex: 0,
        width: 1120,
        height: 630,
        outputWidth: 1600,
        outputHeight: 900,
        offscreen: false,
      )!;
      expect(view.toJson(), containsPair('width', 1120));
      expect(view.toJson(), containsPair('outputWidth', 1600));
    },
  );
}
