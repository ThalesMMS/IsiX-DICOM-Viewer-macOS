#!/usr/bin/env python3
"""The arrow keys of a mirrored MPR view each move the plane their own way (#844).

MPRDCMView -keyDown: swapped left and right for a horizontally mirrored image,
and up and down for a vertically mirrored one, with two ifs in a row: the second
undid what the first did, so both arrows of the pair meant the same key. The
swap is now MPRDCMView.arrowKeyInImage(_:xFlipped:yFlipped:), which keyDown
calls. The test compiles that function with swiftc and checks every arrow under
every mirroring.

`<git revision>` as an optional argument reads MPRDCMView from that revision,
the negative control: before this change, the swap was written in keyDown, and
the test compiles that code instead.
"""
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  (a TMPDIR of the test's own)
import sources
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def view_source():
    if revision is None:
        return sources.source_text('MPRDCMView')
    for name in ('MPRDCMView.swift', 'MPRDCMView.m'):
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/{name}'],
                                           stderr=subprocess.DEVNULL).decode('utf-8', 'replace')
        except subprocess.CalledProcessError:
            continue
    raise SystemExit(f'FAIL: no MPRDCMView at {revision}')


def block(text, start):
    """From `start` to the brace that closes the first brace after it."""
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise ValueError('unbalanced braces')


text = view_source()
key_down = text.find('func keyDown(with theEvent: NSEvent)')
if key_down < 0:
    print('FAIL: MPRDCMView has no Swift keyDown(with:)', file=sys.stderr)
    sys.exit(1)
key_down_body = block(text, key_down)

helper = text.find('static func arrowKeyInImage(')
if helper >= 0:
    function = block(text, helper).replace('static func', 'func', 1)
    if 'MPRDCMView.arrowKeyInImage(c, xFlipped: self.xFlipped, yFlipped: self.yFlipped)' not in key_down_body:
        print('FAIL: keyDown does not pass the key through arrowKeyInImage', file=sys.stderr)
        sys.exit(1)
    if re.search(r'if\s+self\.[xy]Flipped\s*\{', key_down_body):
        print('FAIL: keyDown still swaps the arrows itself', file=sys.stderr)
        sys.exit(1)
else:
    # The former code: the swap written in keyDown.
    start = key_down_body.find('if self.xFlipped {')
    end = key_down_body.find('if c == NSDownArrowFunctionKey || c == NSUpArrowFunctionKey {')
    if start < 0 or end < 0:
        print('FAIL: MPRDCMView swaps the arrows neither in arrowKeyInImage nor in keyDown', file=sys.stderr)
        sys.exit(1)
    swap = key_down_body[start:end].replace('self.xFlipped', 'xFlipped').replace('self.yFlipped', 'yFlipped')
    function = ('func arrowKeyInImage(_ key: Int, xFlipped: Bool, yFlipped: Bool) -> Int {\n'
                '    var c = key\n' + swap + '\n    return c\n}\n')

code = 'import AppKit\n\n' + function + r'''

let names = [NSLeftArrowFunctionKey: "left", NSRightArrowFunctionKey: "right",
             NSUpArrowFunctionKey: "up", NSDownArrowFunctionKey: "down", 0x20: "space"]
var failures: [String] = []
for xFlipped in [false, true] {
    for yFlipped in [false, true] {
        let expected = [
            NSLeftArrowFunctionKey: xFlipped ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey,
            NSRightArrowFunctionKey: xFlipped ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey,
            NSUpArrowFunctionKey: yFlipped ? NSDownArrowFunctionKey : NSUpArrowFunctionKey,
            NSDownArrowFunctionKey: yFlipped ? NSUpArrowFunctionKey : NSDownArrowFunctionKey,
            0x20: 0x20,
        ]
        for (key, wanted) in expected.sorted(by: { $0.key < $1.key }) {
            let got = arrowKeyInImage(key, xFlipped: xFlipped, yFlipped: yFlipped)
            if got != wanted {
                failures.append("xFlipped \(xFlipped), yFlipped \(yFlipped): \(names[key]!) gives \(names[got] ?? String(got)), not \(names[wanted]!)")
            }
        }
    }
}
if !failures.isEmpty {
    for failure in failures { print(failure) }
    exit(1)
}
print("ok")
'''

with tempfile.TemporaryDirectory(prefix='horos-mpr-arrows-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(code)
    build = subprocess.run(['xcrun', 'swiftc', '-O', str(folder / 'main.swift'), '-o', str(folder / 'arrows')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print('FAIL: the arrow swap does not compile:\n' + build.stderr, file=sys.stderr)
        sys.exit(1)
    run = subprocess.run([str(folder / 'arrows')], capture_output=True, text=True)
    if run.returncode != 0:
        print('FAIL: a mirrored MPR view maps the arrows wrongly:\n' + run.stdout + run.stderr, file=sys.stderr)
        sys.exit(1)

print('PASS: each arrow of a mirrored MPR view is swapped once, and only under its own mirroring')
