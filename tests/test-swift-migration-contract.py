#!/usr/bin/env python3
"""A class migrated to Swift keeps what plugins compiled against (#708).

tests/fixtures/swift-api-contract.json records the public Objective-C selectors
that plugins compiled against. Each interface is checked against the built
application:

- the Swift source names the class with @objc(Name) and makes it public;
- the kept header <Horos/Name.h> imports Horos-Swift.h, and only forward
  declares the class under the bridging header;
- every class and instance selector and property of the former header is in
  the generated interface of the class, as a class or instance member again;
- the executable exports _OBJC_CLASS_$_Name, which plugins link;
- Horos.framework publishes Name.h and Horos-Swift.h. An entry with
  "published": false is a class whose header was never in the SDK (the
  preference panes, #711): only Horos-Swift.h is required.

An entry with "block" is a block of methods of a class that stays Objective-C,
moved to a Swift extension (#831): each of its "selectors" is declared by the
Swift file and by the generated interface, and no longer defined by the former
implementation; the header is the compatibility header of the block (it
imports Horos-Swift.h, or declares the block's selectors in a category outside
the bridging header, #834); and
every member of the class's former interface is still declared, by the class,
one of its categories in the SDK or the generated interface.

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
registry = json.loads((root / 'tests/fixtures/swift-api-contract.json').read_text())
swift_header = generated.read_text(errors='replace')
exported = subprocess.run(['nm', '-gU', str(app / 'Contents/MacOS/Horos')], capture_output=True, text=True).stdout


def members(declarations):
    """{('+'|'-', selector)} of an Objective-C interface body."""
    found = set()
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', declarations, flags=re.S)
    # A deprecated property (storedMountedVolume of DicomImage, #721) ends with
    # __deprecated in the former header and SWIFT_DEPRECATED in the generated
    # one; its name is the word before that. NS_SWIFT_NONISOLATED (#1004) marks
    # a member that other threads call; the selector is the same.
    text = re.sub(r'\s+(?:__deprecated|SWIFT_DEPRECATED(?:_MSG\([^)]*\))?|NS_SWIFT_NONISOLATED)\s*;', ';', text)
    for kind, signature in re.findall(r'^\s*([-+])\s*\([^;{]*?\)\s*([^;{]+)', text, re.M):
        # Without the parameter types, a part is `label:name`, and the label
        # may be empty (`-loadSeries:::keyImagesOnly:`, #831).
        while re.search(r'\([^()]*\)', signature):
            signature = re.sub(r'\([^()]*\)', ' ', signature)
        parts = re.findall(r'(\w*)\s*:\s*\w+', signature)
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


def class_interface(text, name):
    """The class's own `@interface Name : Super` (or `Name: Super`) block."""
    found = re.search(r'@interface\s+' + re.escape(name) + r'\s*:', text)
    return interface(text, name, found.group(0)) if found else None


def category_members(text, base, category):
    """Members of every `@interface Base (Category)` block of a header; a
    category of None is any category."""
    name = r'\w*' if category is None else re.escape(category)
    pattern = r'@interface\s+' + re.escape(base) + r'\s*(?:<[^>]*>)?\s*\(\s*' + name + r'\s*\)(.*?)\n@end'
    return set().union(*[members(block) for block in re.findall(pattern, text, re.S)] or [set()])


# Foundation classes Swift imports under another name.
SWIFT_NAMES = {'NSThread': 'Thread', 'NSFileManager': 'FileManager', 'NSNotificationCenter': 'NotificationCenter',
               'NSHost': 'Host', 'NSXMLNode': 'XMLNode', 'NSBundle': 'Bundle', 'NSProcessInfo': 'ProcessInfo'}


def without_fallback(header):
    """The header minus the declarations kept for targets without Swift: the
    `#else` after `#elif __has_include("Horos-Swift.h")`. Those restate the
    former interface and would otherwise count as members the Swift keeps."""
    return re.sub(r'(#elif\s+__has_include\("Horos-Swift\.h"\).*?)#else.*?#endif', r'\1#endif', header, flags=re.S)


def defined_selectors(implementation):
    """{('+'|'-', selector)} of the method definitions of an Objective-C source."""
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', implementation, flags=re.S)
    return members('\n'.join(line.split('{')[0] + ';' for line in text.split('\n') if re.match(r'^[-+]\s*\(', line)))


def swift_declares(swift, kind, selector):
    """The Swift source names the selector with @objc(…), or declares the
    @objc property whose getter or setter it is."""
    if f'@objc({selector})' in swift:
        return True
    name = selector[3].lower() + selector[4:-1] if selector.startswith('set') and selector.endswith(':') else selector
    return ':' not in name and re.search(r'@objc\b[^\n]*\n?[^\n]*\bvar\s+' + re.escape(name) + r'\b', swift) is not None


failures = []
checked_bases = set()
for entry in registry['classes']:
    name = entry['name']
    swift = (root / entry['swift']).read_text()
    header = without_fallback((root / entry['header']).read_text(errors='replace'))
    former_members = {(value[0], value[1:]) for value in registry['interfaces'][entry['former']['interface']]}
    if 'block' in entry:
        # A block of methods of a class that stays Objective-C (#831): its
        # selectors, defined in the class's .m before, are now a Swift extension.
        base = entry['base']
        if not re.search(r'extension\s+' + re.escape(base) + r'\b', swift):
            failures.append(f'{name}: {entry["swift"]} does not extend {base}')
        # The header either imports the generated interface or, outside the
        # bridging header, declares in a category every selector of the block
        # that the former header declared:
        # DCMView.h, which imports the DCMView blocks' headers, is itself
        # imported before other classes' interfaces, which the generated
        # interface needs complete (#834).
        declared_in_header = category_members(header, base, None)
        if 'HOROS_BRIDGING_HEADER' not in header or ('#import "Horos-Swift.h"' not in header and not all(
                (member[0], member[1:]) in declared_in_header for member in entry['selectors']
                if (member[0], member[1:]) in former_members)):
            failures.append(f'{name}: {entry["header"]} is not the compatibility header of the contract')
        generated_members = category_members(swift_header, base, 'SWIFT_EXTENSION(Horos)')
        implementation = (root / entry['former']['implementation']).read_bytes().decode('latin1')
        still_defined = defined_selectors(implementation)
        for member in entry['selectors']:
            kind, selector = member[0], member[1:]
            if (kind, selector) not in generated_members:
                failures.append(f'{name}: {member} of the "{entry["block"]}" block is not in a Swift extension of {base}')
            if not swift_declares(swift, kind, selector):
                failures.append(f'{name}: {entry["swift"]} does not declare {member}')
            if (kind, selector) in still_defined:
                failures.append(f'{name}: {entry["former"]["implementation"]} still defines {member}')
        if entry.get('published', True) and not (published / Path(entry['header']).name).is_file():
            failures.append(f'{name}: Horos.framework does not publish {Path(entry["header"]).name}')
        if base not in checked_bases:
            # Whatever the former header of the class declared is still declared
            # for plugins: by the class's interface, by one of its Objective-C
            # categories in the SDK, or by the generated interface.
            checked_bases.add(base)
            own_header = without_fallback((root / entry['former']['header']).read_text(errors='replace'))
            kept = members(class_interface(own_header, base) or '')
            # Compatibility actions may move into a category in the same header;
            # selectors there remain part of the public Objective-C contract.
            kept |= category_members(own_header, base, None)
            for path in sorted((root / Path(entry['former']['header']).parent).glob(base + '+*.h')):
                if not path.name.endswith('+SwiftIvars.h'):
                    kept |= category_members(without_fallback(path.read_text(errors='replace')), base, None)
            old = former_members
            for kind, selector in sorted(old - kept - generated_members):
                failures.append(f'{base}: {kind}{selector} of the former header is declared nowhere')
        print(f'{name}: {len(entry["selectors"])} selectors of "{entry["block"]}" in Swift')
        continue
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
        old = former_members
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
    old = former_members
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
