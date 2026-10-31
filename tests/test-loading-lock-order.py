#!/usr/bin/env python3
"""Nothing waits for a worker while holding a lock that worker needs.

The report behind this check is a spindump: the main thread waiting for images to
load, worker threads stopped in `getDicomField` on a lock the main thread held.
That shape - hold a lock, then wait for somebody who needs it - is a deadlock
whenever the two halves are true at once, and no amount of running proves it
absent, because it depends on timing.

So the property is checked in the source instead. Every region that holds a lock
and waits for other threads is found, the work it hands to them is followed to
its implementation, and the region fails if that work takes the same lock. A
region is, in Swift, from `<name>.lock()` (also `lock(whenCondition:)` and
`lock(before:)`) to its `unlock()`, or to the end of the scope when the unlock
is deferred, the closure of `<name>.withLock { }` (NSLock, Mutex,
OSAllocatedUnfairLock), and `os_unfair_lock_lock(&name)` to its unlock; in the
Objective-C left, from `[<name>Lock lock]` to its `unlock`. The work handed over
is a `#selector`/`@selector`, an Operation subclass whose `main` a queue runs, or
a closure given to a queue or a thread together with the functions it calls.
Horos has a handful of such regions today and all of them are safe; one that is
not would fail here.

Waiting on the region's own condition (`condition.wait()` between its lock and
unlock) releases the lock while it waits, so it is not a wait under the lock.

The other half is about the wait itself: `-[ViewerController checkEverythingLoaded]`
spins on the main thread until the loading thread finishes, and it must never be
reached from inside a lock region, because everything the loading thread does is
then behind that lock.

The measured side of the same issue - how long those locks are really held, and
by whom - is `tools/probe-lock-order.m`; a static
rule cannot say anything about that, and a run cannot say anything about this.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []

WAITS = {
    'sleepForTimeInterval': 'sleeps until another thread finishes',
    'Thread.sleep(': 'sleeps until another thread finishes',
    'usleep(': 'sleeps until another thread finishes',
    'waitUntilAllOperationsAreFinished': 'waits for an operation queue',
    'waitUntilFinished': 'waits for a thread or operation',
    'waitUntilDone: YES': 'waits for the main thread',
    'waitUntilDone:YES': 'waits for the main thread',
    'waitUntilDone: true': 'waits for the main thread',
    'runModal': 'runs a modal loop',
    '.sync {': 'waits for a dispatch queue',
    '.sync(execute:': 'waits for a dispatch queue',
    '.wait(': 'waits for a semaphore, group or condition',
}
# -[ViewerController checkEverythingLoaded] is matched as a call, not as a name: the
# viewer's loading state also has a Bool property of that name, read and written
# under its own lock, and an argument label `checkEverythingLoaded:` is no call
# either. A call is `checkEverythingLoaded()`, the message `[viewer
# checkEverythingLoaded]`, or its selector handed to another call.
CHECK_EVERYTHING_LOADED = re.compile(r'\bcheckEverythingLoaded\s*\('
                                     r'|(?<=[\s\]])checkEverythingLoaded\s*\]'
                                     r'|[#@]selector\(\s*(?:[\w.]*\.)?checkEverythingLoaded\s*\)')
WAITS[CHECK_EVERYTHING_LOADED] = 'waits for the loading thread'


def waits_in(wait, body):
    """Whether `body` contains the wait: a literal, or a pattern for one."""
    return bool(wait.search(body)) if isinstance(wait, re.Pattern) else wait in body


# Objective-C.
LOCK = re.compile(r'\[\s*(\w*[Ll]ock)\s+lock\s*\]')
UNLOCK = re.compile(r'\[\s*(\w*[Ll]ock)\s+unlock(?:WithCondition:)?')
SELECTOR = re.compile(r'@selector\(\s*([A-Za-z_]\w*:?)')
# Work is also handed over as an NSOperation rather than a selector, and then the
# body to follow is that class's -main.
OPERATION = re.compile(r'\[\s*\[\s*(\w+)\s+alloc\s*\]')
# Swift. The lock is named by the identifier the call is made on: `lock.lock()`,
# `drawLock?.lock()`, `DicomStudy.dbModifyLock()?.lock()`.
SWIFT_LOCK = re.compile(r'\b(\w+)(?:\(\))?[?!]?\.lock\((?:whenCondition:[^)]*|before:[^)]*)?\)')
SWIFT_WITH = re.compile(r'\b(\w+)(?:\(\))?[?!]?\.withLock(?:Unchecked)?\s*(?:\(\s*)?\{')
SWIFT_UNFAIR = re.compile(r'\bos_unfair_lock_lock\(\s*&\s*(\w+)\s*\)')
SWIFT_SELECTOR = re.compile(r'#selector\(\s*(?:(?:getter|setter):\s*)?(?:[\w.]*\.)?([A-Za-z_]\w*)')
SWIFT_OPERATION_CLASS = re.compile(r'\bclass\s+(\w+)\s*:\s*(?:Foundation\.)?(?:NS)?Operation\b')
# Closures that run on another thread (or on a queue the region may wait for).
HANDOFF = re.compile(r'(?:\.async|\.asyncAfter|\.sync|addOperation|BlockOperation|detachNewThread|\bThread)'
                     r'\s*(?:\([^{}]*?)?\{')
CALL = re.compile(r'\b([a-z_]\w*)\s*\(')

objc = sorted(list((root / 'Horos/Sources').glob('*.m')) + list((root / 'Horos/Sources').glob('*.mm')))
swift = sorted((root / 'Horos/Sources').rglob('*.swift')) + sorted(root.glob('Modules/*/Sources/**/*.swift'))


def blank(text):
    """The Swift text with comments and string literals turned to spaces; line
    breaks stay, so offsets and line numbers still point into the file."""
    out = list(text)
    index, length = 0, len(text)

    def clear(start, end):
        for at in range(start, end):
            if out[at] != '\n':
                out[at] = ' '

    while index < length:
        if text.startswith('//', index):
            end = text.find('\n', index)
            end = length if end < 0 else end
            clear(index, end)
            index = end
        elif text.startswith('/*', index):
            depth, end = 1, index + 2
            while end < length and depth:
                if text.startswith('/*', end):
                    depth, end = depth + 1, end + 2
                elif text.startswith('*/', end):
                    depth, end = depth - 1, end + 2
                else:
                    end += 1
            clear(index, end)
            index = end
        elif text.startswith('"""', index):
            end = text.find('"""', index + 3)
            end = length if end < 0 else end + 3
            clear(index + 1, end - 1)
            index = end
        elif text[index] == '"':
            end = index + 1
            while end < length and text[end] not in '"\n':
                end += 2 if text[end] == '\\' else 1
            clear(index + 1, end)
            index = end + 1
        else:
            index += 1
    return ''.join(out)


def block_end(text, opening):
    """The offset of the brace that closes the one at `opening`."""
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return index
    return len(text)


def scope_end(text, at):
    """The offset of the brace that closes the scope `at` is in."""
    depth = 0
    for index in range(at, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            if depth == 0:
                return index
            depth -= 1
    return len(text)


objc_bodies = {path: path.read_bytes().decode('latin1') for path in objc}
swift_bodies = {path: blank(path.read_text(encoding='utf-8')) for path in swift}


def objc_method(pattern):
    for path, text in objc_bodies.items():
        found = pattern.search(text)
        if not found:
            continue
        rest = text[found.start():]
        # To the next method at column zero, which is close enough to its end.
        end = re.search(r'\n[-+]\s*\(', rest[1:])
        return rest[:end.start() + 1] if end else rest[:8000]
    return None


def swift_functions(name):
    """The bodies of every Swift function called `name`, or exported to
    Objective-C under that selector."""
    found = []
    exported = r'@objc\(%s\)[^{]*?\bfunc\s+\w+' % re.escape(name)
    declaration = re.compile(exported if ':' in name else r'\bfunc\s+%s\b|%s' % (re.escape(name), exported))
    for text in swift_bodies.values():
        for match in declaration.finditer(text):
            opening = text.find('{', match.end())
            if opening >= 0:
                found.append(text[match.start():block_end(text, opening) + 1])
    return found


def implementations(selector):
    """The bodies of the methods with that selector, wherever they are defined."""
    name = selector.rstrip(':')
    bodies = []
    method = objc_method(re.compile(r'^[-+]\s*\([^)]*\)\s*%s[:\s]' % re.escape(name), re.M))
    if method:
        bodies.append(method)
    bodies += swift_functions(name)
    if ':' in selector:
        # An Objective-C selector may be implemented in Swift under @objc(...).
        bodies += swift_functions(selector)
    return bodies


def operation_mains(className):
    """The main of that Operation subclass, which is what an operation queue runs."""
    for path, text in objc_bodies.items():
        at = text.find('@implementation %s\n' % className)
        if at < 0:
            at = text.find('@implementation %s ' % className)
        if at < 0:
            continue
        body = text[at:text.find('\n@end', at) if '\n@end' in text[at:] else at + 20000]
        found = re.search(r'^-\s*\(\s*void\s*\)\s*main\b', body, re.M)
        if not found:
            return []
        rest = body[found.start():]
        end = re.search(r'\n[-+]\s*\(', rest[1:])
        return [rest[:end.start() + 1] if end else rest]
    for text in swift_bodies.values():
        declared = re.search(r'\bclass\s+%s\s*:' % re.escape(className), text)
        if not declared:
            continue
        body = text[declared.start():block_end(text, text.find('{', declared.end())) + 1]
        main = re.search(r'\bfunc\s+main\s*\(\s*\)', body)
        if main:
            return [body[main.start():block_end(body, body.find('{', main.end())) + 1]]
        return []
    return []


operation_classes = sorted({name for text in swift_bodies.values() for name in SWIFT_OPERATION_CLASS.findall(text)})

regions = []
for path, text in objc_bodies.items():
    open_regions = {}
    for number, line in enumerate(text.splitlines(), 1):
        stripped = re.sub(r'//.*', '', line)
        for body in open_regions.values():
            body[1].append(stripped)
        for match in LOCK.finditer(stripped):
            open_regions.setdefault(match.group(1), (number, []))
        for match in UNLOCK.finditer(stripped):
            name = match.group(1)
            if name in open_regions:
                start, body = open_regions.pop(name)
                if number - start > 1:
                    regions.append((path.name, name, start, number, '\n'.join(body)))

for path, text in swift_bodies.items():
    def line(offset):
        return text.count('\n', 0, offset) + 1

    for match in SWIFT_LOCK.finditer(text):
        name = match.group(1)
        # The unlock may reach the lock through a cast: `(lock as? NSLocking)?.unlock()`.
        unlock = re.compile(r'\b%s\b[^;\n{}]{0,30}?\.unlock\(' % re.escape(name))
        after = text[match.end():]
        deferred = re.match(r'[\s;]*defer\s*\{', after)
        if deferred and unlock.search(after[:block_end(after, deferred.end() - 1)]):
            end = scope_end(text, match.end())
        else:
            released = unlock.search(text, match.end())
            if not released:
                continue
            end = released.start()
        # A local that holds the lock is named after where it came from:
        # `let lock = database?.processFilesLock` holds processFilesLock.
        held = re.findall(r'\b(?:let|var)\s+%s\s*=\s*[^\n=]*?(\w+)(?:\(\))?[ \t]*$' % re.escape(name),
                          text[max(0, match.start() - 3000):match.start()], re.M)
        if held and held[-1] != name:
            name = '%s(%s)' % (name, held[-1])
        regions.append((path.name, name, line(match.start()), line(end), text[match.end():end]))
    for match in SWIFT_WITH.finditer(text):
        end = block_end(text, match.end() - 1)
        regions.append((path.name, match.group(1), line(match.start()), line(end), text[match.end():end]))
    for match in SWIFT_UNFAIR.finditer(text):
        released = re.compile(r'\bos_unfair_lock_unlock\(\s*&\s*%s\s*\)' % re.escape(match.group(1))).search(
            text, match.end())
        if released:
            regions.append((path.name, match.group(1), line(match.start()), line(released.start()),
                            text[match.end():released.start()]))

waiting = []
for name, lock, start, end, body in regions:
    # Waiting on the region's own condition gives the lock up while it waits.
    own = re.compile(r'\b%s\b(?:\(\))?[?!]?\.wait\(' % re.escape(re.findall(r'\w+', lock)[0]))
    reasons = sorted({why for wait, why in WAITS.items()
                      if waits_in(wait, own.sub(' ', body) if wait == '.wait(' else body)})
    if reasons:
        waiting.append((name, lock, start, end, body, reasons))

if not waiting:
    failures.append('no region holds a lock across a wait any more, which is either very good '
                    'news or a sign this test stopped looking')

for name, lock, start, end, body, reasons in waiting:
    # The work being waited for: whatever the region hands to other threads. If
    # any of it takes this very lock, the wait cannot end.
    # The lock is not always named directly: `[[ctrl roiLock] lock]`,
    # `[self.mainDatabase processFilesLock]` and `database?.processFilesLock`
    # reach it through an accessor, an ivar spelt `_processFilesLock` is read
    # back as `processFilesLock`, and a Swift property holding a converted ivar
    # is `horos_roiLock` (`horos_static_drawLock` for a class one). Match the
    # name wherever it appears, as long as a blocking `lock` follows it closely.
    # `tryLock`/`try()` and `lock(before:)` are left out on purpose: they give up,
    # so they cannot deadlock.
    # A local alias is followed under the name of the lock it holds.
    core = re.escape(re.sub(r'^(?:_|horos_(?:static_)?)', '', re.findall(r'\w+', lock)[-1]))
    takesTheLock = re.compile(r'(?<![A-Za-z0-9])(?:_|horos_(?:static_)?)?%s\b(?:[^;\n]{0,60}?\block(?:WhenCondition)?\s*[\]:]'
                              r'|[^;\n{}]{0,60}?\.(?:lock\((?:whenCondition:[^)]*)?\)|withLock(?:Unchecked)?\b))'
                              % core)
    for selector in sorted(set(SELECTOR.findall(body)) | set(SWIFT_SELECTOR.findall(body))):
        for worker in implementations(selector):
            if takesTheLock.search(worker):
                failures.append('%s:%d holds %s and waits for %s, which takes %s itself'
                                % (name, start, lock, selector, lock))
                break
    for className in sorted(set(OPERATION.findall(body)) |
                            {c for c in operation_classes if re.search(r'\b%s\s*\(' % re.escape(c), body)}):
        for worker in operation_mains(className):
            if takesTheLock.search(worker):
                failures.append('%s:%d holds %s and waits for %s, whose main takes %s itself'
                                % (name, start, lock, className, lock))
    for handoff in HANDOFF.finditer(body):
        closure = body[handoff.end() - 1:block_end(body, handoff.end() - 1) + 1]
        called = [closure] + [worker for function in sorted(set(CALL.findall(closure)))
                              for worker in swift_functions(function)]
        if any(takesTheLock.search(worker) for worker in called):
            failures.append('%s:%d holds %s and hands another thread work that takes %s itself'
                            % (name, start, lock, lock))

# The loading wait in particular: it spins the main thread until the loading
# thread is done, so a lock held around it is held for a whole series load.
for name, lock, start, end, body, reasons in waiting:
    if CHECK_EVERYTHING_LOADED.search(body):
        failures.append('%s:%d holds %s across -[ViewerController checkEverythingLoaded], which '
                        'waits for the loading thread' % (name, start, lock))

# And it has to still be the spin it is described as, or the paragraph above is
# about something that no longer exists.
# -checkEverythingLoaded is Swift, a façade in ViewerController+StudyNavigation.swift
# of the viewer's ViewerLoadingWait.waitUntilLoaded() there, which spins.
viewer = (root / 'Horos/Sources/ViewerController+StudyNavigation.swift').read_text(encoding='utf-8')
facade = viewer.find('    func checkEverythingLoaded() {')
facade = viewer[facade:viewer.find('\n    }\n', facade)] if facade >= 0 else ''
at = viewer.find('    func waitUntilLoaded() {') if 'ViewerLoadingWait(viewer: self).waitUntilLoaded()' in facade else -1
loop = viewer[at:viewer.find('\n    }\n', at)] if at >= 0 else ''
if not loop:
    failures.append('checkEverythingLoaded is gone')
elif 'Thread.sleep(forTimeInterval:' not in loop or '!(thread?.isFinished ?? true)' not in loop:
    failures.append('checkEverythingLoaded no longer waits on the loading thread the way this '
                    'test assumes')

for failure in failures:
    print('FAIL: %s' % failure)
print('%d region(s) hold a lock across a wait; none waits for work that needs that lock'
      % len(waiting))
for name, lock, start, end, body, reasons in sorted(waiting):
    print('  %-34s %-24s %5d-%-5d %s' % (name, lock, start, end, ', '.join(reasons)))

if failures:
    sys.exit(1)
print('ok: no lock is held across a wait for work that needs it')
