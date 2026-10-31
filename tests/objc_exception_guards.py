"""The guards of HorosObjCException, for the harnesses that compile app code.

Horos/Sources/HorosObjCException+Guards.swift holds every guard the Swift of
the app puts where the Objective-C had @try or @synchronized
(HorosObjCException.caught, .synchronized, .logged, .raisingToCaller,
.throwing, .caughtWithoutAllocation). A harness that builds
HorosObjCException.m takes the real extension with source(); one that does not
takes STAND_IN, which runs each body without catching what it raises.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/HorosObjCException+Guards.swift'


def source(text=None, log=True, perform_function=True):
    """The extension of HorosObjCException+Guards.swift, from its import on.

    `text` is the file as a revision has it (the working tree's when None); a
    revision without the file answers ''. With `log` false the member that
    calls _N2LogExceptionImpl is left out, for a harness that has no such
    function; with `perform_function` false the member that calls
    HorosObjCPerformFunction is, for a double of HorosObjCException without it."""
    if text is None:
        path = ROOT / PATH
        text = path.read_text() if path.exists() else ''
    if isinstance(text, bytes):
        text = text.decode('utf-8')
    if not text:
        return ''
    body = text[text.index('import Foundation'):]
    if not log:
        body = re.sub(r'\n    /// Runs `body` as an @try block whose @catch logs.*?\n    }\n', '\n', body, flags=re.S)
    if not perform_function:
        body = re.sub(r'\n    /// caught\(_:\) through HorosObjCPerformFunction.*?\n    }\n', '\n', body, flags=re.S)
    return body + '\n'


def source_at(revision=None, root=ROOT, log=True):
    """source() of the file as `revision` has it: the working tree's for None,
    '' for a revision from before the file."""
    if revision is None:
        path = Path(root) / PATH
        return source(path.read_text() if path.exists() else '', log)
    done = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{PATH}'], capture_output=True)
    return source(done.stdout if done.returncode == 0 else '', log)


def between(name, text=None, log=False, perform_function=True):
    """The guards for a harness that puts the helpers it takes inside `enum
    name { ... }`: that enum is closed, the guards follow at file scope, and an
    extension of `name` takes the rest of the enum's body."""
    return '}\n' + source(text, log, perform_function).replace('import Foundation\n', '', 1) + 'extension %s {\n' % name


# The guards without the Objective-C class: the body runs and nothing is caught.
STAND_IN = r'''
enum HorosObjCException {
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) { body() }
    static func caughtWithoutAllocation(_ body: () -> Void) -> NSException? { body(); return nil }
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return false }
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T { body() }
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T { body() }
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T { try body() }
}
'''
