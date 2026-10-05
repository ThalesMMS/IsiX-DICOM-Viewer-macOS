#!/usr/bin/env python3
"""The Decompress helper asks for character sets only where they are answered.

`NSString (DICOMToNSString)` is implemented in Swift, in the application
(#716). The Decompress helper has no Swift, yet it compiles DicomFile.mm and
DicomFileDCMTKCategory.mm, which asked `+[NSString encodingForDICOMCharacterSet:]`;
the header declared the selectors for the helper without an implementation, so
reaching those lines there ended in an unrecognized selector exception (#767).
Those sources now ask `DCMCharacterSet`, from DCM.framework, which the helper
links and which is the table the Swift category forwards to.

Checked:

1. the sources the Decompress target compiles, read from its Sources phase in
   Horos.xcodeproj, send none of the category's selectors to NSString unless
   the target compiles an implementation, and DICOMToNSString.h no longer
   declares the category for a target without Swift;
2. in each built helper, every `encodingForDICOMCharacterSet:` (and
   `...DICOMEncoding:`) call site, traced back from the disassembly to the
   class loaded as its receiver, goes to a class that implements it in the
   helper or in the DCM.framework next to it. Skipped (exit 2) when no helper
   is built; `--helper PATH` checks another one.

`<git revision>` as an optional argument reads the sources from that revision;
the helper check always reads the built products.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
args = sys.argv[1:]
helpers = []
while '--helper' in args:
    at = args.index('--helper')
    helpers.append(Path(args[at + 1]))
    del args[at:at + 2]
revision = args[0] if args else None
failures = []


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', '%s:%s' % (revision, path)])
    else:
        data = (root / path).read_bytes()
    return data.decode('latin1')


def tracked():
    command = ['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision] if revision else \
        ['git', '-C', str(root), 'ls-files']
    return subprocess.check_output(command, text=True).splitlines()


def uncommented(text):
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n') or ' ', text, flags=re.S)
    return re.sub(r'(?m)(^|[^:"])//.*$', r'\1', text)


SELECTORS = ('encodingForDICOMCharacterSet:', 'stringWithUTF8String:DICOMEncoding:',
             'initWithCString:DICOMEncoding:')
SENDS = {
    'encodingForDICOMCharacterSet:': re.compile(r'\[\s*NSString\s+encodingForDICOMCharacterSet\s*:'),
    'stringWithUTF8String:DICOMEncoding:': re.compile(r'\[\s*NSString\s+stringWithUTF8String\s*:[^\];]*\bDICOMEncoding\s*:'),
    'initWithCString:DICOMEncoding:': re.compile(r'\binitWithCString\s*:[^\];]*\bDICOMEncoding\s*:'),
}

# ------------------------------------------------- 1. what the target compiles
project = read('Horos.xcodeproj/project.pbxproj')
target = re.search(r'\t\t[0-9A-F]{24} /\* Decompress \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};',
                   project, re.S)
if not target:
    print('FAIL: Horos.xcodeproj has no Decompress target; this test is stale')
    sys.exit(1)
sources = []
for phase in re.findall(r'([0-9A-F]{24})', re.search(r'buildPhases = \((.*?)\);', target.group(1), re.S).group(1)):
    block = re.search(r'\t\t' + phase + r' /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S)
    if block:
        sources += re.findall(r'/\* (.+?) in Sources \*/', block.group(1))
if 'Decompress.mm' not in sources or 'DicomFileDCMTKCategory.mm' not in sources:
    failures.append('the Decompress Sources phase was not read: %s' % sources)

vendored = ('DCMTK/', 'ITK/', 'VTK/', 'Binaries/', 'OpenJPEG/', 'build/')
by_name = {}
for path in tracked():
    if not path.startswith(vendored):
        by_name.setdefault(Path(path).name, []).append(path)

implemented = set()
if 'DICOMToNSString.swift' in sources:
    implemented.update(SELECTORS)
sends = []
for name in sources:
    if Path(name).suffix not in ('.m', '.mm', '.c', '.cpp'):
        continue
    paths = by_name.get(name, [])
    if not paths:
        failures.append('%s, compiled by Decompress, is not in the repository' % name)
    for path in paths:
        text = uncommented(read(path))
        for block in re.findall(r'@implementation\s+NSString\s*\(.*?@end', text, re.S):
            implemented.update(s for s in SELECTORS
                               if re.search(r'^[+-]\s*\([^)]*\)\s*' + s.split(':')[0] + r'\s*:', block, re.M))
        for selector, pattern in SENDS.items():
            for match in pattern.finditer(text):
                sends.append((path, text.count('\n', 0, match.start()) + 1, selector))

missing = [s for s in sends if s[2] not in implemented]
for path, line, selector in missing:
    failures.append('%s:%d sends %s to NSString, which Decompress does not implement' % (path, line, selector))
print('Decompress compiles %d sources; %d send the category to NSString, %d without an implementation'
      % (len(sources), len(sends), len(missing)))

header = uncommented(read('Horos/Sources/DICOMToNSString.h'))
fallback = header.split('#elif __has_include("Horos-Swift.h")', 1)[-1].split('#else', 1)
if len(fallback) < 2:
    failures.append('DICOMToNSString.h has no branch for a target without Swift; this test is stale')
elif '@interface' in fallback[1].split('#endif', 1)[0]:
    failures.append('DICOMToNSString.h declares the category for a target without Swift, '
                    'which has no implementation of it')
else:
    print('DICOMToNSString.h declares nothing for a target without Swift')

# ----------------------------------------------------- 2. the built helpers
if not helpers:
    helpers = [p for p in (root / 'build/Build/Products/Debug/IsiX DICOM Viewer.app/Contents/Resources/Decompress',
                           root / 'build/Development/HorosDevelopment.app/Contents/Resources/Decompress')
               if p.is_file()]
    if not helpers:
        for failure in failures:
            print('FAIL: %s' % failure)
        if failures:
            sys.exit(1)
        print('skip: no Decompress helper is built (build/Build/Products/Debug, build/Development); '
              'pass --helper PATH')
        sys.exit(2)

INSTRUCTION = re.compile(r'^([0-9a-f]{8,16})\t(\S+)\t?([^;]*?)\s*(?:;\s*(.*))?$')
POOL = re.compile(r'literal pool symbol address: (\S+)|Objc class ref: (\S+)')


def implementations(binary):
    """Class -> selectors from the method symbols of a binary."""
    found = {}
    listed = subprocess.run(['nm', '-m', str(binary)], capture_output=True, text=True).stdout
    for cls, selector in re.findall(r'[+-]\[(\w+)(?:\([^)]*\))? ([^\]]+)\]', listed):
        found.setdefault(cls, set()).add(selector)
    return found


def functions(binary):
    """(name, [(address, mnemonic, operands, comment)]) per function in the disassembly."""
    listing = subprocess.run(['otool', '-tV', str(binary)], capture_output=True, text=True).stdout
    current, body = None, []
    for line in listing.splitlines():
        match = INSTRUCTION.match(line)
        if match:
            body.append((int(match.group(1), 16), match.group(2), match.group(3).strip(), match.group(4) or ''))
        elif line.endswith(':') and not line.startswith(('(', '/')):
            if current is not None:
                yield current, body
            current, body = line[:-1], []
    if current is not None:
        yield current, body


def operands(text):
    return [part.strip() for part in re.split(r',(?![^\[]*\])', text)]


def memory(operand):
    """[base, #offset] -> (base, offset)."""
    match = re.match(r'\[(\w+)(?:,\s*#(-?0x[0-9a-f]+|-?\d+))?\]!?$', operand)
    return (match.group(1), int(match.group(2) or '0', 0)) if match else None


CALL_CLOBBERED = {'x%d' % n for n in range(19)} | {'w%d' % n for n in range(19)}
NO_DESTINATION = ('st', 'cb', 'tb', 'b.', 'cmp', 'cmn', 'tst', 'ccmp', 'fcmp')


def receiver(body, index, register, pool, depth=0):
    """The symbol loaded into `register` before instruction `index`, or None."""
    if depth > 12:
        return None
    for at in range(index - 1, -1, -1):
        _, mnemonic, text, comment = body[at]
        parts = operands(text)
        if mnemonic in ('bl', 'blr'):
            if register in CALL_CLOBBERED:
                return None
            continue
        if not parts or mnemonic.startswith(NO_DESTINATION) or mnemonic in ('b', 'br', 'ret', 'nop'):
            continue
        written = [parts[0]] + ([parts[1]] if mnemonic == 'ldp' else [])
        if register not in written:
            continue
        if mnemonic in ('ldr', 'ldur'):
            symbol = POOL.search(comment)
            if symbol:
                return symbol.group(1) or symbol.group(2)
            slot = memory(parts[1])
            if not slot:
                return None
            base, offset = slot
            if base in ('sp', 'x29'):
                return stored(body, at, base, offset, pool, depth)
            page = adrp(body, at, base)
            return pool.get(page + offset) if page is not None else None
        if mnemonic == 'ldp':
            slot = memory(parts[2])
            if not slot or slot[0] not in ('sp', 'x29'):
                return None
            return stored(body, at, slot[0], slot[1] + (8 if register == parts[1] else 0), pool, depth)
        if mnemonic == 'mov' and re.match(r'[xw]\d+$', parts[1]):
            return receiver(body, at, parts[1], pool, depth + 1)
        return None
    return None


def stored(body, index, base, offset, pool, depth):
    for at in range(index - 1, -1, -1):
        _, mnemonic, text, _ = body[at]
        parts = operands(text)
        if mnemonic in ('str', 'stur') and memory(parts[1]) == (base, offset):
            return receiver(body, at, parts[0], pool, depth + 1)
        if mnemonic == 'stp':
            slot = memory(parts[2])
            if slot and slot[0] == base and offset in (slot[1], slot[1] + 8):
                return receiver(body, at, parts[0] if offset == slot[1] else parts[1], pool, depth + 1)
    return None


def adrp(body, index, register):
    for at in range(index - 1, -1, -1):
        _, mnemonic, text, comment = body[at]
        parts = operands(text)
        if parts and parts[0] == register and not mnemonic.startswith(NO_DESTINATION):
            if mnemonic == 'adrp' and comment.startswith('0x'):
                return int(comment.split()[0], 16)
            return None
    return None


for helper in helpers:
    if not helper.is_file():
        failures.append('%s is not built' % helper)
        continue
    label = helper.parents[3].name if len(helper.parents) > 3 else str(helper)   # Debug, Development...
    framework = helper.parent.parent / 'Frameworks/DCM.framework/Versions/A/DCM'
    known = implementations(helper)
    if framework.is_file():
        for cls, selectors in implementations(framework).items():
            known.setdefault(cls, set()).update(selectors)
    else:
        failures.append('%s: no DCM.framework next to it' % helper)
    listing = list(functions(helper))
    pool = {}
    for _, body in listing:
        for at, (_, mnemonic, text, comment) in enumerate(body):
            symbol = POOL.search(comment)
            slot = memory(operands(text)[1]) if mnemonic in ('ldr', 'ldur') and symbol and ',' in text else None
            if slot:
                page = adrp(body, at, slot[0])
                if page is not None:
                    pool[page + slot[1]] = symbol.group(1) or symbol.group(2)
    checked, unresolved = [], []
    for name, body in listing:
        for at, (address, mnemonic, text, _) in enumerate(body):
            called = re.match(r'"?_objc_msgSend\$([^"]+)"?$', text) if mnemonic == 'bl' else None
            if not called or called.group(1) not in SELECTORS:
                continue
            selector = called.group(1)
            symbol = receiver(body, at, 'x0', pool)
            if symbol is None:
                unresolved.append('%s at 0x%x' % (name, address))
                continue
            cls = symbol.replace('_OBJC_CLASS_$_', '').replace('_OBJC_METACLASS_$_', '')
            checked.append((name, cls, selector))
            if selector not in known.get(cls, set()):
                failures.append('%s helper: %s sends %s to %s, which implements no such method there'
                                % (label, name, selector, cls))
    if not checked and not unresolved:
        print('%s: sends none of the category\'s selectors' % helper)
    elif not checked:
        failures.append('%s: no receiver of the %d calls could be traced; this test is stale'
                        % (helper, len(unresolved)))
    print('%s: %d calls traced to %s; %d not traced%s' % (
        helper, len(checked), ', '.join(sorted({c for _, c, _ in checked})) or 'nothing', len(unresolved),
        (' (%s)' % ', '.join(unresolved)) if unresolved else ''))

for failure in failures:
    print('FAIL: %s' % failure)
if not failures:
    print('PASS: Decompress sends the character-set selectors only to classes it links')
sys.exit(1 if failures else 0)
