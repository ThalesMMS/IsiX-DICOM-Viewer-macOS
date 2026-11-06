#!/usr/bin/env python3
"""Who keeps a viewer opened by +[ViewerController newWindow:::].

newWindow::: hands over the +1 of the viewer's alloc, and the viewer releases
itself when its window closes. The selector is in the new family, so Swift
takes that +1 over and releases it when the result goes out of use: a Swift
caller that does not keep it leaves the viewer released twice, and closing
its window crashes. Every Swift call through the imported method must
therefore hand the viewer back with Unmanaged.passRetained, as the former
Objective-C, which never released it, left it.

Callers that go through the method's implementation with an Unmanaged result
(takeUnretainedValue) do not take the +1 over and need nothing, and neither
do the newWindow::: variants that answer one another's viewer.

A viewer bound by a guard is kept after the guard: the scan accepts
`guard let name = ...newWindow(...) else { ... }` only when the call is the
guard's single condition and `_ = Unmanaged.passRetained(name)` is the first
statement after the else block, so that no path leaves with the viewer
unkept. The snippets below hold the scan to that.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
call = re.compile(r'(?<![\w"])(?:ViewerController\.|self\.|\b)newWindow\(')
guard_binding = re.compile(r'\s*guard\s+let\s+(\w+)\s*=\s*(?:\w+\.)*newWindow\(')
guard_else = re.compile(r'\s*else\s*\{')


def bare(line):
    """The line without its comment, its string literals emptied: what is
    left can be searched for brackets and statements."""
    out = []
    quoted = False
    position = 0
    while position < len(line):
        character = line[position]
        if quoted:
            if character == '\\':
                position += 1
            elif character == '"':
                quoted = False
                out.append(character)
        elif character == '"':
            quoted = True
            out.append(character)
        elif line.startswith('//', position):
            break
        else:
            out.append(character)
        position += 1
    return ''.join(out)


def closing(text, start, opener, closer):
    """The index after the bracket that closes the one opened at `start`."""
    depth = 0
    for position in range(start, len(text)):
        if text[position] == opener:
            depth += 1
        elif text[position] == closer:
            depth -= 1
            if depth == 0:
                return position + 1
    return None


def kept_after_guard(lines, number):
    """Whether the guard at `number` binds the viewer of newWindow alone and
    the statement after its else block keeps that viewer."""
    text = '\n'.join(bare(line) for line in lines[number:])
    binding = guard_binding.match(text)
    if not binding:
        return False
    # Any further condition could fail with the viewer already opened.
    call_end = closing(text, binding.end() - 1, '(', ')')
    if call_end is None:
        return False
    otherwise = guard_else.match(text, call_end)
    if not otherwise:
        return False
    block_end = closing(text, otherwise.end() - 1, '{', '}')
    if block_end is None:
        return False
    statements = [line.strip() for line in text[block_end:].split('\n')]
    following = next((line for line in statements if line), '')
    return re.fullmatch(rf'_\s*=\s*Unmanaged\.passRetained\({binding.group(1)}\)', following) is not None


def scan(lines):
    """The numbers of the lines that call newWindow, and of those among them
    whose viewer is not kept."""
    calls, unkept = [], []
    for number, line in enumerate(lines):
        code = line.split('//', 1)[0]
        if not call.search(code) or 'func newWindow' in code:
            continue
        # One newWindow::: variant answering another hands the +1 on to its caller.
        if code.strip().startswith('return '):
            continue
        calls.append(number + 1)
        if code.strip().startswith('guard'):
            kept = kept_after_guard(lines, number)
        else:
            window = '\n'.join(lines[number:number + 4])
            # A viewer assigned to a name may be kept once after the branches that
            # make it: Unmanaged.passRetained(name) within the next lines.
            assigned = re.match(r'\s*(?:let\s+|var\s+)?(\w+)\s*=', code)
            kept_later = bool(assigned) and f'Unmanaged.passRetained({assigned.group(1)})' in '\n'.join(lines[number:number + 20])
            kept = 'Unmanaged.passRetained' in window or kept_later
        if not kept:
            unkept.append(number + 1)
    return calls, unkept


GUARD = '''\
guard let opened = ViewerController.newWindow(copied.pixels, viewer.fileList(at: movie), copied.volume) else {
    fail(NSLocalizedString("There is not enough memory {for the series.", comment: ""))
    return
}
'''
KEEP = '''\
// The viewer releases itself when its window closes.

_ = Unmanaged.passRetained(opened)
opened.setPostprocessed(true)
'''
# What the snippet shows, the snippet, and whether its viewer is kept.
controls = [
    ('a viewer kept in the statement of its if let',
     'if let viewer = ViewerController.newWindow(pixels, files, volume) { _ = Unmanaged.passRetained(viewer) }\n', True),
    ('a viewer nobody keeps',
     'let viewer = ViewerController.newWindow(pixels, files, volume)\nviewer?.window?.makeKeyAndOrderFront(nil)\n', False),
    ('a viewer kept right after the guard that binds it', GUARD + KEEP, True),
    ('a viewer kept right after a one-line guard',
     'guard let made = viewer.newWindow(pixels, files, volume) else { return false }\n_ = Unmanaged.passRetained(made)\n', True),
    ('a viewer kept after a guard whose call and else take several lines',
     'guard let made = ViewerController.newWindow(pixels, list(of: files),\n'
     '                                           volume)\n'
     'else {\n    return\n}\n_ = Unmanaged.passRetained(made)\n', True),
    ('a guard-bound viewer never kept', GUARD + 'opened.setPostprocessed(true)\n', False),
    ('a guard-bound viewer never kept, next to the retain of something else',
     'guard let made = viewer.newWindow(pixels, files, volume) else { return }\n_ = Unmanaged.passRetained(other)\n', False),
    ('another name kept after the guard', GUARD + '_ = Unmanaged.passRetained(viewer)\nopened.setPostprocessed(true)\n', False),
    ('a guard-bound viewer kept only in a comment', GUARD + '// _ = Unmanaged.passRetained(opened)\nopened.setPostprocessed(true)\n', False),
    ('a guard-bound viewer kept after an early return',
     GUARD + 'guard opened.window != nil else { return }\n_ = Unmanaged.passRetained(opened)\n', False),
    ('a guard-bound viewer kept in one branch only',
     GUARD + 'if shown {\n    _ = Unmanaged.passRetained(opened)\n}\n', False),
    ('a guard-bound viewer kept after it was used',
     GUARD + 'opened.setPostprocessed(true)\n_ = Unmanaged.passRetained(opened)\n', False),
    ('a guard that can fail after the viewer opened',
     'guard let made = viewer.newWindow(pixels, files, volume), let window = made.window else { return }\n'
     '_ = Unmanaged.passRetained(made)\n', False),
    ('a guard-bound viewer kept only inside the else block',
     'guard let made = viewer.newWindow(pixels, files, volume) else {\n    _ = Unmanaged.passRetained(made)\n    return\n}\n'
     'made.setPostprocessed(true)\n', False),
]

failures = []
for what, snippet, kept in controls:
    found, unkept = scan(snippet.splitlines())
    if found != [1]:
        failures.append(f'the scan of {what} found the calls of lines {found}, not of line 1')
    elif kept and unkept:
        failures.append(f'the scan refuses {what}')
    elif not kept and not unkept:
        failures.append(f'the scan accepts {what}')

calls = 0
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    found, unkept = scan(path.read_text().splitlines())
    calls += len(found)
    for number in unkept:
        failures.append(f'{path.relative_to(root)}:{number}: the viewer from newWindow is not kept')

if calls == 0:
    failures.append('no Swift call of newWindow found: the check no longer looks at anything')
for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'ok ({calls} calls, {len(controls)} controls)')
