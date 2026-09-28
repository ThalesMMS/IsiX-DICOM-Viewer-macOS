#!/usr/bin/env python3
"""DicomDirParser reads dcmdump's whole output and never waits for a dcmdump that did not start (#751).

DicomDirParser.swift is compiled as it is, with the real HorosObjCException. A
fake dcmdump beside the test binary (the parser runs <resourcePath>/dcmdump)
prints Referenced File IDs the way `dcmdump +L +P 0004,1500` does, in small
writes with pauses between them:
- missing: no dcmdump. The parser used to wait forever, holding the lock of
  every DICOMDIR read; two parsers in a row must return at once, empty.
- latin1: three names in Latin-1. Reads that did not decode as UTF-8 were
  dropped; all three files must be found.
- utf8: twenty names of multi-byte characters, a character cut between two
  writes. The parser stopped at the UTF-16 length of a UTF-8 buffer and lost
  the last names; all twenty must be found.
The depth counter is checked in the source: one per parser, not a static.

`<git revision>` as an optional argument reads the parser from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/DicomDirParser.swift'
source = (subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
          if revision else (root / path).read_text())

failures = []
if re.search(r'static var validFilePathDepth', source):
    failures.append('the depth counter is still shared by every parser and thread')

LATIN1 = ['IMGÉ%d' % n for n in range(1, 4)]
UTF8 = ['ÉÉÉÉÉÉÉÉÉÉ%02d' % n for n in range(1, 21)]

fake = r'''#!/usr/bin/python3
import os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, 'mode')).read().strip()
names = {'latin1': %r, 'utf8': %r}[mode]
encoding = 'latin-1' if mode == 'latin1' else 'utf-8'
out = sys.stdout.buffer
out.write(b'\n# Dicom-File-Format\n')
for name in names:
    line = ('(0004,1500) CS [DIR\\' + name + '] # 12, 2 ReferencedFileID\n').encode(encoding)
    cut = line.index(b'[') + 7
    out.write(line[:cut]); out.flush(); time.sleep(0.02)
    out.write(line[cut:]); out.flush(); time.sleep(0.02)
''' % (LATIN1, UTF8)

main = r'''
import Foundation
let folder = CommandLine.arguments[1]
let start = Date()
for _ in 0..<2 {
    let parser = DicomDirParser(folder + "/DICOMDIR")
    let files = NSMutableArray()
    parser.parseArray(files)
    print("found \(files.count)")
}
print(String(format: "seconds %.1f", Date().timeIntervalSince(start)))
'''

with tempfile.TemporaryDirectory(prefix='horos-dicomdir-parser-') as tmp:
    p = Path(tmp)
    (p / 'DicomDirParser.swift').write_text(source)
    (p / 'main.swift').write_text(main)
    (p / 'bridging.h').write_text('#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n'
                                  'extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);\n')
    (p / 'n2.m').write_text('#import <Foundation/Foundation.h>\n'
                            'void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%@", e); }\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'clang', '-c', str(p / 'n2.m'), '-o', str(p / 'n2.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                    '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / 'DicomDirParser.swift'), str(p / 'main.swift'),
                    str(p / 'HorosObjCException.o'), str(p / 'n2.o'), '-o', str(p / 'parser')], check=True, capture_output=True)

    for mode, names in (('missing', []), ('latin1', LATIN1), ('utf8', UTF8)):
        dicomdir = p / mode
        (dicomdir / 'DIR').mkdir(parents=True)
        (dicomdir / 'DICOMDIR').write_bytes(b'')
        for name in names:
            (dicomdir / 'DIR' / name).write_bytes(b'x')
        tool = p / 'dcmdump'
        if mode == 'missing':
            tool.unlink(missing_ok=True)
        else:
            tool.write_text(fake)
            tool.chmod(0o755)
            (p / 'mode').write_text(mode)
        try:
            done = subprocess.run([str(p / 'parser'), str(dicomdir)], capture_output=True, text=True, timeout=30)
            found = [int(n) for n in re.findall(r'found (\d+)', done.stdout)]
            seconds = float(re.search(r'seconds ([\d.]+)', done.stdout).group(1)) if 'seconds' in done.stdout else None
        except subprocess.TimeoutExpired:
            found, seconds = [], None
        expected = len(names)
        if found != [expected, expected]:
            failures.append(f'{mode}: found {found or "nothing (the parser did not return in 30 s)"}, expected {expected} twice')
        elif mode == 'missing' and seconds is not None and seconds > 5:
            failures.append(f'missing: two parsers took {seconds} s without a dcmdump')
        else:
            print(f'pass {mode}: {expected} of {expected}, twice' + (f', {seconds} s' if mode == 'missing' else ''))

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a missing dcmdump ends the read; Latin-1 and UTF-8 names are all found; one depth counter per parser')
