"""The definitions of the names the former plugin SDK exports, for a test that links a slice of the app.

The headers of the app declare `extern` the constants and globals a plugin
built for Horos or OsiriX looks up by name; two files define them, and each
compiles alone, with the branch of its headers that does not need the
generated Swift interface:

- Horos/Sources/FormerPluginSDK+CAPI.m: the error domain, the ROI manager's
  notification and keys, the curved path's token, the web portal's entity
  names and session keys. It needs nothing at link.
- Nitrogen/Sources/Nitrogen+CAPI.m: the N3 and N2 constants, the thread and
  SMTP keys, the notifications of Nitrogen's views. Its Core Foundation
  callbacks call four functions of N3BezierCore: a slice that does not link
  the N3 geometry takes `bezier_stubs` too.

A test whose slice reads one of those names adds the object to its link.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TARGET = ['-target', 'arm64-apple-macos15.0']

STUBS = '''
#include <CoreFoundation/CoreFoundation.h>
void *N3BezierCoreRetain(const void *core) { return (void *)core; }
void N3BezierCoreRelease(const void *core) {}
CFStringRef N3BezierCoreCopyDescription(const void *core) { return CFSTR(""); }
bool N3BezierCoreEqualToBezierCore(const void *first, const void *second) { return first == second; }
'''


def _compile(source, obj, flags):
    if not obj.exists():
        result = subprocess.run(['xcrun', 'clang', *TARGET, '-fno-objc-arc', '-DHOROS_BRIDGING_HEADER', *flags,
                                 '-I', str(ROOT / 'Nitrogen/Sources'), '-I', str(ROOT / 'Horos/Sources'),
                                 '-c', str(source), '-o', str(obj)], capture_output=True, text=True, timeout=600)
        if result.returncode:
            raise RuntimeError(f'{Path(source).name} does not compile alone:\n{result.stderr[-2500:]}')
    return str(obj)


def app(folder, flags=('-O0',)):
    """The object of Horos/Sources/FormerPluginSDK+CAPI.m, made in `folder`."""
    return _compile(ROOT / 'Horos/Sources/FormerPluginSDK+CAPI.m', Path(folder) / 'FormerPluginSDK.o', flags)


def nitrogen(folder, flags=('-O0',)):
    """The object of Nitrogen/Sources/Nitrogen+CAPI.m, made in `folder`."""
    return _compile(ROOT / 'Nitrogen/Sources/Nitrogen+CAPI.m', Path(folder) / 'NitrogenConstants.o', flags)


def bezier_stubs(folder):
    """An object with the four N3BezierCore functions Nitrogen+CAPI.m calls, for a slice without the N3 geometry."""
    source = Path(folder) / 'N3BezierCoreStubs.c'
    source.write_text(STUBS)
    return _compile(source, Path(folder) / 'N3BezierCoreStubs.o', ('-O0',))
