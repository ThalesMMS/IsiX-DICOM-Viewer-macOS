#!/usr/bin/env python3
"""A region of a lock that raises leaves the lock for the other threads.

The loading of an image takes PapyrusLock, a recursive lock every image load
and every plugin shares, around the parsed-file cache, the annotations and the
DCMTK reads. An NSException that unwinds a Swift frame does not run its
`defer`: a region written `lock.lock(); defer { lock.unlock() }` that raised
left the lock with its thread, and since the load of a slice catches the
exception and its thread lives on, every other thread waited for ever.
HorosObjCException.locked(_:_:) and .lockedThrowing(_:_:) take the lock round
a caught body instead, leave it, and raise the exception again.

The checks compile the real Horos/Sources/HorosObjCException+Guards.swift and
HorosObjCException.m, without and with optimization, and hold each guard to:
- a body that raises nothing: its value comes back, the lock is the thread's
  while the body runs (another thread cannot take it) and free after;
- a body that raises, Objective-C under two Swift frames of it: the exception
  reaches the caller with its name and reason, another thread takes the lock,
  and the guard works again;
- a region inside a region of the same recursive lock: an exception the inner
  one raises and the outer body catches leaves the lock with the thread until
  the outer region ends; one that crosses both leaves it free, not taken once;
- a thread already waiting for the lock when the region raises: it gets it;
- a body that throws: the error is thrown on and the lock is free; a body
  that may throw and raises instead: the exception is raised, the lock free;
- no lock at all (nil): the body runs and its exception reaches the caller;
- as the control, the former shape of a region, written in the harness (the
  lock left by a `defer`): after an exception another thread must find the
  lock taken, or these checks would not see the defect.

The sources are those of the working tree, or of the revision given as the
first argument: `test-objc-exception-guard-lock.py HEAD~1`.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import objc_exception_guards  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


def text(path):
    if revision is None:
        return (root / path).read_text()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')


SUPPORT_HEADER = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
/// Raises an NSRangeException with `reason`.
void HarnessRaise(NSString * _Nonnull reason);
'''

SUPPORT = r'''
#import "support.h"

void HarnessRaise(NSString *reason)
{
    [NSException raise: NSRangeException format: @"%@", reason];
}
'''

HARNESS = r'''
import Foundation

func check(_ condition: Bool, _ what: String) {
    if !condition {
        FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!)
        exit(1)
    }
}

final class Flag: @unchecked Sendable {
    var value = false
}

/// Whether a thread other than the caller's can take `lock` now. It leaves it
/// at once.
func anotherThreadTakes(_ lock: NSRecursiveLock) -> Bool {
    let taken = Flag()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        taken.value = lock.try()
        if taken.value { lock.unlock() }
        done.signal()
    }
    done.wait()
    return taken.value
}

struct Refused: Error, Equatable {
    let what: String
}

/// The former shape of a region, the control: the lock left by a `defer`.
func formerRegion<T>(_ lock: NSRecursiveLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// Two Swift frames under the body of a region, the second a closure the first
/// calls, and Objective-C raising below them.
func each(_ items: [String], _ body: (String) -> Void) {
    for item in items { body(item) }
}

func raiseUnderTwoFrames(_ reason: String) -> Int {
    let held = NSMutableArray()
    each(["a", "b", "c"]) { item in
        held.add(item)
        if held.count > 2 { HarnessRaise(reason) }
    }
    return held.count
}

// PapyrusLock is a recursive lock, taken as NSLocking by the guard.
let lock = NSRecursiveLock()

switch CommandLine.arguments[1] {
case "quiet":
    var free = true
    let value = HorosObjCException.locked(lock) { () -> Int in
        free = anotherThreadTakes(lock)
        return 7
    }
    check(value == 7, "the value of the body did not come back: \(value)")
    check(!free, "the body ran without the lock: another thread took it meanwhile")
    check(anotherThreadTakes(lock), "the lock is still taken after a region that raised nothing")

case "raises":
    for round in 0..<2 {
        var reached = 0
        let raised = HorosObjCException.caught {
            reached = 1
            reached = HorosObjCException.locked(lock) { raiseUnderTwoFrames("in the region \(round)") }
            reached = 2
        }
        check(raised?.name == .rangeException && raised?.reason == "in the region \(round)",
              "the exception of the region did not reach the caller: \(String(describing: raised))")
        check(reached == 1, "the caller went on after the region raised")
        check(anotherThreadTakes(lock), "an exception raised in a region left the lock with its thread")
    }
    check(HorosObjCException.locked(lock) { 3 } == 3 && anotherThreadTakes(lock), "the guard does not work after it raised")

case "recursive":
    var inner: NSException?
    var heldAfterInner = false
    HorosObjCException.locked(lock) {
        inner = HorosObjCException.caught {
            HorosObjCException.locked(lock) { HarnessRaise("inner region") }
        }
        heldAfterInner = !anotherThreadTakes(lock)
    }
    check(inner?.reason == "inner region", "the inner region did not raise its exception again: \(String(describing: inner))")
    check(heldAfterInner, "an exception of the inner region took the lock from the outer one")
    check(anotherThreadTakes(lock), "the lock is still taken after the outer region")
    let crossing = HorosObjCException.caught {
        HorosObjCException.locked(lock) {
            HorosObjCException.locked(lock) { HarnessRaise("both regions") }
        }
    }
    check(crossing?.reason == "both regions", "an exception that crosses two regions was lost: \(String(describing: crossing))")
    check(anotherThreadTakes(lock), "an exception that crossed two regions of the lock left it taken")

case "waiter":
    // The loading thread that waited for ever: it asks for the lock while the
    // region that will raise holds it.
    let waiting = DispatchSemaphore(value: 0)
    let got = DispatchSemaphore(value: 0)
    let raised = HorosObjCException.caught {
        HorosObjCException.locked(lock) {
            Thread.detachNewThread {
                waiting.signal()
                lock.lock()
                lock.unlock()
                got.signal()
            }
            waiting.wait()
            Thread.sleep(forTimeInterval: 0.2)
            HarnessRaise("with a thread waiting")
        }
    }
    check(raised?.reason == "with a thread waiting", "the exception was lost: \(String(describing: raised))")
    check(got.wait(timeout: .now() + 10) == .success, "a thread that waited for the lock of a region that raised never got it")

case "throwing":
    let value = try? HorosObjCException.lockedThrowing(lock) { () throws -> Int in 5 }
    check(value == 5 && anotherThreadTakes(lock), "a throwing region that threw nothing: \(String(describing: value))")
    var thrown: Error?
    do {
        _ = try HorosObjCException.lockedThrowing(lock) { () throws -> Int in throw Refused(what: "thrown") }
    } catch {
        thrown = error
    }
    check(thrown as? Refused == Refused(what: "thrown"), "the error of a throwing region was not thrown on: \(String(describing: thrown))")
    check(anotherThreadTakes(lock), "an error thrown in a region left the lock taken")
    thrown = nil
    let raised = HorosObjCException.caught {
        do {
            _ = try HorosObjCException.lockedThrowing(lock) { () throws -> Int in raiseUnderTwoFrames("raised, not thrown") }
        } catch {
            thrown = error
        }
    }
    check(raised?.reason == "raised, not thrown" && thrown == nil,
          "an exception of a throwing region: \(String(describing: raised)), \(String(describing: thrown))")
    check(anotherThreadTakes(lock), "an exception raised in a throwing region left the lock with its thread")

case "none":
    check(HorosObjCException.locked(nil) { 9 } == 9, "a region of no lock did not run its body")
    let raised = HorosObjCException.caught {
        HorosObjCException.locked(nil) { HarnessRaise("no lock") }
    }
    check(raised?.reason == "no lock", "the exception of a region of no lock: \(String(describing: raised))")

case "control":
    let raised = HorosObjCException.caught {
        _ = formerRegion(lock) { raiseUnderTwoFrames("control") }
    }
    check(raised?.reason == "control", "the control raised nothing")
    print(anotherThreadTakes(lock) ? "the control left the lock free" : "the control left the lock taken")

default:
    check(false, "unknown case")
}
'''

CASES = ['quiet', 'raises', 'recursive', 'waiter', 'throwing', 'none']

guards_text = text(objc_exception_guards.PATH)
guards = objc_exception_guards.source(guards_text, log=False)
for guard in ('locked', 'lockedThrowing'):
    if f'static func {guard}<T>(_ lock: NSLocking?' not in guards:
        fail(f'{objc_exception_guards.PATH} has no HorosObjCException.{guard}(_:_:) taking the lock as NSLocking?')


def build(directory, level):
    binary = directory / ('harness' + level)
    done = subprocess.run(['xcrun', 'swiftc', level, '-swift-version', '6', '-module-name', 'GuardLock',
                           '-import-objc-header', str(directory / 'support.h'), '-I', str(directory),
                           str(directory / 'guards.swift'), str(directory / 'main.swift'),
                           str(directory / 'exception.o'), str(directory / 'support.o'),
                           '-o', str(binary)], capture_output=True, text=True)
    if done.returncode != 0:
        fail(f'the harness at {level} does not compile:\n{done.stderr[-3000:]}')
        return None
    return binary


def run(binary, case):
    return subprocess.run([str(binary), case], capture_output=True, text=True, timeout=120)


if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-guard-lock-') as name:
        directory = Path(name)
        for file in ('HorosObjCException.h', 'HorosObjCException.m'):
            (directory / file).write_text(text('Horos/Sources/' + file))
        (directory / 'support.h').write_text(SUPPORT_HEADER)
        (directory / 'support.m').write_text(SUPPORT)
        (directory / 'guards.swift').write_text(guards)
        (directory / 'main.swift').write_text(HARNESS)
        # The application compiles HorosObjCException.m without ARC.
        for source in ('HorosObjCException.m', 'support.m'):
            subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(directory), str(directory / source),
                            '-o', str(directory / ('exception.o' if source.startswith('Horos') else 'support.o'))], check=True)

        for level in ('-Onone', '-O'):
            binary = build(directory, level)
            if binary is None:
                continue
            for case in CASES:
                try:
                    done = run(binary, case)
                except subprocess.TimeoutExpired:
                    fail(f'at {level}, {case}: the harness did not finish: a thread waits for a lock that was not left')
                    continue
                if done.returncode != 0:
                    reason = (done.stderr.strip().splitlines() or ['no message'])[-1]
                    fail(f'at {level}, {case}: the process ended with {done.returncode}: {reason}')
            done = run(binary, 'control')
            if done.returncode != 0 or 'left the lock taken' not in done.stdout:
                fail(f'the control at {level} did not leave its lock taken ({done.returncode}: {done.stdout.strip()} '
                     f'{done.stderr.strip()[-300:]}): these checks would not see a region that leaves its lock by a defer')

if failures:
    print(f'{len(failures)} failure(s)', file=sys.stderr)
    raise SystemExit(1)
print('PASS: a region of HorosObjCException.locked or .lockedThrowing that raises leaves its recursive lock to the '
      'other threads and raises the exception again, without and with optimization')
