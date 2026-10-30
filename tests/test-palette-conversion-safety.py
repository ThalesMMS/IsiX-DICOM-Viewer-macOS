#!/usr/bin/env python3
"""Palettes that are truncated, extreme or absent, under AddressSanitizer.

`-[DCMPixelDataAttribute convertPaletteToRGB:]` trusted what the object told it.
Driven under AddressSanitizer against thirteen palettes - 8- and 16-bit, indices of
0 and 65535, tables shorter than their descriptors, a descriptor with one value
instead of three, pixel data half as long as the picture, a segment claiming
60000 values in a stream of five, a linear segment with nothing before it - the
version before this reported:

    heap-buffer-overflow  x3   reading a lookup table past its end
    runtime error: load of null pointer of type 'unsigned char'
    SEGV on unknown address 0x000000000000

The null load and the crash are the blue table being read from the green
attribute when there is no green one. The overflows are a table read to the
number of entries the descriptor claims rather than the number it holds.

The same thirteen cases now produce no findings at all. The conversion is the
IsiXDICOMDataset module's: tools/exercise-palette-conversion.swift is compiled
with the module's sources and drives it with real DCMObjects. A Swift bounds
check that stops the driver counts as a finding too.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_driver  # noqa: E402

root = Path(__file__).resolve().parents[1]
failures = []
driver_path = root / 'tools/exercise-palette-conversion.swift'

if not driver_path.exists():
    failures.append('the driver that exercises the conversion is gone')
else:
    with tempfile.TemporaryDirectory(prefix='horos-palette-asan-') as directory:
        binary = Path(directory) / 'palette'
        try:
            module_driver('IsiXDICOMDataset', driver_path.read_text(encoding='utf-8'), binary,
                          ['-sanitize=address', '-g', '-Onone'])
        except subprocess.CalledProcessError as error:
            failures.append('the conversion does not compile with the driver:\n%s' % error.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300,
                                 env={'ASAN_OPTIONS': 'halt_on_error=0:exitcode=1', 'PATH': '/usr/bin:/bin'})
            output = run.stdout + run.stderr
            findings = [line for line in output.splitlines()
                        if 'ERROR: AddressSanitizer' in line or 'runtime error:' in line or 'Fatal error' in line]
            for finding in findings:
                failures.append('sanitizer: %s' % finding.strip()[:160])
            if 'WRONG SIZE' in output:
                for line in output.splitlines():
                    if 'WRONG SIZE' in line:
                        failures.append('the conversion answered the wrong size: %s' % line.strip())
            cases = [line for line in output.splitlines() if 'bytes  (expected' in line]
            if len(cases) < 13:
                failures.append('only %d of the 13 cases ran; the driver stopped early' % len(cases))
            if run.returncode != 0 and not findings:
                failures.append('the driver exited %d with no sanitizer finding: %s'
                                % (run.returncode, output[-500:]))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: thirteen truncated, extreme and absent palettes convert without reading or writing '
      'outside a buffer')
