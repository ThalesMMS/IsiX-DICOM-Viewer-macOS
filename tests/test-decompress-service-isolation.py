#!/usr/bin/env python3
"""A file that brings the decoder down ends the Decompress service, not the application.

That is why the decoding runs apart from the application: first in the
Decompress helper process, now in the Decompress XPC service. Here a copy of
the built service is given a fault: a library inserted into it
(DYLD_INSERT_LIBRARIES, through the copy's XPCService EnvironmentVariables)
makes every fopen of a file named "isix-crash-trigger" end the process on
SIGSEGV, where DCMTK first opens the file. The service itself carries no such
trigger; the copy is signed again ad hoc, without the hardened runtime, so that
the library loads.

Through the tests' client (decompress_service.py), which calls the code the
application calls, in one process:

1. a list to compress with the trigger second converts the first file, fails,
   says the service ended, and leaves the trigger and the third file as they were;
2. the validation before importing refuses the trigger alone;
3. the next list starts the service again and converts the third file;
4. the client, standing for the application, ends normally.

And, as a control, the real service converts the same trigger file.

    python3 tests/test-decompress-service-isolation.py [--helper PATH]

--helper names another Decompress.xpc. Skipped (exit 2) without a built service.
"""
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import decompress_service  # noqa: E402

args = sys.argv[1:]
service = Path(args[args.index('--helper') + 1]).resolve() if '--helper' in args else decompress_service.built_service()
if service is None or not (service / 'Contents/Info.plist').is_file():
    print('skipped: needs the built Decompress service (build Debug or --helper PATH to a Decompress.xpc)',
          file=sys.stderr)
    raise SystemExit(2)

FAULT = r'''
#include <signal.h>
#include <stdio.h>
#include <string.h>

// fopen is imported under two names, the plain one and the one the SDK's
// headers alias it to; both are replaced.
extern FILE *plain_fopen(const char *, const char *) __asm("_fopen");
extern FILE *extsn_fopen(const char *, const char *) __asm("_fopen$DARWIN_EXTSN");

// Ends the process the way a decoder that reads past its buffer would.
static void fault(const char *path)
{
    if (path && strstr(path, "isix-crash-trigger")) raise(SIGSEGV);
}
static FILE *faulting_plain(const char *path, const char *mode) { fault(path); return plain_fopen(path, mode); }
static FILE *faulting_extsn(const char *path, const char *mode) { fault(path); return extsn_fopen(path, mode); }

__attribute__((used)) static const struct { const void *replacement; const void *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
        { (const void *)faulting_plain, (const void *)plain_fopen },
        { (const void *)faulting_extsn, (const void *)extsn_fopen } };
'''


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


def synthetic_ct(path, sop):
    ct = b'1.2.840.10008.5.1.4.1.1.2'
    body = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', ct) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') \
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.10.7000')
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(body))) + body
    data = element(0x0008, 0x0016, b'UI', ct) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', b'CT') + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^ISOLATION') \
        + element(0x0010, 0x0020, b'LO', b'SYN-ISOLATION') \
        + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.10.7000.1') \
        + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.10.7000.2') \
        + element(0x0028, 0x0002, b'US', struct.pack('<H', 1)) + element(0x0028, 0x0004, b'CS', b'MONOCHROME2') \
        + element(0x0028, 0x0010, b'US', struct.pack('<H', 16)) + element(0x0028, 0x0011, b'US', struct.pack('<H', 16)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', 16)) + element(0x0028, 0x0101, b'US', struct.pack('<H', 12)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', 11)) + element(0x0028, 0x0103, b'US', struct.pack('<H', 0)) \
        + element(0x7FE0, 0x0010, b'OW', struct.pack('<256H', *range(256)))
    path.write_bytes(b'\0' * 128 + b'DICM' + meta + data)


def syntax(path):
    data = path.read_bytes()[:2048]
    at = data.find(b'\x02\x00\x10\x00UI')
    return data[at + 8:at + 8 + struct.unpack('<H', data[at + 6:at + 8])[0]].rstrip(b'\0 ').decode() if at >= 0 else None


failures = []
JPEG2000 = '1.2.840.10008.1.2.4.90'
with tempfile.TemporaryDirectory(prefix='horos-decompress-isolation-') as folder:
    work = Path(folder)
    fault = work / 'fault.dylib'
    (work / 'fault.c').write_text(FAULT)
    # Both slices, for the service of either package (x86_64 runs under Rosetta).
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-arch', 'x86_64', str(work / 'fault.c'),
                    '-o', str(fault)], check=True, timeout=120)
    faulty = decompress_service.client(service, work / 'faulty', environment={'DYLD_INSERT_LIBRARIES': str(fault)})

    settings = work / 'settings.plist'
    codec = [{'modality': 'default', 'compression': 3, 'quality': 0}]
    settings.write_bytes(plistlib.dumps({'CompressionSettings': codec, 'CompressionSettingsLowRes': codec,
                                         'CompressionResolutionLimit': 0, 'DecompressMoveIfFail': False}))
    sources, out = work / 'sources', work / 'out'
    sources.mkdir()
    out.mkdir()
    good, trigger, other = sources / 'good.dcm', sources / 'isix-crash-trigger.dcm', sources / 'other.dcm'
    for index, path in enumerate((good, trigger, other)):
        synthetic_ct(path, f'1.2.826.0.1.3680043.10.7000.3.{index}'.encode())
    before = {path: path.read_bytes() for path in (trigger, other)}

    result = subprocess.run([str(faulty), str(out), 'SettingsPlist', str(settings), 'isolation',
                             str(good), str(trigger), str(other)], capture_output=True, text=True, timeout=300)
    lines = result.stdout.splitlines()
    print('\n'.join('client: ' + line for line in lines))
    expected = ['list succeeded=false crashed=true', 'refused=isix-crash-trigger.dcm',
                'after succeeded=true crashed=false']
    if result.returncode != 0:
        failures.append(f'the client did not end normally ({result.returncode}): {result.stderr[-600:]}')
    if lines != expected:
        failures.append(f'expected {expected}, the client said {lines}')
    if 'service ended' not in result.stderr:
        failures.append('the conversion the service did not survive was not reported')
    if syntax(out / 'good.dcm') != JPEG2000 or (out / 'other.dcm').is_file() and syntax(out / 'other.dcm') != JPEG2000:
        failures.append('the files around the trigger were not converted')
    if not (out / 'other.dcm').is_file():
        failures.append('the service was not started again for the next list')
    if not trigger.is_file() or trigger.read_bytes() != before[trigger] or (out / trigger.name).exists():
        failures.append('the file that ended the service was moved or changed')
    if list(work.rglob('.horos-*')):
        failures.append('a working file was left behind')
    if not failures:
        print('ok: the file that ends the service fails alone; the client goes on and the service starts again')

    # The control: without the fault, the same file converts.
    control = work / 'control'
    control.mkdir()
    real = decompress_service.client(service, work / 'real')
    result = subprocess.run([str(real), str(control), 'SettingsPlist', str(settings), 'compress', str(trigger)],
                            capture_output=True, text=True, timeout=120)
    if result.returncode != 0 or syntax(control / trigger.name) != JPEG2000:
        failures.append(f'the real service did not convert the trigger file ({result.returncode}): {result.stderr[-400:]}')
    else:
        print('ok: without the fault the same file converts')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
