#!/usr/bin/env python3
"""Compile Vulkan/GLES bundles and compare FP32 EASU to AMD's gather reference.
macOS CGL is a local shader correctness check, not target-driver acceptance.
Usage: python3 tool/fsr1/validate_macos.py /path/to/impellerc
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
package = root / 'packages/flutter_scene'
shaders = package / 'shaders'
compiler = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='fsr-conformance-') as directory:
    tmp = Path(directory)
    manifest = (shaders / 'fsr1.shaderbundle.json').read_text()
    for backend in ['vulkan', 'opengl-es', 'metal-desktop', 'metal-ios']:
        subprocess.run([compiler, '--'+backend, '--gles-language-version=300',
            '--shader-bundle='+manifest, '--include='+str(shaders),
            '--sl='+str(tmp/(backend+'.bundle'))], cwd=package, check=True)
        print('Compiled', backend, flush=True)
    source = (shaders/'flutter_scene_fsr_easu.frag').read_text()
    # AMD's documented callback implementation, on an opaque fixture. Uses
    # hardware gathers to independently check the portable texel addressing.
    reference = re.sub(r'AF4 FsrEasu([RGB])F\(AF2 p\) \{[^}]*\}',
        lambda m: 'AF4 FsrEasu'+m[1]+'F(AF2 p) { return textureGather(input_color,p,'+
        str('RGB'.index(m[1]))+'); }', source)
    (tmp/'reference.frag').write_text(reference)
    rcas_reference = (shaders/'flutter_scene_fsr_rcas.frag').read_text().replace(
        'uvec4 con = uvec4(floatBitsToUint(exp2(-0.5)),0u,0u,0u);',
        'uvec4 con; FsrRcasCon(con, 0.5);')
    (tmp/'rcas_reference.frag').write_text(rcas_reference)
    paths = [shaders/'flutter_scene_fsr_easu.frag', tmp/'reference.frag',
             shaders/'flutter_scene_fsr_rcas.frag', tmp/'rcas_reference.frag']
    glsl = []
    for index, path in enumerate(paths):
        out = tmp/f'{index}.glsl'
        subprocess.run([compiler,'--opengl-es','--gles-language-version=310',
            '--input='+str(path),'--input-type=frag','--include='+str(shaders),
            '--sl='+str(out),'--spirv='+str(tmp/f'{index}.spv')],check=True)
        # CGL supports desktop 4.1. Remove ES precision/interface decorations;
        # retain all generated shader arithmetic and texture instructions.
        text = out.read_text().replace('#version 310 es','#version 410 core')
        if index == 0:
            reads = text.count('texelFetch(')
            assert reads <= 16, f'EASU RGB samples duplicated: {reads} texel reads'
            assert 'textureGather(' not in text
            print('Portable EASU texel reads:', reads, flush=True)
        text = re.sub(r'precision \w+ \w+;','',text)
        text = re.sub(r'\b(highp|mediump|lowp)\b','',text)
        text = re.sub(r'layout\(binding = \d+, std140\)', 'layout(std140)',text)
        text = re.sub(r'layout\((binding|location) = \d+\)', '',text)
        out.write_text(text)
        glsl.append(str(out))
    binary = tmp/'check'
    subprocess.run(['clang++','-std=c++17','-Wno-deprecated-declarations',
        str(root/'tool/fsr1/validate_macos.cc'),'-framework','OpenGL','-o',str(binary)],check=True)
    subprocess.run([str(binary),*glsl],check=True)
