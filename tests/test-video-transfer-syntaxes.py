#!/usr/bin/env python3
"""DCMTK recognizes video transfer syntaxes even without a viewer decoder.

Recognition prevents incoming video instances from being discarded. Host
classification/import is covered by the production detector tests; this
check exercises the transfer syntax table used by that backend.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
from dcmtk_build import ROOT, dcmtk_flags

generator = (ROOT / 'tools/generate-mpeg4-fixture.py').read_text()
for uid in ('1.2.840.10008.1.2.4.107', '1.2.840.10008.1.2.4.108'):
    assert uid in generator, 'the synthetic generator cannot write ' + uid

program = r'''
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmdata/dcxfer.h"
#include <cstdio>
int main() {
    for (int i = 100; i <= 108; ++i) {
        char uid[64];
        snprintf(uid, sizeof uid, "1.2.840.10008.1.2.4.%d", i);
        DcmXfer syntax(uid);
        if (syntax.getXfer() == EXS_Unknown || !syntax.usesEncapsulatedFormat() ||
            !syntax.isPixelDataLossyCompressed() || syntax.isPixelDataLosslessCompressed() ||
            !syntax.isExplicitVR() || !syntax.isLittleEndian()) return 1;
        printf("%s: encapsulated, lossy, explicit VR little endian\n", uid);
    }
    return 0;
}
'''
if len(sys.argv) > 1:
    install = Path(sys.argv[1]).resolve()
    archives = [install / 'lib' / ('lib' + name + '.a')
                for name in ('dcmdata', 'oflog', 'ofstd', 'oficonv')]
    if not all(path.is_file() for path in [install / 'include/dcmtk/config/osconfig.h', *archives]):
        print('skipped: requires the installed DCMTK headers and archives')
        raise SystemExit(2)
    flags = ['-I' + str(install / 'include'), *map(str, archives), '-lz', '-liconv']
else:
    flags = dcmtk_flags()
with tempfile.TemporaryDirectory(prefix='horos-video-ts-') as temporary:
    directory = Path(temporary)
    source = directory / 'transfer-syntax.cc'
    source.write_text(program)
    binary = directory / 'transfer-syntax'
    subprocess.run(['xcrun', 'clang++', '-std=c++11', str(source), *flags,
                    '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30)
print('PASS: DCMTK recognizes all nine video transfer syntaxes')
