#!/usr/bin/env python3
"""The anonymization field of an SL tag accepts every signed 32-bit value.

The former [NSNumber numberWithInteger:-0x80000000] was +2147483648, because
0x80000000 is unsigned in C: the minimum was above the maximum, and a negative
SL value was refused. The formatter is built by AnonymizationTagsView; this
compiles its SL branch and asks the formatter itself.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/AnonymizationTagsView.swift'
if revision:
    source = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
else:
    source = (root / path).read_text()

branch = re.search(r'\} else if vr == "SL" \{ //signed long\n(.*?)\n\s*\} else if vr == "SS"', source, re.S)
if not branch:
    print('FAIL: the SL branch of AnonymizationTagsView is not where it was')
    sys.exit(1)
lines = [line for line in branch.group(1).split('\n') if 'toolTip' not in line]
program = '''import Foundation
let nf = NumberFormatter()
nf.formatterBehavior = .behavior10_4
nf.numberStyle = .decimal
''' + '\n'.join(lines) + '''
var failed = false
for text in ["-2147483648", "-5", "0", "2147483647"] {
    var value: AnyObject?
    var error: NSString?
    if !nf.getObjectValue(&value, for: nf.string(from: NSNumber(value: Int(text)!))!, errorDescription: &error) {
        print("refused " + text); failed = true
    }
}
for text in ["-2147483649", "2147483648"] {
    var value: AnyObject?
    var error: NSString?
    if nf.getObjectValue(&value, for: nf.string(from: NSNumber(value: Int(text)!))!, errorDescription: &error) {
        print("accepted " + text); failed = true
    }
}
exit(failed ? 1 : 0)
'''
with tempfile.TemporaryDirectory(prefix='horos-anonymization-sl-') as directory:
    main = Path(directory) / 'main.swift'
    main.write_text(program)
    subprocess.run(['xcrun', 'swiftc', str(main), '-o', str(Path(directory) / 'sl')], check=True)
    done = subprocess.run([str(Path(directory) / 'sl')], capture_output=True, text=True)
if done.returncode:
    for line in done.stdout.split('\n'):
        if line:
            print('FAIL:', line)
    sys.exit(1)
print('PASS: an SL field accepts -2147483648 to 2147483647 and nothing outside')
