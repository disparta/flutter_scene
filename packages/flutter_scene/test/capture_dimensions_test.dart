import 'package:flutter_scene/src/render/render_graph_capture.dart';
import 'package:flutter_scene/src/render/render_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
