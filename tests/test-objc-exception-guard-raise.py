#!/usr/bin/env python3
"""A guard of HorosObjCException that catches an exception lets the process go on.

The handlers of DCMView and PreviewView (the image shown, the mouse, the
keyboard, the drag and drop) run their bodies in a guard and log what it
caught. A guard that hands its closure to Objective-C through
withoutActuallyEscaping and a C function ended the process instead: the Swift
callback of the C function retains the closure to call it, the exception
abandons that frame without the release, and withoutActuallyEscaping stops the
process for a closure that escaped ("closure argument was escaped in
withoutActuallyEscaping block"). So the application closed exactly when the
guard had something to catch, and the report of the crash had no exception in
it.

The checks compile the real Horos/Sources/HorosObjCException+Guards.swift and
HorosObjCException.m, without and with optimization, and call each guard the
event handlers name (read from their sources) the way they call it:
- a body that captures the view and raises (an NSArray read past its end):
  the exception comes back with its name and reason, and the next call works;
- a body that raises nothing: nil, and what the body did is done;
- a body handed on as a parameter before it reaches the guard;
- a guard inside a guard: the inner one catches its own, the outer one what is
  raised after it, and an exception the inner one raises again;
- Objective-C raising under two Swift frames of the body, one of them a closure
  called by the other;
- 10,000 exceptions caught in a row: the process is alive and its memory has
  grown by no more than what the abandoned frames can hold. The growth is
  printed. It is the known price: Swift does not unwind for an Objective-C
  exception, so what the frames between the raise and the catch owned is
  never released;
- as the control, the former shape of the guard, written in the harness: it
  must stop the process, or these checks would not see the defect.
The module's own catcher (DCMHost.catchingObjCException, which finds the
host's class by name) is compiled from its source and held to the same.

The sources are those of the working tree, or of the revision given as the
first argument: `test-objc-exception-guard-raise.py HEAD~1`.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import objc_exception_guards  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

EVENT_SOURCES = ['DCMView.swift', 'DCMView+ImageList.swift', 'DCMView+Mouse.swift', 'DCMView+MouseDragging.swift',
                 'DCMView+MouseTracking.swift', 'DCMView+DragAndDrop.swift', 'DCMView+Keyboard.swift',
                 'DCMView+SeriesSettings.swift', 'PreviewView.swift']
MODULE_CATCHER = 'Modules/IsiXDICOMDataset/Sources/DCMHostServices.swift'
# What 10,000 caught exceptions may add to the footprint of the process: the
# abandoned frames of the harness hold a few small objects each (some 60 bytes
# a caught exception were measured).
GROWTH_LIMIT = 8 * 1024 * 1024

failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


def text(path):
    if revision is None:
        return (root / path).read_text()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')


def code_lines(source):
    """The lines of `source` without those that are only a comment."""
    return [line for line in source.splitlines() if not line.lstrip().startswith('//')]


guards_text = text(objc_exception_guards.PATH)
guards = objc_exception_guards.source(guards_text, log=False)
# The guards that take a body and answer the exception: those a handler calls.
answering = set(re.findall(r'static func (\w+)\(_ body: \(\) -> Void\) -> NSException\?', guards))

used = {}
for name in EVENT_SOURCES:
    source = text('Horos/Sources/' + name)
    for line in code_lines(source):
        for guard in re.findall(r'\bHorosObjCException\.(\w+)\s*[({]', line):
            used.setdefault(guard, set()).add(name)
if not used:
    fail('no handler of DCMView or PreviewView names a guard of HorosObjCException: the list of sources is out of date')
image_list = text('Horos/Sources/DCMView+ImageList.swift')
set_index = image_list[image_list.index('func setIndex(_ index: Int)'):]
first_guard = re.search(r'HorosObjCException\.(\w+)\s*[({]', set_index[:400])
if not first_guard:
    fail('-[DCMView setIndex:] no longer runs in a guard of HorosObjCException')
tested = sorted(set(used) & answering)
for guard in sorted(set(used) - answering - {'logged', 'perform'}):
    fail(f'the handlers call HorosObjCException.{guard}, which these checks do not know how to call')

# No guard lends its body through withoutActuallyEscaping.
for path, source in ((objc_exception_guards.PATH, guards_text), (MODULE_CATCHER, text(MODULE_CATCHER))):
    if any('withoutActuallyEscaping' in line for line in code_lines(source)):
        fail(f'{path} wraps a guarded body in withoutActuallyEscaping: a frame that retains the closure and is '
             'abandoned by the exception stops the process')

# The module's catcher, as its source has it.
catcher_source = text(MODULE_CATCHER)
start = catcher_source.index('    static func catchingObjCException(')
end = catcher_source.index('\n    }\n', start) + len('\n    }\n')
selector = re.search(r'    private static let performSelector = .*\n', catcher_source)
catcher = 'import ObjectiveC\nenum DCMHost {\n' + catcher_source[start:end] + (selector.group(0) if selector else '') + '}\n'

SUPPORT_HEADER = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
/// Raises an NSRangeException with `reason`.
void HarnessRaise(NSString * _Nonnull reason);
/// The physical footprint of the process, in bytes.
uint64_t HarnessFootprint(void);
'''

SUPPORT = r'''
#import "support.h"
#import <mach/mach.h>

void HarnessRaise(NSString *reason)
{
    [NSException raise: NSRangeException format: @"%@", reason];
}

uint64_t HarnessFootprint(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}
'''

HARNESS = r'''
import Foundation

/// The former shape of the guard, the control: the closure lent by
/// withoutActuallyEscaping, called from the Swift callback of a C function.
func formerGuard(_ body: () -> Void) -> NSException? {
    return withoutActuallyEscaping(body) { escapable in
        var call = escapable
        return withUnsafeMutablePointer(to: &call) { pointer in
            HarnessPerformFunction({ context in
                context!.assumingMemoryBound(to: (() -> Void).self).pointee()
            }, pointer)
        }
    }
}

func check(_ condition: Bool, _ what: String) {
    if !condition {
        FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// A view as the handlers see theirs: lists it reads by index, and state the
/// body changes through the `self` it captures.
final class View: NSObject {
    var pixels: NSMutableArray = ["a", "b", "c"]
    var rois: NSMutableArray = [NSMutableArray()]
    var current: AnyObject?
    var shown = 0
    var applying = 0

    /// -setIndex:, as it was: the ROI list read at the index of the pixels.
    func setIndex(_ index: Int) -> NSException? {
        return GUARD {
            self.shown += 1
            self.current = self.pixels.object(at: index) as AnyObject
            self.current = self.rois.object(at: index) as AnyObject
        }
    }

    /// A body handed on before it reaches the guard.
    func whileApplying(_ body: () -> Void) -> NSException? {
        self.applying += 1
        let exception = GUARD(body)
        self.applying -= 1
        return exception
    }

    /// Two Swift frames under the body, the second a closure the first calls.
    func each(_ body: (AnyObject) -> Void) {
        for case let object as AnyObject in self.pixels { body(object) }
    }

    func throughTwoFrames(_ reason: String) -> NSException? {
        return GUARD {
            let held = NSMutableArray(array: self.pixels)
            self.each { object in
                held.add(object)
                if held.count > 4 { HarnessRaise(reason) }
            }
        }
    }
}

let view = View()

switch CommandLine.arguments[1] {
case "quiet":
    for index in 0..<3 { check(view.setIndex(0) == nil && view.shown == index + 1, "a body that raises nothing answered an exception") }
    check(view.whileApplying { view.shown += 1 } == nil && view.shown == 4 && view.applying == 0, "a body handed on did not run")

case "raises":
    for _ in 0..<2 {
        let exception = view.setIndex(1)
        check(exception?.name == .rangeException, "the exception did not come back: \(String(describing: exception))")
        check(exception?.reason?.contains("beyond bounds") == true, "the exception lost its reason: \(exception?.reason ?? "nil")")
    }
    check(view.shown == 2, "the body did not run up to the raise")
    check(view.setIndex(0) == nil, "the guard does not work after it caught")

case "forwarded":
    let exception = view.whileApplying { HarnessRaise("handed on") }
    check(exception?.reason == "handed on" && view.applying == 0, "a body handed on: \(String(describing: exception))")
    check(view.whileApplying { view.shown += 1 } == nil && view.shown == 1, "the guard does not work after it caught")

case "nested":
    var inner: NSException?
    var outer = GUARD {
        inner = GUARD { HarnessRaise("inner") }
        view.shown += 1
        HarnessRaise("outer")
    }
    check(inner?.reason == "inner" && outer?.reason == "outer" && view.shown == 1, "a guard inside a guard: \(String(describing: inner)), \(String(describing: outer))")
    outer = GUARD {
        inner = GUARD { HarnessRaise("inner alone") }
    }
    check(inner?.reason == "inner alone" && outer == nil, "the outer guard answered what the inner one caught")
    // Raised again by the guard that caught it, for the one around it.
    outer = GUARD {
        HorosObjCException.raisingToCaller { HarnessRaise("raised again") }
        view.shown += 1
    }
    check(outer?.reason == "raised again" && view.shown == 1, "an exception raised again: \(String(describing: outer))")
    let lock = NSObject()
    outer = GUARD {
        HorosObjCException.synchronized(lock) { HarnessRaise("under a lock") }
    }
    check(outer?.reason == "under a lock", "an exception raised again from a synchronized body: \(String(describing: outer))")

case "frames":
    for _ in 0..<2 {
        let exception = view.throughTwoFrames("two frames below")
        check(exception?.reason == "two frames below", "Objective-C raising under two Swift frames: \(String(describing: exception))")
    }

case "repeat":
    // The first exceptions pay for what the runtime sets up once.
    for _ in 0..<100 { autoreleasepool { _ = view.throughTwoFrames("warm") } }
    let before = HarnessFootprint()
    var caught = 0
    for index in 0..<10_000 {
        autoreleasepool {
            let exception = index % 2 == 0 ? view.throughTwoFrames("again") : view.setIndex(1)
            if exception != nil { caught += 1 }
        }
    }
    let after = HarnessFootprint()
    check(caught == 10_000, "\(caught) of 10000 exceptions came back")
    print("growth \(after > before ? after - before : 0)")

case "control":
    _ = formerGuard { [view] in
        view.shown += 1
        HarnessRaise("control")
    }
    print("the control survived")

default:
    check(false, "unknown case")
}
'''

CASES = ['quiet', 'raises', 'forwarded', 'nested', 'frames', 'repeat']


def build(directory, name, level, guard, extra=''):
    (directory / name).mkdir()
    main = directory / name / 'main.swift'
    main.write_text(HARNESS.replace('GUARD', guard))
    (directory / name / 'catcher.swift').write_text(extra)
    binary = directory / name / 'harness'
    done = subprocess.run(['xcrun', 'swiftc', level, '-swift-version', '6', '-module-name', 'GuardRaise',
                           '-import-objc-header', str(directory / 'support.h'), '-I', str(directory),
                           str(directory / 'guards.swift'), str(main), str(directory / name / 'catcher.swift'),
                           str(directory / 'exception.o'), str(directory / 'support.o'),
                           '-o', str(binary)], capture_output=True, text=True)
    if done.returncode != 0:
        fail(f'{guard} at {level} does not compile:\n{done.stderr[-3000:]}')
        return None
    return binary


def run(binary, case):
    return subprocess.run([str(binary), case], capture_output=True, text=True, timeout=300)


with tempfile.TemporaryDirectory(prefix='horos-guard-raise-') as name:
    directory = Path(name)
    for file in ('HorosObjCException.h', 'HorosObjCException.m'):
        (directory / file).write_text(text('Horos/Sources/' + file))
    (directory / 'support.h').write_text(SUPPORT_HEADER + 'NSException * _Nullable HarnessPerformFunction(void (* _Nonnull function)'
                                         '(void * _Nullable context), void * _Nullable context);\n')
    (directory / 'support.m').write_text(SUPPORT + '''
NSException *HarnessPerformFunction(void (*function)(void *context), void *context)
{
    @try { function(context); return nil; }
    @catch (NSException *exception) { return exception; }
}
''')
    (directory / 'guards.swift').write_text(guards)
    # The application compiles HorosObjCException.m without ARC.
    for source in ('HorosObjCException.m', 'support.m'):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(directory), str(directory / source),
                        '-o', str(directory / ('exception.o' if source.startswith('Horos') else 'support.o'))], check=True)

    growth = {}
    variants = [(f'HorosObjCException.{guard}', '') for guard in tested] + [('DCMHost.catchingObjCException', catcher)]
    for level in ('-Onone', '-O'):
        for index, (guard, extra) in enumerate(variants):
            binary = build(directory, f'guard{index}{level}', level, guard, extra)
            if binary is None:
                continue
            for case in CASES:
                done = run(binary, case)
                if done.returncode != 0:
                    reason = (done.stderr.strip().splitlines() or ['no message'])[-1]
                    fail(f'{guard} at {level}, {case}: the process ended with {done.returncode}: {reason}')
                elif case == 'repeat':
                    grown = int(done.stdout.split()[-1])
                    growth[(guard, level)] = grown
                    if grown > GROWTH_LIMIT:
                        fail(f'{guard} at {level}: 10,000 caught exceptions added {grown} bytes to the process, above {GROWTH_LIMIT}')
            if index == 0:
                done = run(binary, 'control')
                if done.returncode == 0 or 'escaped' not in done.stderr:
                    fail(f'the control at {level} did not stop the process ({done.returncode}): these checks would not see '
                         'a guard that lends its body through withoutActuallyEscaping')

for (guard, level), grown in sorted(growth.items()):
    print(f'{guard} at {level}: 10,000 caught exceptions added {grown} bytes ({grown / 10_000:.0f} a caught exception)')

if failures:
    print(f'{len(failures)} failure(s)', file=sys.stderr)
    raise SystemExit(1)
print(f'PASS: the guards the event handlers call ({", ".join(tested)}) and the module\'s catcher answer the exception '
      'and the process goes on, without and with optimization')
