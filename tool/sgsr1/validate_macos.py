#!/usr/bin/env python3
"""Compile every bundle backend; audit generated sampling/precision; compare
standard mobile SGSR 1 to Qualcomm's pinned unmodified algorithm on macOS CGL.
This does not validate mobile mediump precision or target-driver performance.
Usage: python3 tool/sgsr1/validate_macos.py /path/to/impellerc [output-directory]
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
package = root / 'packages/flutter_scene'
shaders = package / 'shaders'
compiler = sys.argv[1]
tmp = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/sgsr1-conformance')
tmp.mkdir(parents=True, exist_ok=True)
manifest = (shaders / 'sgsr1.shaderbundle.json').read_text()
source = shaders / 'flutter_scene_sgsr1.frag'
for backend, define in [('vulkan', 'VULKAN'), ('opengl-es', 'OPENGLES'),
                        ('metal-desktop', 'METAL'), ('metal-ios', 'METAL')]:
    subprocess.run([compiler, '--'+backend, '--gles-language-version=300',
        '--shader-bundle='+manifest, '--include='+str(shaders),
        '--sl='+str(tmp/(backend+'.bundle'))], cwd=package, check=True)
    output = tmp/(backend+'.shader')
    subprocess.run([compiler, '--'+backend, '--gles-language-version=300',
        '--define=IMPELLER_TARGET_'+define, '--input='+str(source),
        '--input-type=frag', '--sl='+str(output),
        '--spirv='+str(tmp/(backend+'.spv'))], check=True)
    text = output.read_text() if backend != 'vulkan' else ''
    if backend == 'opengl-es':
        assert text.count('texelFetch(') == 12, 'duplicated or missing texel reads'
        assert text.count('textureLod(') == 1
        assert 'textureGather(' not in text
        assert 'precision mediump float;' in text and 'highp vec2' in text
        print('GLES 3.0: 12 texel reads + 1 bilinear read; mediump arithmetic/highp coordinates')
    elif define == 'METAL':
        assert text.count('.gather(') == 4 and text.count('.sample(') == 1
        assert text.count('.read(') == 0
        assert 'texture2d<float>' in text
        print(backend+': 4 gathers + 1 bilinear read; compiler promotes mediump to float')
    print('Compiled', backend, flush=True)

# Reference algorithm stays unchanged. Only adapt stage I/O/uniform layout.
reference = (shaders/'sgsr1_mobile_reference.frag').read_text()
reference = reference.replace('#version 300 es', '')
a = reference.index('#if defined(UseUniformBlock)')
b = reference.index('float fastLanczos2')
reference = reference[:a]+'''uniform SgsrInfo { highp vec2 input_size; highp vec2 output_size; } sgsr;
uniform mediump sampler2D input_color;
in highp vec2 v_uv;
out vec4 frag_color;
'''+reference[b:]
reference = reference.replace('ViewportInfo[0]', 'vec4(1.0/sgsr.input_size,sgsr.input_size)')
# Make the mode a GLSL constant and remove invalid constructor qualifiers;
# neither changes the reference arithmetic or sampling.
reference = reference.replace('int mode = OperationMode;', 'const int mode = OperationMode;').replace('highp vec2(', 'vec2(')
reference = reference.replace('ps0','input_color').replace('in_TEXCOORD0','vec4(v_uv,0.0,0.0)').replace('out_Target0','frag_color')
(tmp/'reference.frag').write_text(reference)
paths = [source, source, tmp/'reference.frag']
glsl = []
for index, path in enumerate(paths):
    out = tmp/f'{index}.glsl'
    subprocess.run([compiler, '--opengl-es', '--gles-language-version=310',
        *(['--define=SGSR_TEST_GATHER'] if index == 1 else []),
        '--input='+str(path), '--input-type=frag', '--sl='+str(out),
        '--spirv='+str(tmp/f'{index}.spv')], check=True)
    text = out.read_text().replace('#version 310 es','#version 410 core')
    text = re.sub(r'precision \w+ \w+;','',text)
    text = re.sub(r'\b(highp|mediump|lowp)\b','',text)
    text = re.sub(r'layout\(binding = \d+, std140\)', 'layout(std140)',text)
    text = re.sub(r'layout\((binding|location) = \d+\)', '',text)
    out.write_text(text)
    glsl.append(str(out))
binary = tmp/'check'
subprocess.run(['clang++','-std=c++17','-Wno-deprecated-declarations',
    str(root/'tool/sgsr1/validate_macos.cc'),'-framework','OpenGL','-o',str(binary)],check=True)
subprocess.run([str(binary),*glsl],check=True)
