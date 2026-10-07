#!/usr/bin/env python3
"""The JPEG-LS adapter retains its public API and keeps codec symbols local on both slices."""
import private_tmpdir  # noqa: F401
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
execution_unavailable = False


def run(*arguments):
    return subprocess.check_output(list(arguments), text=True)


with tempfile.TemporaryDirectory(prefix='horos-jpegls-isolation-test-') as temporary:
    base = Path(temporary)
    (base / 'codec.cc').write_text(
        'template<class T> T codecValue(T value) { return value + 1; }\n'
        'extern "C" int JpegLsDecode() { return codecValue(41); }\n')
    (base / 'adapter.cc').write_text(
        'extern "C" int JpegLsDecode();\n'
        'extern "C" int adapterDecode() { return JpegLsDecode(); }\n')
    (base / 'main.cc').write_text(
        'extern "C" int adapterDecode();\n'
        'int main() { return adapterDecode() == 42 ? 0 : 1; }\n')
    for architecture in ('arm64', 'x86_64'):
        directory = base / architecture
        directory.mkdir()
        for name, archive in (('codec', 'libdcmtkcharls.a'), ('adapter', 'libdcmjpls.a')):
            object_file = directory / (name + '.o')
            run('xcrun', 'clang++', '-arch', architecture, '-mmacosx-version-min=26.0',
                '-O0', '-c', str(base / (name + '.cc')), '-o', str(object_file))
            run('xcrun', 'libtool', '-static', '-o', str(directory / archive), str(object_file))
        run(sys.executable, str(ROOT / 'tools/isolate-dcmtk-jpegls.py'), str(directory),
            '--architecture', architecture, '--deployment', '26.0')
        isolated = directory / 'libhorosdcmjpls.a'
        assert run('lipo', '-archs', str(isolated)).strip() == architecture
        symbols = run('xcrun', 'nm', '-g', str(isolated))
        assert '_adapterDecode' in symbols
        assert '_JpegLsDecode' not in symbols and 'codecValue' not in symbols
        executable = directory / 'decode'
        run('xcrun', 'clang++', '-arch', architecture, '-mmacosx-version-min=26.0',
            str(base / 'main.cc'), str(isolated), '-o', str(executable))
        try:
            result = subprocess.run([str(executable)], capture_output=True, text=True)
        except OSError as error:
            if architecture != 'x86_64' or error.errno != 86:
                raise
            execution_unavailable = True
            print('x86_64 execution unavailable: Rosetta is required on Apple Silicon')
        else:
            assert result.returncode == 0, (architecture, result.stderr)
            print('PASS:', architecture, 'adapter decodes through its private codec')

print('PASS: both slices preserve the adapter API and hide C and C++ codec symbols')
if execution_unavailable:
    raise SystemExit(2)
