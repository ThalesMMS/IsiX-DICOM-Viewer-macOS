#!/usr/bin/env python3
"""A class migrated to Swift keeps what plugins compiled against (#708).

docs/swift-migrated-classes.json lists every class the Swift track moved, with
the commit that still had its Objective-C header. For each, against the built
application, the contract of docs/swift-migration-contract.md is checked:

- the Swift source names the class with @objc(Name) and makes it public;
- the kept header <Horos/Name.h> imports Horos-Swift.h, and only forward
  declares the class under the bridging header;
- every class and instance selector and property of the former header is in
  the generated interface of the class, as a class or instance member again;
- the executable exports _OBJC_CLASS_$_Name, which plugins link;
- Horos.framework publishes Name.h and Horos-Swift.h. An entry with
  "published": false is a class whose header was never in the SDK (the
  preference panes, #711): only Horos-Swift.h is required.

--generated FILE checks against another generated header, which is how a
removed selector is shown to fail.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=root / 'build/Build/Products/Debug')
parser.add_argument('--generated', type=Path)
args = parser.parse_args()

app = args.products / 'Horos.app'
published = app / 'Contents/Frameworks/Horos.framework/Headers'
generated = args.generated or published / 'Horos-Swift.h'
if not generated.is_file():
    print('skipped: needs a built Horos.app (script/build_and_run.sh): --products DIR', file=sys.stderr)
    raise SystemExit(2)
registry = json.loads((root / 'docs/swift-migrated-classes.json').read_text())
swift_header = generated.read_text(errors='replace')
exported = subprocess.run(['nm', '-gU', str(app / 'Contents/MacOS/Horos')], capture_output=True, text=True).stdout


def members(declarations):
    """{('+'|'-', selector)} of an Objective-C interface body."""
    found = set()
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', declarations, flags=re.S)
    # A deprecated property (storedMountedVolume of DicomImage, #721) ends with
    # __deprecated in the former header and SWIFT_DEPRECATED in the generated
    # one; its name is the word before that.
    text = re.sub(r'\s+(?:__deprecated|SWIFT_DEPRECATED(?:_MSG\([^)]*\))?)\s*;', ';', text)
    for kind, signature in re.findall(r'^\s*([-+])\s*\([^;{]*?\)\s*([^;{]+)', text, re.M):
        parts = re.findall(r'(\w+)\s*:', signature)
        found.add((kind, ''.join(p + ':' for p in parts) if parts else signature.split()[0]))
    for attributes, name in re.findall(r'@property\s*(\([^)]*\))?[^;]*?\b(\w+)\s*;', text):
        getter = re.search(r'getter\s*=\s*(\w+)', attributes or '')
        # Swift renames a property whose name is a C++ keyword (`operator` of
        # O2DicomPredicateEditorView, #713) and keeps the selectors in getter=
        # and setter=.
        setter = re.search(r'setter\s*=\s*(\w+:)', attributes or '')
        kind = '+' if 'class' in (attributes or '') else '-'
        found.add((kind, getter.group(1) if getter else name))
        if 'readonly' not in (attributes or ''):
            found.add((kind, setter.group(1) if setter else 'set' + name[0].upper() + name[1:] + ':'))
    return found


def interface(text, name, marker):
    start = text.find(marker)
    if start < 0:
        return None
    start = text.index('@interface ' + name, start)
    return text[start:text.index('\n@end', start)]


def category_members(text, base, category):
    """Members of every `@interface Base (Category)` block of a header."""
    pattern = r'@interface\s+' + re.escape(base) + r'\s*(?:<[^>]*>)?\s*\(\s*' + re.escape(category) + r'\s*\)(.*?)\n@end'
    return set().union(*[members(block) for block in re.findall(pattern, text, re.S)] or [set()])


# Foundation classes Swift imports under another name.
SWIFT_NAMES = {'NSThread': 'Thread', 'NSFileManager': 'FileManager', 'NSNotificationCenter': 'NotificationCenter',
               'NSHost': 'Host', 'NSXMLNode': 'XMLNode', 'NSBundle': 'Bundle', 'NSProcessInfo': 'ProcessInfo'}


def without_fallback(header):
    """The header minus the declarations kept for targets without Swift: the
    `#else` after `#elif __has_include("Horos-Swift.h")`. Those restate the
    former interface and would otherwise count as members the Swift keeps."""
    return re.sub(r'(#elif\s+__has_include\("Horos-Swift\.h"\).*?)#else.*?#endif', r'\1#endif', header, flags=re.S)


failures = []
for entry in registry['classes']:
    name = entry['name']
    swift = (root / entry['swift']).read_text()
    header = without_fallback((root / entry['header']).read_text(errors='replace'))
    former = subprocess.run(['git', '-C', str(root), 'show', f'{entry["former"]["commit"]}:{entry["former"]["header"]}'],
                            capture_output=True, text=True, errors='replace')
    if former.returncode:
        print(f'skipped: the former header of {name} is not in this clone\'s history', file=sys.stderr)
        raise SystemExit(2)
    if 'category' in entry:
        # A category on an AppKit class: its members, now in a Swift extension.
        base, category = entry['base'], entry['category']
        # An informal protocol or a category kept in Objective-C stays declared
        # in the compatibility header; what it declares is kept there.
        kept_in_header = category_members(header, base, category)
        swift_base = r'(?:%s|%s)' % (re.escape(base), re.escape(SWIFT_NAMES.get(base, base)))
        if not kept_in_header and not re.search(r'extension\s+' + swift_base + r'\b', swift):
            failures.append(f'{name}: {entry["swift"]} does not extend {base}')
        if '#import "Horos-Swift.h"' not in header or 'HOROS_BRIDGING_HEADER' not in header:
            failures.append(f'{name}: {entry["header"]} is not the compatibility header of the contract')
        old = category_members(former.stdout, base, category)
        new = category_members(swift_header, base, 'SWIFT_EXTENSION(Horos)') | kept_in_header
        for kind, selector in sorted(old - new):
            failures.append(f'{name}: {kind}{selector} of the former category is not in a Swift extension of {base}')
        if entry.get('published', True) and not (published / Path(entry['header']).name).is_file():
            failures.append(f'{name}: Horos.framework does not publish {Path(entry["header"]).name}')
        print(f'{name}: {len(old)} former members kept')
        continue
    if f'@objc({name})' not in swift or not re.search(r'(public|open) (final )?class ' + name + r'\b', swift):
        failures.append(f'{name}: {entry["swift"]} does not declare a public @objc({name}) class')
    if '#import "Horos-Swift.h"' not in header or not re.search(r'@class [^;]*\b' + name + r'\b', header) or 'HOROS_BRIDGING_HEADER' not in header:
        failures.append(f'{name}: {entry["header"]} is not the compatibility header of the contract')
    old = members(interface(former.stdout, name, '@interface ' + name) or '')
    new_interface = interface(swift_header, name, f'SWIFT_CLASS_NAMED("{name}")')
    if new_interface is None:
        failures.append(f'{name}: not in the generated interface {generated.name}')
        continue
    # Members an Objective-C category of the class keeps, declared in the
    # compatibility header (N2View's -layout, which Swift cannot declare).
    new = members(new_interface) | set().union(*[members(block) for block in re.findall(
        r'@interface\s+' + name + r'\s*\(\s*\w*\s*\)(.*?)\n@end', header, re.S)] or [set()])
    for kind, selector in sorted(old - new):
        failures.append(f'{name}: {kind}{selector} of the former header is not in the Swift class')
    if f'_OBJC_CLASS_$_{name}\n' not in exported + '\n':
        failures.append(f'{name}: the executable does not export _OBJC_CLASS_$_{name}')
    for file in ((Path(entry['header']).name,) if entry.get('published', True) else ()) + ('Horos-Swift.h',):
        if not (published / file).is_file():
            failures.append(f'{name}: Horos.framework does not publish {file}')
    print(f'{name}: {len(old)} former members kept')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
