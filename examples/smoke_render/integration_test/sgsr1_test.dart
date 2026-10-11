// Metal is a portability smoke test; target-hardware acceptance is separate.
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/render/frame_transients.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/render_graph.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/sgsr1_pass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:smoke_render/smoke_scenes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('SGSR graph, presentation, resizing, reuse and fallback', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    await tester.pump();
    await Scene.initializeStaticResources();
    expect(Scene.sgsr1Available, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final ready = await Scene.initializeSgsr1Resources();
    debugDefaultTargetPlatformOverride = null;
    expect(ready, isTrue, reason: '${Scene.sgsr1Failure}');
    final setup = kSmokeScenes.first.setup();
    final scene = setup.scene
      ..renderScale = .5
      ..antiAliasingMode = AntiAliasingMode.fxaa
      ..maxGpuFramesInFlight = 0;
    scene.renderQuality.adaptive = false;
    final library = await gpu.loadShaderLibraryAsync(
      await gpu.resolveShaderBundleKey('smoke'),
    );
    final legacy = PostEffect(
      insertion: PostInsertion.afterTonemap,
      fragmentShader: library!['FsrLegacyProbeFragment']!,
      bypassWhenUpscaling: true,
    );
    scene.postProcess.customEffects.add(legacy);
    scene.upscaling = SceneUpscaling.sgsr1;
    Scene.debugAllowRenderGraphCapture = true;
    addTearDown(() => Scene.debugAllowRenderGraphCapture = false);
    void draw({double dpr = 2, double width = 96}) {
      final recorder = ui.PictureRecorder();
      scene.render(
        setup.camera,
        ui.Canvas(recorder),
        viewport: ui.Rect.fromLTWH(0, 0, width, 64),
        pixelRatio: dpr,
      );
      recorder.endRecording().dispose();
    }

    Future<RenderGraphCaptureResult> capture({
      double dpr = 2,
      double width = 96,
    }) async {
      final next = scene.captureRenderGraph(
        request: const RenderGraphCaptureRequest(captureImages: false),
      );
      draw(dpr: dpr, width: width);
      return next;
    }

    var frame = await capture();
    expect(
      [
        frame.pixelWidth,
        frame.pixelHeight,
        frame.outputWidth,
        frame.outputHeight,
      ],
      [96, 64, 192, 128],
    );
    final names = frame.passes.map((p) => p.name).toList();
    expect(names.last, 'Sgsr1Pass');
    expect(names.where((n) => n == 'Sgsr1Pass'), hasLength(1));
    expect(names, isNot(contains('FsrEasuPass')));
    expect(names.indexOf('FxaaPass'), lessThan(names.indexOf('Sgsr1Pass')));
    expect(names, isNot(contains('PostEffectPass')));
    expect(scene.surface.lastSwapchainColorTexture()!.width, 192);
    draw();
    draw();
    final allocated = TransientTexturePool.texturesCreated;
    draw();
    draw();
    expect(TransientTexturePool.texturesCreated, allocated);
    final poolA = scene.surface.transientTexturePool();
    scene.renderScale = .7;
    draw();
    expect(identical(poolA, scene.surface.transientTexturePool()), isFalse);
    expect(scene.surface.lastSwapchainColorTexture()!.width, 192);
    scene.renderScale = .5;
    draw();
    expect(identical(poolA, scene.surface.transientTexturePool()), isTrue);
    frame = await capture(dpr: 1, width: 120);
    expect(
      [frame.pixelWidth, frame.outputWidth, frame.outputHeight],
      [60, 120, 64],
    );
    final pending = rendererSubmissions.record();
    rendererSubmissions.endFrame();
    scene.maxGpuFramesInFlight = 1;
    final previous = scene.surface.lastSwapchainColorTexture();
    draw(dpr: 1, width: 120);
    expect(
      identical(scene.surface.lastSwapchainColorTexture(), previous),
      isTrue,
    );
    rendererSubmissions.complete(pending);
    scene.maxGpuFramesInFlight = 0;
    for (final scale in [1.0, 1.25]) {
      scene.renderScale = scale;
      frame = await capture();
      expect(frame.outputWidth, frame.pixelWidth);
      expect(
        frame.passes.where((p) => p.name == 'PostEffectPass'),
        hasLength(1),
      );
      expect(frame.passes.map((p) => p.name), isNot(contains('Sgsr1Pass')));
    }
    scene.renderScale = .5;
    scene.upscaling = SceneUpscaling.none;
    frame = await capture();
    expect(frame.outputWidth, 96);
    expect(frame.passes.where((p) => p.name == 'PostEffectPass'), hasLength(1));
    expect(frame.passes.map((p) => p.name), isNot(contains('Sgsr1Pass')));
    // FSR remains independently usable after an SGSR failure.
    final fsrFailure = Scene.fsr1Failure;
    scene.upscaling = SceneUpscaling.sgsr1;
    // Simulate a resource disappearing after readiness: execution must retry
    // a complete legacy frame, including sharpening, in the same call.
    Sgsr1Resources.fragment = null;
    draw();
    expect(Scene.sgsr1Available, isFalse);
    expect(Scene.sgsr1Failure, isNotNull);
    frame = await capture();
    expect(frame.outputWidth, 96);
    expect(frame.passes.where((p) => p.name == 'PostEffectPass'), hasLength(1));
    expect(frame.passes.map((p) => p.name), isNot(contains('Sgsr1Pass')));
    expect(Scene.fsr1Failure, same(fsrFailure));
  });
}
