#!/usr/bin/env python3
"""Every Swift creator of a window controller that releases itself keeps it.

Many window controllers let themselves go when their window closes: their
-windowWillClose: autoreleases them (`Unmanaged.passUnretained(self)
.autorelease()`), the design of the former manual reference counting, in which
the code that made the controller left it the +1 of its alloc. Under ARC the
creator has to hand that +1 back with Unmanaged.passRetained; one that does not
loses the controller as soon as its own reference goes, while the window stays
on screen (the database window's Meta-Data showed an empty window that way),
and closing it then releases a controller that is already gone.

The scan finds those controllers, every class whose -windowWillClose:
autoreleases self, and every Swift call of their initializers in
Horos/Sources. A creation is kept when the call is the argument of
Unmanaged.passRetained, or when the name it is bound to (let, var, if let,
guard let) is handed to Unmanaged.passRetained, or to a function of the
sources that hands its parameter to Unmanaged.passRetained, before the scope
that made it ends. The snippets below hold the scan to that. `<git revision>`
as an optional argument reads the sources of that revision, the negative
control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
SOURCES = 'Horos/Sources'
SELF_RELEASE = 'Unmanaged.passUnretained(self).autorelease()'
# A type of the file's top level: the one a -windowWillClose: belongs to.
type_declaration = re.compile(r'^(?:@[\w.]+(?:\([^)]*\))?[ \t]+)*(?:(?:public|open|internal|final|private|fileprivate|nonisolated)[ \t]+)*'
                              r'(?:class|extension)[ \t]+(?!func\b|var\b|let\b)(\w+)', re.M)
will_close = re.compile(r'\bfunc\s+windowWillClose\s*\(')
function_declaration = re.compile(r'\bfunc\s+(\w+)\s*(?:<[^>]*>)?\(\s*(\w+)(?:\s+(\w+))?\s*:')
binding = re.compile(r'(?:\b(?:let|var)\s+(\w+)\s*(?::[^=]*)?|^\s*(\w+)\s*)=\s*(?:try[?!]?\s+)?$')


def bare(text):
    """The text without its comments, string literals emptied, line breaks kept."""
    out = []
    position, quoted, block = 0, False, 0
    while position < len(text):
        character = text[position]
        if block:
            if text.startswith('*/', position):
                block -= 1
                position += 2
                continue
            if text.startswith('/*', position):
                block += 1
                position += 2
                continue
            if character == '\n':
                out.append(character)
        elif quoted:
            if character == '\\':
                position += 1
            elif character == '"':
                quoted = False
                out.append(character)
            elif character == '\n':
                out.append(character)
        elif character == '"':
            quoted = True
            out.append(character)
        elif text.startswith('//', position):
            end = text.find('\n', position)
            position = len(text) if end < 0 else end
            continue
        elif text.startswith('/*', position):
            block = 1
            position += 2
            continue
        else:
            out.append(character)
        position += 1
    return ''.join(out)


def closing(text, start):
    """The index after the brace that closes the one at `start`."""
    depth = 0
    for position in range(start, len(text)):
        if text[position] == '{':
            depth += 1
        elif text[position] == '}':
            depth -= 1
            if depth == 0:
                return position + 1
    return len(text)


def rest_of_scope(text, start):
    """The text from `start` to the end of the scope `start` is in."""
    depth = 0
    for position in range(start, len(text)):
        if text[position] == '{':
            depth += 1
        elif text[position] == '}':
            depth -= 1
            if depth < 0:
                return text[start:position]
    return text[start:]


def self_releasing(sources):
    """The classes whose -windowWillClose: autoreleases self."""
    found = set()
    for text in sources.values():
        for declaration in will_close.finditer(text):
            opening = text.find('{', declaration.end())
            if opening < 0 or SELF_RELEASE not in text[opening:closing(text, opening)]:
                continue
            owners = [match.group(1) for match in type_declaration.finditer(text, 0, declaration.start())]
            if owners:
                found.add(owners[-1])
    return found


def keepers(sources):
    """The functions that hand their first parameter to Unmanaged.passRetained."""
    found = set()
    for text in sources.values():
        for declaration in function_declaration.finditer(text):
            parameter = declaration.group(3) or declaration.group(2)
            opening = text.find('{', declaration.end())
            if opening >= 0 and re.search(rf'Unmanaged\.passRetained\(\s*{parameter}\s*\)', text[opening:closing(text, opening)]):
                found.add(declaration.group(1))
    return found


def scan(sources):
    """The self-releasing classes, the creations found, and those not kept."""
    classes = self_releasing(sources)
    helpers = keepers(sources)
    creations, unkept = [], []
    for name, text in sorted(sources.items()):
        for cls in sorted(classes):
            for call in re.finditer(rf'(?<![\w.]){cls}(?:\.init)?\s*\(', text):
                line_start = text.rfind('\n', 0, call.start()) + 1
                line = text[line_start:text.find('\n', call.start())]
                before = text[line_start:call.start()]
                if re.search(r'\b(?:func|class|init|extension)\b', before):
                    continue
                number = text.count('\n', 0, call.start()) + 1
                creations.append((name, number, cls))
                if re.search(rf'Unmanaged\.passRetained\(\s*{cls}(?:\.init)?\s*\(', line):
                    continue
                bound = binding.search(re.sub(r'^\s*(?:if|guard)\s+', '', before))
                kept = False
                if bound:
                    variable = bound.group(1) or bound.group(2)
                    scope = rest_of_scope(text, call.start())
                    handed = [r'Unmanaged\.passRetained'] + [re.escape(helper) for helper in sorted(helpers)]
                    kept = re.search(rf'(?<![\w.])(?:{"|".join(handed)})\(\s*{variable}\s*\)', scope) is not None
                if not kept:
                    unkept.append((name, number, cls))
    return classes, creations, unkept


CONTROLLER = '''\
final class Thing: NSWindowController {
    func windowWillClose(_ notification: Notification) {
        _ = Unmanaged.passUnretained(self).autorelease()
    }
}
final class Kept: NSWindowController {
    func windowWillClose(_ notification: Notification) {}
}
'''
HELPER = '''\
private func handOver(_ controller: AnyObject?) {
    guard let controller else { return }
    _ = Unmanaged.passRetained(controller)
}
'''


def snippet(body):
    return 'func open() {\n' + body + '}\n'


# What the snippet shows, the snippet, and whether its controller is kept.
controls = [
    ('a controller kept in the call that makes it', snippet('    _ = Unmanaged.passRetained(Thing(viewer: self))\n'), True),
    ('a controller kept after it is bound',
     snippet('    let thing = Thing(viewer: self)\n    _ = Unmanaged.passRetained(thing)\n    thing.showWindow(nil)\n'), True),
    ('a controller kept in its if let',
     snippet('    if let thing = Thing(viewer: self) {\n        _ = Unmanaged.passRetained(thing)\n    }\n'), True),
    ('a controller kept after its guard',
     snippet('    guard let thing = Thing(image: image) else { return }\n    _ = Unmanaged.passRetained(thing)\n'), True),
    ('a controller with a type annotation, kept',
     snippet('    let thing: Thing = Thing(viewer: self)\n    _ = Unmanaged.passRetained(thing)\n'), True),
    ('a controller handed to a helper that keeps it', HELPER + snippet('    let made = Thing(viewer: self)\n    handOver(made)\n'), True),
    ('a controller nobody keeps', snippet('    let thing = Thing(image: image)\n    thing?.showWindow(self)\n'), False),
    ('a controller never bound', snippet('    Thing(image: image)?.showWindow(self)\n'), False),
    ('a controller kept only in a comment',
     snippet('    let thing = Thing(viewer: self)\n    // _ = Unmanaged.passRetained(thing)\n'), False),
    ('a controller kept in a block comment',
     snippet('    let thing = Thing(viewer: self)\n    /* _ = Unmanaged.passRetained(thing) */\n'), False),
    ('another name kept', snippet('    let thing = Thing(viewer: self)\n    _ = Unmanaged.passRetained(other)\n'), False),
    ('a controller kept in another function',
     snippet('    let thing = Thing(viewer: self)\n    thing.showWindow(nil)\n') + snippet('    _ = Unmanaged.passRetained(thing)\n'), False),
    ('a controller handed to a function that does not keep it',
     'func show(_ controller: AnyObject?) {\n    _ = controller\n}\n' + snippet('    let made = Thing(viewer: self)\n    show(made)\n'), False),
]

failures = []
for what, code, kept in controls:
    classes, found, unkept = scan({'Controller.swift': bare(CONTROLLER), 'Snippet.swift': bare(code)})
    if classes != {'Thing'}:
        failures.append(f'the scan of {what} takes {sorted(classes)} for the controllers that release themselves')
    elif [(name, cls) for name, _, cls in found] != [('Snippet.swift', 'Thing')]:
        failures.append(f'the scan of {what} found the creations {found}, not one')
    elif kept and unkept:
        failures.append(f'the scan refuses {what}')
    elif not kept and not unkept:
        failures.append(f'the scan accepts {what}')


def sources_of(revision):
    if revision:
        listed = subprocess.run(['git', '-C', str(root), 'ls-tree', '--name-only', f'{revision}:{SOURCES}'],
                                capture_output=True, text=True, check=True).stdout.split()
        return {f'{SOURCES}/{name}': subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{SOURCES}/{name}'],
                                                    capture_output=True, check=True).stdout.decode('utf-8', 'replace')
                for name in listed if name.endswith('.swift')}
    return {str(path.relative_to(root)): path.read_text(encoding='utf-8', errors='replace')
            for path in sorted((root / SOURCES).glob('*.swift'))}


sources = {name: bare(text) for name, text in sources_of(revision).items()}
classes, creations, unkept = scan(sources)
if 'XMLController' not in classes or len(classes) < 10:
    failures.append(f'only {sorted(classes)} found among the controllers that release themselves: this test needs a new look')
if sum(1 for _, _, cls in creations if cls == 'XMLController') < 2:
    failures.append('the two creators of XMLController (the database window and the viewer) are no longer found')
for name, number, cls in unkept:
    failures.append(f'{name}:{number}: the {cls} made here is not kept; it releases itself when its window closes')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'ok ({len(classes)} controllers, {len(creations)} creations, {len(controls)} controls)')
