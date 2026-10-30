#!/usr/bin/env python3
"""The 3D window survives an Objective-C exception in its saved state, its
initializer and its presets.

The Objective-C VRController ran its initializer, -load3DState and the
application of a 3D preset inside @try: an NSException there (a saved state
whose values are not of the type -[VRView set3DStateDictionary:] reads, a VTK
or nib edge case) was logged and the rest skipped; the initializer answered
nil. Swift does not catch an NSException, so the Swift controller sends those
calls through HorosObjCException.

Statically: the initializer's checks and its setup after the nib each run under
HorosObjCException.caught and answer nil after _N2LogExceptionImpl;
-load3DState runs all of its body there and logs; -load3DSettings: applies the
preset there and logs "Applying 3d preset exception".

At run time: -load3DState as VRController+State.swift has it, with
HorosObjCException.m and the `caught` helper of DCMPix+Database.swift, is
compiled into a stand-in controller whose body reads a state file the way
-[VRView set3DStateDictionary:] reads ShadingValues (that method's first
statements and the readers of the saved values, cut from VRView+State.swift,
the Swift extension of VRView that has it). A state whose ShadingValues is a
string, not an array, raises NSInvalidArgumentException there, as it did in
the former code; the stand-in must log it once, skip what follows in the body
and keep running. A well-formed state goes through without a log.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
SKIPPED = 2
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def read(path):
    return (root / path).read_text()


def block(source, signature):
    start = source.find(signature)
    if start < 0:
        return ''
    depth, i = 0, source.index('{', start)
    while True:
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1


controller = read('Horos/Sources/VRController.swift')
state = read('Horos/Sources/VRController+State.swift')
presets = read('Horos/Sources/VRController+Presets.swift')

init = block(controller, '    public convenience init?(pix: NSMutableArray!, _ f: NSArray!, _ vData: NSData!, _ bC: ViewerController!,\n'
                         '                             _ vC: ViewerController!, style m: String!, mode renderingMode: String!) {')
check(init, 'VRController.swift lost -initWithPix:::::style:mode:')
guarded = re.findall(r'if let e = HorosObjCException\.caught\(\{[^\n]*\}\) \{\n\s*_N2LogExceptionImpl\(e, false, VRController\.initializerName\)\n\s*return nil', init)
check(len(guarded) == 2, f'the initializer must run its checks and its setup under HorosObjCException.caught, log and answer nil ({len(guarded)} guarded calls)')
check('volumeIsRenderable(' in init and 'adoptVolume(' in init and init.count('self.init(windowNibName: "VR")') == 1,
      'the initializer must call its checks and its setup only through the guarded calls')
check('"-[VRController initWithPix:::::style:mode:]"' in controller, 'the initializer must log under its Objective-C name')

load = block(state, '    public override func load3DState() {')
check(re.search(r'if let e = HorosObjCException\.caught\(\{ applySavedState\(\) \}\) \{\n\s*_N2LogExceptionImpl\(e, false, "-\[VRController load3DState\]"\)', load),
      '-load3DState must run its whole body under HorosObjCException.caught and log what it caught')
check(load.count('\n') <= 6, '-load3DState must do nothing outside the guarded call')

settings = block(presets, '    public final func load3DSettings(_ sender: Any!) {')
check(re.search(r'if let e = HorosObjCException\.caught\(\{ applySelectedPreset\(\) \}\) \{\n\s*NSLog\("Applying 3d preset exception: %@", e\)', settings),
      '-load3DSettings: must apply the preset under HorosObjCException.caught and log "Applying 3d preset exception"')

# The run.
view = read('Horos/Sources/VRView+State.swift')
setter = re.search(r'    func set3DStateDictionary\(_ dict: \[AnyHashable: Any\]\?\) \{\n.*?        if let dict \{\n(.*?)\n            if renderingMode == 0', view, re.S)
readers = re.search(r'\n(/// `\[x floatValue\]`.*?)\nextension VRView \{', view, re.S)
helper = re.search(r'extension HorosObjCException \{.*?\n\}\n', read('Horos/Sources/DCMPix+Database.swift'), re.S)
if not (setter and readers and helper and load):
    print('FAIL: the sources this probe compiles moved; the test needs a new look')
    sys.exit(1)
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun', file=sys.stderr)
    sys.exit(SKIPPED)

STUB_H = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
int loggedCountValue(void);
extern void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);
'''
STUB_M = r'''
#import "stub.h"
static int loggedCount = 0;
int loggedCountValue(void) { return loggedCount; }
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) {
    loggedCount++;
    fprintf(stderr, "logged %s in %s\n", e.name.UTF8String, pf);
}
'''
MAIN = r'''
import Foundation

@@HELPER@@

nonisolated(unsafe) var reachedEnd = false

@@READERS@@

// The view: its saved state's first reading, as VRView+State.swift has it.
final class StubVRView: NSObject {
    var shading0: Float = 0
    func setShadingValues(_ a: Float, _ d: Float, _ s: Float, _ p: Float) { shading0 = a }
    func set3DStateDictionary(_ dict: [AnyHashable: Any]?) {
        if let dict {
@@SETTER@@
        }
    }
}

final class VRController: NSObject {
    let view = StubVRView()
    let file: String
    init(file: String) { self.file = file }
    // -[VRController load3DState]'s reading: the file, then the view.
    private func applySavedState() {
        let dict = NSDictionary(contentsOfFile: file)
        view.set3DStateDictionary(dict as? [AnyHashable: Any] ?? [:])
        reachedEnd = true
    }
@@LOAD@@
}

let bad = VRController(file: CommandLine.arguments[1])
bad.load3DState()
print("bad", loggedCountValue(), reachedEnd)
reachedEnd = false
let good = VRController(file: CommandLine.arguments[2])
good.load3DState()
print("good", loggedCountValue(), reachedEnd, good.view.shading0)
'''

with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    (t / 'stub.h').write_text(STUB_H)
    (t / 'stub.m').write_text(STUB_M)
    (t / 'main.swift').write_text(MAIN.replace('@@HELPER@@', helper.group(0)).replace('@@READERS@@', readers.group(1))
                                  .replace('@@SETTER@@', setter.group(1))
                                  .replace('@@LOAD@@', load.replace('public override func load3DState', 'func load3DState')))
    import plistlib
    (t / 'bad.plist').write_bytes(plistlib.dumps({'ShadingValues': 'not an array', 'WL': 40, 'WW': 400}))
    (t / 'good.plist').write_bytes(plistlib.dumps({'ShadingValues': [0.25, 0.5, 0.75, 10.0], 'WL': 40, 'WW': 400}))
    sources = root / 'Horos/Sources'
    objc = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(sources), '-I', str(t),
                           str(sources / 'HorosObjCException.m'), str(t / 'stub.m')],
                          cwd=t, capture_output=True, text=True, timeout=300)
    if objc.returncode:
        print('FAIL: the Objective-C part does not build:\n' + objc.stderr[-3000:])
        sys.exit(1)
    swift = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-import-objc-header', str(t / 'stub.h'),
                            '-I', str(sources), str(t / 'main.swift'), 'HorosObjCException.o', 'stub.o', '-o', 'probe'],
                           cwd=t, capture_output=True, text=True, timeout=300)
    if swift.returncode:
        print('FAIL: the probe does not build:\n' + swift.stderr[-3000:])
        sys.exit(1)
    run = subprocess.run([str(t / 'probe'), str(t / 'bad.plist'), str(t / 'good.plist')],
                         capture_output=True, text=True, timeout=60)
    if run.returncode:
        failures.append(f'the probe stopped with {run.returncode} on a state that raises: {run.stderr.strip()[-500:]}')
    else:
        lines = run.stdout.split('\n')
        check(lines[0] == 'bad 1 false', f'a state whose ShadingValues is a string must be logged once and the rest skipped: {lines[0]!r}')
        check(lines[1] == 'good 1 true 0.25', f'a well-formed state must load without a log: {lines[1]!r}')
        check('NSInvalidArgumentException in -[VRController load3DState]' in run.stderr,
              f'the exception must be logged under -[VRController load3DState]: {run.stderr.strip()!r}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the initializer, -load3DState and the preset apply run under HorosObjCException; a state that raises '
      'is logged and skipped, a good one loads')
