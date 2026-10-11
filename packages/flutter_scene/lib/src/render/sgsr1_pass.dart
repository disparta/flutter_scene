import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import '../generated_assets/generated_asset_lookup.dart';
import '../generated_assets/generated_assets.dart';
import '../gpu/raster_sync.dart';
import '../scene_encoder.dart' show resolvePipeline;
import 'frame_transients.dart';
import 'render_graph.dart';
import 'resolve_pass.dart';
import 'scene_upscaling.dart';

/// Lazy, optional resources: failure is sticky and reported once per process.
class Sgsr1Resources {
  static Future<bool>? _loading;
  static gpu.Shader? vertex, fragment;
  static gpu.BufferView? quad;
  static Object? failure;
  static bool _ready = false;
  static bool get available => _ready && failure == null;
  static bool get supported =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  static Future<bool> initialize() async {
    await (_loading ??= _initialize());
    return available;
  }

  static Future<bool> _initialize() async {
    try {
      if (!supported) {
        throw UnsupportedError(
          'SGSR 1 requires native Android, Windows or Linux',
        );
      }
      final key = (await loadGeneratedAssetIndex()).resolveFirstKey(
        GeneratedAssetFamily.shaderBundle,
        'sgsr1',
        package: 'flutter_scene',
      );
      if (key == null) throw StateError('SGSR 1 shader bundle is missing');
      final library = await gpu.loadShaderLibraryAsync(key);
      vertex = library?['SgsrVertex'];
      fragment = library?['SgsrFragment'];
      if (vertex == null || fragment == null) {
        throw StateError('SGSR 1 shader bundle is missing required stages');
      }
      // Build the pipeline up front; an unsupported backend keeps the
      // legacy display chain. Allocations at the real size are guarded too.
      await awaitRasterThread();
      resolvePipeline(vertex!, fragment!);
      final buffer = gpu.gpuContext.createDeviceBufferWithCopy(
        ByteData.sublistView(
          Float32List.fromList([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
        ),
      );
      quad = gpu.BufferView(buffer, offsetInBytes: 0, lengthInBytes: 48);
      // Capability check includes real draw submission, not just shader
      // lookup: some drivers reject a pipeline only at the first draw.
      gpu.Texture target(int size) => gpu.gpuContext.createTexture(
        gpu.StorageMode.devicePrivate,
        size,
        size,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
        enableRenderTargetUsage: true,
        enableShaderReadUsage: true,
      );
      final input = target(1);
      final clear = gpu.gpuContext.createCommandBuffer();
      clear.createRenderPass(
        gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: input)),
      );
      rendererSubmissions.submit(clear);
      final board = Blackboard()..set(kDisplayColorBlackboardKey, input);
      final context = RenderGraphContext(
        transientsBuffer: uniformTransients,
        texturePool: TransientTexturePool(),
        blackboard: board,
      );
      final done = Completer<bool>();
      Sgsr1Pass(output: target(2), onComplete: done.complete).execute(context);
      if (!await done.future.timeout(const Duration(seconds: 5))) {
        throw StateError('SGSR 1 capability draw failed');
      }
      _ready = failure == null;
      return _ready;
    } catch (error) {
      disable(error);
      return false;
    }
  }

  static void disable(Object error) {
    if (failure != null) return;
    failure = error;
    debugPrint(
      'Flutter Scene: SGSR 1 unavailable; retaining existing rendering: $error',
    );
  }
}

/// Standard mobile SGSR 1: reconstruction and sharpening in one display pass.
class Sgsr1Pass extends RenderGraphPass {
  Sgsr1Pass({required this.output, this.onComplete});
  final void Function(bool)? onComplete;
  final gpu.Texture output;
  @override
  String get name => 'Sgsr1Pass';
  @override
  void execute(RenderGraphContext context) {
    try {
      _execute(context);
    } catch (error) {
      throw UpscalingException(error);
    }
  }

  void _execute(RenderGraphContext context) {
    final input = context.blackboard.require<gpu.Texture>(
      kDisplayColorBlackboardKey,
    );
    final shader = Sgsr1Resources.fragment!;
    final command = gpu.gpuContext.createCommandBuffer();
    final pass = command.createRenderPass(
      gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: output)),
    );
    pass.bindPipeline(resolvePipeline(Sgsr1Resources.vertex!, shader));
    bindVertexBufferCompat(pass, Sgsr1Resources.quad!, 6);
    pass.bindTexture(
      shader.getUniformSlot('input_color'),
      input,
      sampler: gpu.SamplerOptions(
        minFilter: gpu.MinMagFilter.linear,
        magFilter: gpu.MinMagFilter.linear,
        widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
        heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
      ),
    );
    pass.bindUniform(
      shader.getUniformSlot('SgsrInfo'),
      context.transientsBuffer.emplace(
        ByteData.sublistView(
          Float32List.fromList([
            input.width.toDouble(),
            input.height.toDouble(),
            output.width.toDouble(),
            output.height.toDouble(),
          ]),
        ),
      ),
    );
    drawCompat(pass, 6);
    rendererSubmissions.submit(
      command,
      onComplete: (success) {
        if (!success) {
          Sgsr1Resources.disable(StateError('$name GPU submission failed'));
        }
        onComplete?.call(success);
      },
    );
    context.blackboard.set(kDisplayColorBlackboardKey, output);
  }
}
