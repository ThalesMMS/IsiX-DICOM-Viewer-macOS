#!/usr/bin/env python3
"""The string constants the plugin headers declare survive dead stripping (#744).

Release links with dead code stripping, which removed 40 constants that
nothing in the application reads but plugins do - notification names, keys,
entity names - and a plugin referencing one did not load (TotalSegmentator:
OsirixLLMPRResliceNotification). Their definitions carry
__attribute__((used)), which keeps them.

Every `extern NSString* const` in the built Horos.framework headers that the
host defines must be marked so, and, when a Release build is present, be
exported by its executable.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
products = root / 'build/Build/Products'
headers = next((products / c / 'Horos.framework/Headers' for c in ('Release', 'Debug')
                if (products / c / 'Horos.framework/Headers').is_dir()), None)
if headers is None:
    print('skipped: needs a built Horos.framework (script/build_and_run.sh)', file=sys.stderr)
    raise SystemExit(2)

declared = set()
for header in headers.glob('*.h'):
    text = header.read_bytes().decode('latin1')
    declared |= set(re.findall(r'extern\s+(?:const\s+)?NSString\s*\*\s*(?:const\s+)?([A-Za-z_]\w*)\s*;', text))

definitions = {}
for folder in ('Horos/Sources', 'Nitrogen/Sources'):
    for source in (root / folder).rglob('*.m*'):
        for line in source.read_bytes().decode('latin1').splitlines():
            match = re.match(r'^(.*?)(?:const\s+)?NSString\s*\*\s*(?:const\s+)?([A-Za-z_]\w*)\s*=', line)
            if match and match.group(2) in declared and 'static' not in match.group(1):
                definitions[match.group(2)] = (source.relative_to(root), line)

failures = [f'{name} in {path} is not marked __attribute__((used))'
            for name, (path, line) in sorted(definitions.items()) if '__attribute__((used))' not in line]

binary = products / 'Release/Horos.app/Contents/MacOS/Horos'
checked = 'no Release build, exports not checked'
if binary.is_file():
    exported = {line.split()[-1][1:] for line in
                subprocess.check_output(['nm', '-gU', str(binary)], text=True).splitlines() if line.split()}
    failures += [f'Release does not export {name}' for name in sorted(definitions) if name not in exported]
    checked = 'all exported by Release'

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print(f'PASS: {len(definitions)} constants from {len(declared)} header declarations are kept; {checked}')
