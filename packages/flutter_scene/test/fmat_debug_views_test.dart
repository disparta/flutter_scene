// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/build_materials.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/fmat/fmat_emitter.dart';
import 'package:flutter_scene/scene.dart' show DirectionalShadowFilter;
import 'package:flutter_test/flutter_test.dart';

const _lit = '''
material {
  name: "Plain",
  shading_model: lit,
  environment_lighting: false,
  parameters: [
    { type: float, name: gain, default: 1.0 },
  ],
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(vec3(material_params.gain), 1.0);
  }
}
''';

const _unlit = '''
material {
  name: "Flat",
  shading_model: unlit,
}

fragment {
  void Surface(inout MaterialInputs material) {
    material.base_color = vec4(0.5, 0.5, 0.5, 1.0);
  }
}
''';

void main() {
  test('entries carry the surface debug views by default', () {
    for (final source in [_lit, _unlit]) {
      final compiled = compileFmat(source, fileName: 'material.fmat');
      final variants = emitFragmentShaderVariants(
        compiled,
        generateShadowVariant: true,
      );
      for (final glsl in variants.values) {
        expect(glsl, contains('#include <material_debug.glsl>'));
        expect(glsl, contains('DebugViewMode()'));
      }
      expect(compiled.sidecar.containsKey('debug_views'), isFalse);
    }
  });

  test('debugViews: false leaves the views out of every entry', () {
    for (final source in [_lit, _unlit]) {
      final compiled = compileFmat(source, fileName: 'material.fmat');
      final variants = emitFragmentShaderVariants(
        compiled,
        generateShadowVariant: true,
        debugViews: false,
      );
      for (final glsl in variants.values) {
        expect(glsl, contains('#define $kNoDebugViewsDefine'));
        expect(glsl, isNot(contains('material_debug.glsl')));
        expect(glsl, isNot(contains('DebugView')));
        expect(glsl, contains('frag_color = MaterialOutput(material);'));
      }
      expect(
        buildSidecar(compiled.material, debugViews: false)['debug_views'],
        isFalse,
      );
    }
  });

  test('a lit material gets a no-shadow entry and a Shadow twin', () {
    final compiled = compileFmat(_lit, fileName: 'plain.fmat');
    final variants = emitFragmentShaderVariants(
      compiled,
      generateShadowVariant: true,
      debugViews: false,
    );
    expect(variants.keys, unorderedEquals(['Plain', 'PlainShadow']));
    expect(variants['Plain'], contains('#define FLUTTER_SCENE_SKIP_SHADOWS'));
    expect(
      variants['PlainShadow'],
      isNot(contains('#define FLUTTER_SCENE_SKIP_SHADOWS')),
    );
    // Without the variants one entry serves both, shadow sampling included.
    final single = emitFragmentShaderVariants(
      compiled,
      generateShadowVariant: false,
    );
    expect(single.keys, ['Plain']);
    expect(
      single['Plain'],
      isNot(contains('#define FLUTTER_SCENE_SKIP_SHADOWS')),
    );
  });

  test(
    'shadow specialization reaches only the entries that sample shadows',
    () {
      final compiled = compileFmat(_lit, fileName: 'plain.fmat');
      final filter = '$kShadowFilterDefine ${shadowFilterIndex('bilinearPcf')}';
      final variants = emitFragmentShaderVariants(
        compiled,
        generateShadowVariant: true,
        shadowDefines: [filter, '$kShadowCascadesDefine 1'],
      );
      expect(variants['PlainShadow'], contains('#define $filter'));
      expect(
        variants['PlainShadow'],
        contains('#define $kShadowCascadesDefine 1'),
      );
      expect(variants['Plain'], isNot(contains(kShadowFilterDefine)));
    },
  );

  test('the hook-side filter names follow the enum', () {
    expect(kDirectionalShadowFilterNames, [
      for (final filter in DirectionalShadowFilter.values) filter.name,
    ]);
    expect(
      shadowFilterIndex('bilinear'),
      DirectionalShadowFilter.bilinear.index,
    );
    expect(() => shadowFilterIndex('soft'), throwsArgumentError);
  });
}
