#!/usr/bin/env python3
"""NSLog called from Swift reaches the unified log, as from Objective-C (#1006).

Foundation's Swift overlay implements NSLog itself and, on this platform, writes
only to standard error. The application runs with standard error going nowhere,
so its Swift diagnostics were lost while the Objective-C ones were not. The Horos
module declares its own NSLog, which calls Foundation's C NSLogv.

This compiles that file with a caller, runs it with standard error discarded,
and looks for the line in the unified log. When a build is present, it also
checks that the executable no longer calls Foundation's Swift NSLog.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
source = root / 'Horos/Sources/UnifiedLogNSLog.swift'
failures = []

text = source.read_text() if source.is_file() else ''
if 'func NSLog(_ format: String, _ args: CVarArg...)' not in text or 'NSLogv(format' not in text:
    failures.append('the module no longer declares an NSLog that calls NSLogv')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if 'UnifiedLogNSLog.swift in Sources' not in project:
    failures.append('UnifiedLogNSLog.swift is not compiled into the application')

executable = root / 'build/Build/Products/Debug/Isis DICOM Viewer.app/Contents/MacOS/Isis DICOM Viewer'
if executable.is_file():
    undefined = subprocess.run(['nm', '-u', str(executable)], capture_output=True, text=True).stdout
    if '$s10Foundation5NSLog' in undefined:
        failures.append('the Debug executable still calls Foundation\'s Swift NSLog, which only '
                        'writes to standard error')


def logged(marker, program):
    subprocess.run([str(program)], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=True)
    for _ in range(10):
        time.sleep(1)
        shown = subprocess.run(['/usr/bin/log', 'show', '--last', '2m', '--style', 'compact',
                                '--predicate', 'eventMessage CONTAINS "%s"' % marker],
                               capture_output=True, text=True)
        if shown.returncode != 0:
            return None
        if marker in shown.stdout.replace('eventMessage CONTAINS', ''):
            lines = [line for line in shown.stdout.splitlines()
                     if marker in line and '/usr/bin/log' not in line]
            if lines:
                return True
    return False


with tempfile.TemporaryDirectory(prefix='horos-nslog-') as directory:
    folder = Path(directory)
    # In the format, not an argument: arguments are redacted as <private>.
    marker = 'HOROS-NSLOG-' + uuid.uuid4().hex
    (folder / 'main.swift').write_text('import Foundation\nNSLog("' + marker + ' %d", Int32(1))\n')
    built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', str(source), str(folder / 'main.swift'),
                            '-o', str(folder / 'probe')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the NSLog file does not compile: %s' % built.stderr[-800:])
    else:
        result = logged(marker, folder / 'probe')
        if result is None:
            print('SKIP: the unified log cannot be read here (/usr/bin/log show failed)')
            sys.exit(2)
        if not result:
            failures.append('a line logged from Swift through the module\'s NSLog is not in the unified log')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: NSLog from Swift reaches the unified log with standard error discarded')
