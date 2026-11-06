#!/usr/bin/env python3
"""A modal never opens inside a block of the main queue or of a main-actor task.

A modal loop run from such a block serves neither the queue nor the main actor:
until someone answers, everything that waits for them stops, on a Mac with nobody
at it too. A modal goes through `onMainRunLoop`, which runs it from the main run
loop and leaves both served.

Every .swift file of Horos/Sources is read through `swift_code` of
tools/swift-idiom-indicator.py, so comments and strings do not count and a brace
inside them does not end a block. Inside the closure of
`DispatchQueue.main.async`, `.sync` or `.asyncAfter`, of `Task { @MainActor`, in
any of its forms, of `MainActor.run`, or of `onMainActor` and `onMainActorSync`,
which go through the main queue when called off the main thread, these calls
are refused: `runModal`,
`runModalSession`, `HorosAlertPanel.run*`, the `NSRun...AlertPanel` functions and
their bridges, and `presentError`. An `onMainRunLoop` nested in the block has left
it, and what it holds is not refused.

LISTED holds what is still there, file by file, with the reason: it is what is
left to do, printed on every run. Its count is exact. One more in a listed file
is refused, like one in any other file, and an entry above what the file holds
is refused too, so that it cannot leave room for a new modal: whoever moves a
modal out lowers its entry in the same change.

MOVED names the panels that went through `onMainRunLoop`: a file that loses one
fails, so a panel cannot pass here by going somewhere this test does not read.

INDIRECT names calls of functions that open a modal and that a block of the main
queue used to make: each must stay inside an `onMainRunLoop` block, and not in a
block of the queue or of the main actor nested in it.

This reads calls where they are written. It does not see a modal in a function
called from a block, unless INDIRECT names that call, a plain `Task {` that
inherits the main actor from its caller, or a queue held in a variable.

The scan is checked on small programs that must be refused and accepted, and on
mutations of the real sources.
"""
from functools import lru_cache
import importlib.util
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

SOURCES = root / 'Horos/Sources'

LISTED = {
}

MOVED = {
    'Horos/Sources/ActivitySendTransport.swift': 1,
    'Horos/Sources/ArchiveImport.swift': 2,
    'Horos/Sources/BonjourBrowser.swift': 1,
    'Horos/Sources/DatabaseRoutingDelivery.swift': 1,
    'Horos/Sources/DICOMwebNodeEditor.swift': 1,
    'Horos/Sources/DICOMwebSendActivity.swift': 1,
    'Horos/Sources/ICloudDriveDetector.swift': 3,
    'Horos/Sources/PagesApplication.swift': 1,
    'Horos/Sources/PluginManager.swift': 2,
    'Horos/Sources/QueryArrayController.swift': 1,
    'Horos/Sources/Reports.swift': 1,
    'Horos/Sources/ViewerOpener.swift': 1,
}

INDIRECT = {
    'Horos/Sources/AnonymizationErrorPresenter.swift': ('presentOnMainActor(supplied)',),
    'Horos/Sources/ArchiveImport.swift': ('ArchiveImport.offerToDelete(archive,',),
    'Horos/Sources/PluginManagerController.swift': ('self.finishDownload(',),
    'Horos/Sources/RISRequestAlert.swift': ('present(text)',),
    'Horos/Sources/UpdateInstaller.swift': ('self?.downloaded(result)', 'self.verified(outcome)'),
}

ON_MAIN = re.compile(r'\bDispatchQueue\s*\.\s*main\s*\.\s*(?:async|sync|asyncAfter)\b'
                     r'|\bMainActor\s*\.\s*run\b'
                     r'|(?<!func )\bonMainActor(?:Sync)?\b')
MAIN_ACTOR_TASK = re.compile(r'\bTask(?:\s*\.\s*detached)?\s*(?:\((?:[^()]|\([^()]*\))*\)\s*)?\{\s*@MainActor\b')
RUN_LOOP = re.compile(r'\bonMainRunLoop(?:Sync)?\b')
MODAL = re.compile(r'\brunModal(?:Session)?\s*\('
                   r'|\bHorosAlertPanel\s*\.\s*run\w*\s*\('
                   r'|\b(?:NS|Horos)Run\w*AlertPanel\w*\s*\('
                   r'|\bpresentError\s*\(')


def closure_after(code, at):
    """The `{` of the closure given to the call whose name ends at `at`, as an
    argument or trailing; None when it is given none, as `async(execute: work)`."""
    depth = 0
    for index in range(at, len(code)):
        character = code[index]
        if character == '{':
            return index
        if character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
            if depth == 0:
                following = code[index + 1:].lstrip()
                return len(code) - len(following) if following.startswith('{') else None
        elif depth == 0 and not character.isspace():
            return None
    return None


def closing_brace(code, opening):
    depth = 0
    for index in range(opening, len(code)):
        depth += (code[index] == '{') - (code[index] == '}')
        if depth == 0:
            return index
    return len(code)


def blocks(code, pattern, start=0, end=None):
    """(first, last) of each closure of a call that `pattern` matches."""
    found = []
    for call in pattern.finditer(code, start, len(code) if end is None else end):
        # The task's pattern ends inside its closure, at the attribute.
        opening = code.rindex('{', 0, call.end()) if pattern is MAIN_ACTOR_TASK else closure_after(code, call.end())
        if opening is not None:
            found.append((opening, closing_brace(code, opening)))
    return found


def line_of(code, at):
    return code.count('\n', 0, at) + 1


@lru_cache(maxsize=None)
def modals_on_main(text):
    """The line and the call of each modal inside a block of the queue or of the main actor."""
    code = indicator.swift_code(text)
    found = {}
    for first, last in blocks(code, ON_MAIN) + blocks(code, MAIN_ACTOR_TASK):
        left = blocks(code, RUN_LOOP, first, last)
        for modal in MODAL.finditer(code, first, last):
            if not any(start < modal.start() < end for start, end in left):
                found[modal.start()] = (line_of(code, modal.start()), re.sub(r'\s+|\($', '', modal.group()))
    return [found[at] for at in sorted(found)]


def left_on_main(code, at):
    """Whether `at` is inside a block of the queue or of the main actor, and not
    inside an `onMainRunLoop` block nested in it."""
    for first, last in blocks(code, ON_MAIN) + blocks(code, MAIN_ACTOR_TASK):
        if first < at < last and not any(start < at < end for start, end in blocks(code, RUN_LOOP, first, last)):
            return True
    return False


@lru_cache(maxsize=None)
def indirect_calls(text, call):
    """(on the run loop, left on the main queue) for each place `call` is written."""
    code = indicator.swift_code(text)
    run_loop = blocks(code, RUN_LOOP)
    return [(any(first < at < last for first, last in run_loop), left_on_main(code, at))
            for at in (found.start() for found in re.finditer(re.escape(call), code))]


@lru_cache(maxsize=None)
def modals_on_run_loop(text):
    """How many modals are inside an `onMainRunLoop` block."""
    code = indicator.swift_code(text)
    inside = [modal.start() for first, last in blocks(code, RUN_LOOP) for modal in MODAL.finditer(code, first, last)]
    return len(set(inside))


def problems(sources, listed=LISTED, moved=MOVED, indirect=INDIRECT):
    """What is wrong with `sources`, {path: text}, for that list."""
    wrong = []
    for path, text in sources.items():
        found = modals_on_main(text)
        allowed = listed[path]['count'] if path in listed else 0
        if len(found) > allowed:
            wrong.extend('%s:%d: %s inside a block of the main queue or of the main actor; use onMainRunLoop'
                         % (path, line, call) for line, call in found)
        elif len(found) < allowed:
            wrong.append('%s: the list allows %d and the file holds %d; lower its entry' % (path, allowed, len(found)))
    for path, entry in listed.items():
        if path not in sources:
            wrong.append('%s: listed, and the file is gone' % path)
        if len(entry['reason'].split()) < 4:
            wrong.append('%s: its entry has no reason' % path)
    for path, count in moved.items():
        if path not in sources:
            wrong.append('%s: its panels went through onMainRunLoop, and the file is gone' % path)
        elif modals_on_run_loop(sources[path]) < count:
            wrong.append('%s: fewer than %d panels go through onMainRunLoop' % (path, count))
    for path, calls in indirect.items():
        if path not in sources:
            wrong.append('%s: it makes calls that open a modal, and the file is gone' % path)
            continue
        for call in calls:
            places = indirect_calls(sources[path], call)
            if not places:
                wrong.append('%s: %s, which opens a modal, is no longer made; update INDIRECT' % (path, call))
            elif not all(run_loop and not on_main for run_loop, on_main in places):
                wrong.append('%s: %s opens a modal and is made outside onMainRunLoop' % (path, call))
    return wrong


failures = []

# --- what must be refused ------------------------------------------------------
REFUSED = {
    'async': 'DispatchQueue.main.async {\n    NSAlert().runModal()\n}\n',
    'sync': 'DispatchQueue.main.sync { _ = alert.runModal() }\n',
    'asyncAfter': 'DispatchQueue.main.asyncAfter(deadline: .now() + 1) {\n    panel.runModal()\n}\n',
    'asyncAfter over two lines': 'DispatchQueue.main.asyncAfter(\n    deadline: .now() + (1 + 1)) {\n    panel.runModal()\n}\n',
    'closure as an argument': 'DispatchQueue.main.async(execute: {\n    panel.runModal()\n})\n',
    'weak capture': 'DispatchQueue.main.async { [weak self] in\n    self?.panel.runModal()\n}\n',
    'task': 'Task { @MainActor in\n    alert.runModal()\n}\n',
    'task with a capture': 'Task { @MainActor [weak self] in\n    self?.alert.runModal()\n}\n',
    'task with a priority': 'Task(priority: .high) { @MainActor in\n    alert.runModal()\n}\n',
    'detached task': 'Task.detached { @MainActor in\n    alert.runModal()\n}\n',
    'task on two lines': 'Task {\n    @MainActor in\n    alert.runModal()\n}\n',
    'MainActor.run': 'await MainActor.run {\n    alert.runModal()\n}\n',
    'HorosAlertPanel.run': 'DispatchQueue.main.async { HorosAlertPanel.run(title: "", message: "") }\n',
    'runCritical': 'DispatchQueue.main.async { _ = HorosAlertPanel.runCritical(title: "", message: "") }\n',
    'runInformational': 'Task { @MainActor in HorosAlertPanel\n    .runInformational(title: "", message: "") }\n',
    'NSRunAlertPanel': 'DispatchQueue.main.async { NSRunAlertPanel("", "", nil, nil, nil) }\n',
    'NSRunCriticalAlertPanel': 'DispatchQueue.main.async { NSRunCriticalAlertPanel("", "", nil, nil, nil) }\n',
    'NSRunInformationalAlertPanel': 'DispatchQueue.main.async { NSRunInformationalAlertPanel("", "", nil, nil, nil) }\n',
    'the bridge': 'DispatchQueue.main.async { HorosRunCriticalAlertPanel("", "", nil, nil, nil) }\n',
    'application modal for a window': 'DispatchQueue.main.async { NSApp.runModal(for: window) }\n',
    'modal session': 'DispatchQueue.main.async { NSApp.runModalSession(session) }\n',
    'presentError': 'DispatchQueue.main.async { NSApp.presentError(error) }\n',
    'deep in the block': 'DispatchQueue.main.async {\n    if a {\n        for b in c { d(b) }\n    } else {\n'
                         '        alert.runModal()\n    }\n}\n',
    'after a brace in a string': 'DispatchQueue.main.async {\n    print("}")\n    alert.runModal()\n}\n',
    'after a brace in a comment': 'DispatchQueue.main.async {\n    // }\n    alert.runModal()\n}\n',
    'in an interpolation': 'DispatchQueue.main.async {\n    print("\\(alert.runModal())")\n}\n',
    'in a closure of the block': 'DispatchQueue.main.async {\n    items.forEach { _ in alert.runModal() }\n}\n',
    'in a block inside a run-loop block': 'onMainRunLoop {\n    DispatchQueue.main.async {\n'
                                          '        alert.runModal()\n    }\n}\n',
    'beside a run-loop block': 'DispatchQueue.main.async {\n    onMainRunLoop { done() }\n    alert.runModal()\n}\n',
    'onMainActorSync': 'onMainActorSync {\n    alert.runModal()\n}\n',
    'onMainActorSync in parentheses': 'if onMainActorSync({ alert.runModal() }) == .OK { done() }\n',
    'onMainActor': 'onMainActor { [weak self] in\n    self?.alert.runModal()\n}\n',
}
for name, program in REFUSED.items():
    if not modals_on_main(program):
        failures.append('a modal passed: %s' % name)

# --- what must be accepted -----------------------------------------------------
ACCEPTED = {
    'the run loop': 'onMainRunLoop {\n    alert.runModal()\n}\n',
    'the run loop, waiting': 'let answer = onMainRunLoopSync { alert.runModal() }\n',
    'a run-loop block inside a block': 'DispatchQueue.main.async {\n    onMainRunLoop {\n        alert.runModal()\n    }\n}\n',
    'a run-loop block inside a task': 'Task { @MainActor in\n    onMainRunLoop { alert.runModal() }\n}\n',
    'no block': 'func answer() {\n    alert.runModal()\n}\n',
    'after the block': 'DispatchQueue.main.async {\n    work()\n}\nalert.runModal()\n',
    'before the block': 'alert.runModal()\nDispatchQueue.main.async { work() }\n',
    'a block with no closure': 'DispatchQueue.main.async(execute: work)\nalert.runModal()\n',
    'a block with no modal': 'DispatchQueue.main.async {\n    window.close()\n}\n',
    'a sheet': 'DispatchQueue.main.async {\n    alert.beginSheetModal(for: window) { _ in }\n}\n',
    'another queue': 'DispatchQueue.global().async {\n    alert.runModal()\n}\n',
    'a task of its own': 'Task.detached {\n    await work()\n}\nalert.runModal()\n',
    'a line comment': 'DispatchQueue.main.async {\n    // alert.runModal()\n}\n',
    'a nested block comment': 'DispatchQueue.main.async {\n    /* a /* b */ alert.runModal() */\n}\n',
    'a string': 'DispatchQueue.main.async {\n    print("alert.runModal()")\n}\n',
    'a raw string': 'DispatchQueue.main.async {\n    print(#"alert.runModal()"#)\n}\n',
    'a multi-line string': 'DispatchQueue.main.async {\n    print("""\n    alert.runModal()\n    """)\n}\n',
    'a block quoted in a string': 'print("DispatchQueue.main.async {")\nalert.runModal()\n',
    'a block quoted in a comment': '// DispatchQueue.main.async {\nalert.runModal()\n// }\n',
    'a similar name': 'DispatchQueue.main.async {\n    alert.runModally()\n    alert.dontRunModal()\n}\n',
    'onMainActorSync with no modal': 'let window = onMainActorSync { NSApp.mainWindow }\nalert.runModal()\n',
    'a run-loop block inside onMainActor': 'onMainActor {\n    onMainRunLoop { alert.runModal() }\n}\n',
    'the definition of onMainActor': 'func onMainActor(_ body: @escaping () -> Void) {\n    body()\n}\nalert.runModal()\n',
}
for name, program in ACCEPTED.items():
    found = modals_on_main(program)
    if found:
        failures.append('%s was refused: %r' % (name, found))

if modals_on_main('DispatchQueue.main.async {\n    work()\n    alert.runModal()\n}\n') != [(3, 'runModal')]:
    failures.append('a modal is not reported at its own line')
nested = 'DispatchQueue.main.async {\n    DispatchQueue.main.async {\n        alert.runModal()\n    }\n}\n'
if len(modals_on_main(nested)) != 1:
    failures.append('a modal inside two blocks counts twice')

# --- the sources as they are ---------------------------------------------------
sources = {path.relative_to(root).as_posix(): path.read_text(encoding='utf-8', errors='replace')
           for path in sorted(SOURCES.rglob('*.swift'))}
if len(sources) < 100:
    failures.append('only %d Swift files under Horos/Sources: the scan has lost its way' % len(sources))
failures.extend(problems(sources))

# --- mutations of the real sources, each of which must be refused --------------
def refused(mutated, listed=LISTED, moved=MOVED):
    return bool(problems(mutated, listed, moved))


# The mutations start from a tree that passes, so that each failure is its own.
baseline = problems(sources)
# Every `onMainRunLoop` of the file goes back, since not all of them hold a panel.
for path in MOVED:
    mutant = {**sources, path: re.sub(r'\bonMainRunLoop(?:Sync)?\s*\{', 'DispatchQueue.main.async {', sources[path])}
    if len(problems(mutant)) <= len(baseline):
        failures.append('a panel back on the main queue passed in %s' % path)
    mutant = {**sources, path: re.sub(r'\bonMainRunLoop(?:Sync)?\s*\{', 'Task { @MainActor in', sources[path])}
    if len(problems(mutant)) <= len(baseline):
        failures.append('a panel in a main-actor task passed in %s' % path)

NEW_CASE = '\nfunc added() {\n    DispatchQueue.main.async {\n        NSAlert().runModal()\n    }\n}\n'
# The list is checked on a sample entry, which holds one case, beside what it lists.
listed_file = 'Horos/Sources/ASampleListedFile.swift'
listed_sources = {**sources, listed_file: NEW_CASE}
listed = {**LISTED, listed_file: {'count': 1, 'reason': 'a sample entry for the checks of the list'}}
if problems(listed_sources, listed) != baseline:
    failures.append('a listed case was refused')
for path in ('Horos/Sources/AppController.swift', 'Horos/Sources/ANewFile.swift', listed_file):
    mutant = {**listed_sources, path: listed_sources.get(path, '') + NEW_CASE}
    if len(problems(mutant, listed)) <= len(baseline):
        failures.append('a new case in %s passed' % path)

stale = {path: dict(entry) for path, entry in listed.items()}
stale[listed_file]['count'] += 1
if len(problems(listed_sources, stale)) <= len(baseline):
    failures.append('an entry above what its file holds passed')
gone = {**listed, 'Horos/Sources/NoSuchFile.swift': {'count': 1, 'reason': 'a file that is not there'}}
if len(problems(listed_sources, gone)) <= len(baseline):
    failures.append('an entry for a file that is gone passed')
silent = {path: dict(entry) for path, entry in listed.items()}
silent[listed_file]['reason'] = 'later'
if len(problems(listed_sources, silent)) <= len(baseline):
    failures.append('an entry without a reason passed')
for path in MOVED:
    code = re.sub(r'\bonMainRunLoop(?:Sync)?\b', 'elsewhere', sources[path])
    if len(problems({**sources, path: code})) <= len(baseline):
        failures.append('a panel that left onMainRunLoop for a function this test does not read passed in %s' % path)

# A call that opens a modal, back on the main queue, in a main-actor task, or
# made where neither is, each must be refused.
for path in INDIRECT:
    for new in ('DispatchQueue.main.async {', 'Task { @MainActor in', 'elsewhere {'):
        code = re.sub(r'\bonMainRunLoop(?:Sync)?\s*\{', new, sources[path])
        if len(problems({**sources, path: code})) <= len(baseline):
            failures.append('a call that opens a modal passed in %s, with its block turned into %r' % (path, new))
    first = INDIRECT[path][0]
    if len(problems({**sources, path: sources[path].replace(first, 'renamed(')})) <= len(baseline):
        failures.append('%s passed without %s' % (path, first))
nested = 'onMainRunLoop {\n    DispatchQueue.main.async {\n        offer(toDeleteZIPFile: archive)\n    }\n}\n'
if indirect_calls(nested, 'offer(toDeleteZIPFile: archive)') != [(True, True)]:
    failures.append('a call in a block of the queue inside a run-loop block was not seen')

# The group that onMainActorSync used to hold, back in it, must be refused.
for path in ('Horos/Sources/BonjourBrowser.swift', 'Horos/Sources/PluginManager.swift',
             'Horos/Sources/QueryArrayController.swift'):
    code = re.sub(r'\bonMainRunLoopSync\b', 'onMainActorSync', sources[path])
    if len(problems({**sources, path: code})) <= len(baseline):
        failures.append('a panel back in onMainActorSync passed in %s' % path)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
for path, entry in sorted(LISTED.items()):
    print('still listed: %s (%d): %s' % (path, entry['count'], entry['reason']))
print('ok: no modal opens inside the main queue or a main-actor task outside the list, over %d files, '
      '%d calls that open one stay on the main run loop, '
      'and %d programs and the mutations of the sources are answered as they must be'
      % (len(sources), sum(len(calls) for calls in INDIRECT.values()), len(REFUSED) + len(ACCEPTED)))
