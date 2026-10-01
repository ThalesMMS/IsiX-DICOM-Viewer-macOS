#!/usr/bin/env python3
"""Run malformed files through the shipped parser and a sanitized upstream build."""
from pathlib import Path
import os
import re
import resource
import signal
import subprocess
import sys
import tempfile
from dcmtk_build import ROOT, dcmtk_flags

# Reuse installed upstream archives without sharing mutable build outputs.
# A worker may snapshot a verified installation into its own build directory.
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--shipped-only', action='store_true', help='leave the heavy sanitizer build to integration')
arguments = parser.parse_args()
flags = dcmtk_flags()
source = ROOT / 'DCMTK'
driver = ROOT / 'tools/exercise-dicom-parser.cc'
assert '-DDCMTK_MAX_SEQUENCE_NESTING=16' in (ROOT / 'Horos/Scripts/DCMTK/CMake.sh').read_text()


def checked(command, **kwargs):
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode:
        print((result.stdout + result.stderr).decode('latin1')[-5000:])
        raise SystemExit(1)
    return result


with tempfile.TemporaryDirectory(prefix='horos-parser-') as directory:
    directory = Path(directory)
    corpus = directory / 'corpus'
    checked([sys.executable, str(ROOT / 'tools/generate-malformed-dicom-fixture.py'), str(corpus), '--deflated'])
    files = sorted(str(path) for path in corpus.glob('*.dcm'))
    shipped = directory / 'shipped'
    checked(['xcrun', 'clang++', '-std=c++11', str(driver), *flags, '-o', str(shipped)])
    snapshot = {path: path.read_bytes() for path in corpus.glob('*.dcm')}
    binaries = [shipped]
    sanitizer = directory / 'sanitizer'
    if not arguments.shipped_only:
        cmake = ['cmake', '-S', str(source), '-B', str(sanitizer), '-DCMAKE_BUILD_TYPE=Debug',
                 '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_CXX_STANDARD=11',
                 '-DDCMTK_ENABLE_STL=ON', '-DBUILD_SHARED_LIBS=OFF',
                 '-DDCMTK_DEFAULT_DICT=builtin', '-DDCMTK_WITH_OPENSSL=OFF', '-DDCMTK_WITH_XML=OFF',
                 '-DDCMTK_WITH_TIFF=OFF', '-DDCMTK_WITH_PNG=OFF', '-DDCMTK_WITH_SNDFILE=OFF',
                 '-DDCMTK_WITH_OPENJPEG=OFF', '-DDCMTK_WITH_ICONV=OFF', '-DDCMTK_WITH_ICU=OFF',
                 '-DDCMTK_WITH_ZLIB=ON', '-DDCMTK_ENABLE_MANPAGES=OFF', '-DBUILD_APPS=OFF',
                 '-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -DDCMTK_MAX_SEQUENCE_NESTING=16',
                 '-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer',
                 '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined']
        checked(cmake)
        checked(['cmake', '--build', str(sanitizer), '--target', 'dcmdata', '--parallel', '8'])
        instrumented = directory / 'instrumented'
        includes = ['-I' + str(sanitizer / 'config/include')]
        includes += ['-I' + str(source / module / 'include') for module in ('dcmdata', 'ofstd', 'oflog', 'oficonv')]
        # The driver reads through the host's seekable deflated input, as the shipped build does.
        includes.append('-I' + str(ROOT / 'Horos/Sources'))
        libraries = [str(sanitizer / 'lib' / ('lib' + module + '.a')) for module in ('dcmdata', 'oflog', 'ofstd', 'oficonv')]
        checked(['xcrun', 'clang++', '-std=c++11', '-fsanitize=address,undefined',
                 '-fno-sanitize-recover=all', str(driver), *includes, *libraries,
                 '-lz', '-liconv', '-o', str(instrumented)])
        binaries.append(instrumented)
    for binary in binaries:
        result = checked([str(binary), *files], timeout=120,
                         env={**os.environ, 'TMPDIR': str(directory), 'ASAN_OPTIONS': 'halt_on_error=1:allocator_may_return_null=1',
                              'UBSAN_OPTIONS': 'halt_on_error=1', 'DCMDICTPATH': ''})
        output = (result.stdout + result.stderr).decode('latin1')
        rows = [line for line in result.stdout.decode('latin1').splitlines() if ' rows=' in line]
        assert len(rows) == len(files), output[-3000:]
        assert any('ordinary.dcm' in line and 'rows=4' in line for line in rows)
        assert any('nested-2000-deep.dcm' in line and 'Maximum sequence nesting depth exceeded' in line for line in rows), rows
        assert 'ERROR: AddressSanitizer' not in output and 'runtime error:' not in output
        assert any('deflated-valid.dcm' in line and 'good=1 pixels=8192 saved=1' in line for line in rows), rows
        hostile = [line for line in rows if 'deflated-' in line and 'deflated-valid' not in line]
        assert len(hostile) == 8 and all('good=0' in line for line in hostile), hostile
        if binary == shipped and sys.platform == 'darwin':
            allocated = max(int(re.search(r'allocated=(\d+)', line)[1]) for line in hostile)
            assert 0 < allocated < 64 * 1024 * 1024, hostile
            print('Hostile deflated maximum active allocation after read: %d bytes (false VL up to 4294967280)' % allocated)
        assert not list(directory.glob('.horos-inflate-*')), 'backing leaked'
        # The saved dataset retains identity and the complete deferred pixels.
        roundtrip = (directory / 'parser-roundtrip.dcm').read_bytes()
        assert bytes(range(256)) * 32 in roundtrip
        assert b'1.2.826.0.1.3680043.8.498.1' in roundtrip
        assert b'1.2.840.10008.1.2.1\x00' in roundtrip
        assert b'1.2.840.10008.1.2.1.99' not in roundtrip
        # Neither metadata nor inflated dataset parsing may change the corpus.
        denied = checked([str(binary), str(corpus / 'deflated-valid.dcm')], timeout=30,
                env={**os.environ, 'TMPDIR': str(directory / 'missing')})
        assert 'good=0' in denied.stdout.decode('latin1'), denied.stdout
        assert not (directory / 'missing').exists()
        assert all(path.read_bytes() == content for path, content in snapshot.items())
        # A file-size quota makes the actual write fail with EFBIG. Ignore
        # SIGXFSZ only in this child so the reader must report a clean failure.
        def no_space():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))
        denied = checked([str(binary), str(corpus / 'deflated-valid.dcm')], timeout=30,
                         env={**os.environ, 'TMPDIR': str(directory)}, preexec_fn=no_space)
        assert 'good=0' in denied.stdout.decode('latin1'), denied.stdout
        assert not list(directory.glob('.horos-inflate-*'))
        assert all(path.read_bytes() == content for path, content in snapshot.items())
    print('PASS: ' + ('installed parser' if arguments.shipped_only else 'installed and ASan/UBSan parsers') + ' reject hostile native/deflated inputs, preserve the control, save with backing alive and clean up')
