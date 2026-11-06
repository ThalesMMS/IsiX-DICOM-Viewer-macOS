#!/usr/bin/env python3
"""A Swift format call gives %s only a C string, never a Swift String.

NSLog, String(format:) and the other Foundation format calls read a %s argument
as a pointer to NUL-terminated bytes. A Swift String passed there arrives as
the object it bridges to, and the formatter walks that object's memory looking
for a NUL: the line comes out as garbage or the process stops in strlen. The
calls that did it sat on exception paths, so the report of one failure brought
the application down.

Every tracked Swift file is read, comments left out. For each NSLog,
String(format:), NSString(format:), appendFormat, appendingFormat and
localizedStringWithFormat call whose format is a literal, every %s (and %S)
is matched to its argument, counting the arguments that %*d widths and
positional %n$ specifiers take. The argument must be one of the C pointers in
C_POINTERS (utf8Start, utf8String, fileSystemRepresentation, objCType,
strerror(...), the process folder); a string literal is refused, and so is
anything the list does not name, which is to be given as %@ or added to the
list with a reason.

The checker first proves itself on a few lines written here. `<git revision>`
as an optional argument checks that revision instead, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

CALL = re.compile(r'(?<![\w.])(?:NSLog\s*\(|(?:NS)?String\s*\(\s*format\s*:|(?:NS)?String\.localizedStringWithFormat\s*\()'
                  r'|\.append(?:ing)?Format\s*\(')
# Expressions that are a pointer to C bytes, which is what %s reads.
C_POINTERS = [
    r'\.utf8Start',                  # StaticString
    r'\.utf8String!?',               # NSString
    r'\.fileSystemRepresentation',   # NSString / FileManager
    r'\.objCType',                   # NSValue / NSNumber
    r'strerror\(.*\)',               # libc
    r'HorosDICOMProcessFolder\(\)',  # UnsafePointer<CChar>
    r'\$0',                          # withCString / withMemoryRebound closures over CChar
]
C_POINTER = re.compile(r'^(?:[\w.()!?\[\]\s]*?(?:' + '|'.join(C_POINTERS[:4]) + r')|' + '|'.join(C_POINTERS[4:]) + r')$', re.S)
SPECIFIER = re.compile(r"%(?:(\d+)\$)?([-+ #0']*)(\*|\d+)?(?:\.(\*|\d+))?(hh|h|ll|l|q|L|z|t|j)?([a-zA-Z@%])")


def without_comments(text):
    """The text with comments blanked, strings kept, and every offset unchanged."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(text[i:j])
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == '\\' else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def arguments(text, start):
    """The top-level arguments of the call whose '(' is at start, or None."""
    depth, i, n = 0, start, len(text)
    current, items = [], []
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\' and text.startswith('\\(', j):
                    k, level = j + 2, 1
                    while k < n and level:
                        level += {'(': 1, ')': -1}.get(text[k], 0)
                        k += 1
                    j = k
                else:
                    j += 2 if text[j] == '\\' else 1
            current.append(text[i:j + 1])
            i = j + 1
            continue
        if c in '([{':
            depth += 1
            if depth == 1:
                i += 1
                continue
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                items.append(''.join(current).strip())
                return [item for item in items if item]
        elif c == ',' and depth == 1:
            items.append(''.join(current).strip())
            current = []
            i += 1
            continue
        current.append(c)
        i += 1
    return None


def literal(argument):
    match = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', argument, re.S)
    return match.group(1) if match and '\\(' not in argument else None


checked = []


def findings(path, text):
    clean = without_comments(text)
    found = []
    for match in CALL.finditer(clean):
        inside = clean.find('(', match.start(), match.end())
        open_paren = inside if inside >= 0 else match.end() - 1
        if clean[open_paren] != '(':
            continue
        items = arguments(clean, open_paren)
        if not items:
            continue
        items = [re.sub(r'^(?:format|_ format)\s*:\s*', '', items[0])] + items[1:]
        if any(re.match(r'arguments\s*:', item) for item in items):
            continue  # a va_list or an array, not a variadic list to match
        items = [item for item in items if not re.match(r'locale\s*:', item)]
        fmt = literal(items[0])
        if fmt is None:
            continue
        args, index = items[1:], 0
        line = clean.count('\n', 0, match.start()) + 1
        for spec in SPECIFIER.finditer(fmt.replace('%%', '')):
            position, _, width, precision, _, conversion = spec.groups()
            if not position:
                index += (width == '*') + (precision == '*')
            target = int(position) - 1 if position else index
            if not position:
                index += 1
            if conversion not in 'sS':
                continue
            checked.append(path)
            argument = args[target] if target < len(args) else None
            if argument is None:
                found.append(f'{path}:{line}: %{conversion} with no argument')
            elif argument.startswith(('"', '#"')):
                found.append(f'{path}:{line}: %{conversion} given the Swift String {argument[:60]}; use %@')
            elif not C_POINTER.match(argument):
                found.append(f'{path}:{line}: %{conversion} given {argument[:60]!r}, not a known C string; '
                             'use %@ for a String, or add the C pointer to C_POINTERS')
    return found


def self_check():
    cases = {
        'NSLog("in %s: %@", "-[A b]", e)': 1,
        'NSLog("in %@: %@", "-[A b]", e)': 0,
        'NSLog("Mode: %s not started", service.utf8Start)': 0,
        'String(format: "%-8d %-20s %@", n, (owner as NSString).utf8String!, name)': 0,
        'String(format: "%s/state-%d", HorosDICOMProcessFolder(), pid)': 0,
        'NSLog("---- %@ failed: %s",\n      name, strerror(errno))': 0,
        'NSLog("%d%% %*d %s", a, w, b, name)': 1,
        'NSLog("%2$s %1$@", a, "b")': 1,
        'let s = String(format: "%s", path)': 1,
        'text.appendFormat("%s", "\\(x)")': 1,
        'NSString(format: "%s", $0)': 0,
        '// NSLog("%s", "commented out")': 0,
        'NSLog("%@ %s", "a")': 1,
    }
    wrong = []
    for code, expected in cases.items():
        got = len(findings('self-check', code))
        if got != expected:
            wrong.append(f'self-check: {code!r} gave {got} finding(s), expected {expected}')
    return wrong


def swift_files():
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision]).decode()
    else:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-files']).decode()
    for name in sorted(names.splitlines()):
        if not name.endswith('.swift'):
            continue
        if revision:
            data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{name}'])
        else:
            data = (root / name).read_bytes()
        yield name, data.decode('utf-8', 'replace')


failures = self_check()
checked.clear()
count = 0
for name, text in swift_files():
    count += 1
    failures += findings(name, text)

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print(f'PASS: {len(checked)} %s argument(s) in {count} Swift files are C strings, none a Swift String')
