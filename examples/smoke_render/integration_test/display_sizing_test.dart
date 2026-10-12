// Metal is a portability smoke test; target-hardware acceptance is separate.
// Pool reuse is intentionally inspected by this renderer integration test.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
// ignore: implementation_imports
import 'package:flutter_scene/src/render/frame_transients.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:smoke_render/smoke_scenes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('scaled presentation, post effects, resizing, reuse and pacing', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    await tester.pump();
    await Scene.initializeStaticResources();
    final setup = kSmokeScenes.first.setup();
    final scene = setup.scene
      ..renderScale = .5
      ..antiAliasingMode = AntiAliasingMode.fxaa
      ..maxGpuFramesInFlight = 0;
    scene.renderQuality.adaptive = false;
    final library = await gpu.loadShaderLibraryAsync(
      await gpu.resolveShaderBundleKey('smoke'),
    );
    final displayEffect = PostEffect(
      insertion: PostInsertion.afterTonemap,
      fragmentShader: library!['DisplayProbeFragment']!,
    );
    scene.postProcess.customEffects.add(displayEffect);
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
      [96, 64, 96, 64],
    );
    final names = frame.passes.map((p) => p.name).toList();
    expect(names.sublist(names.length - 2), ['FxaaPass', 'PostEffectPass']);
    expect(scene.surface.lastSwapchainColorTexture()!.width, 96);
    expect(
      takeMemoryReport().categories
          .firstWhere((c) => c.name == 'presentation textures')
          .bytes,
      greaterThanOrEqualTo(96 * 64 * 4),
    );
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
    expect(scene.surface.lastSwapchainColorTexture()!.width, 135);
    scene.renderScale = .5;
    draw();
    expect(identical(poolA, scene.surface.transientTexturePool()), isTrue);
    frame = await capture(dpr: 1, width: 120);
    expect(
      [frame.pixelWidth, frame.outputWidth, frame.outputHeight],
      [60, 60, 32],
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
    }
  });
}
