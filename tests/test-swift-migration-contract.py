#!/usr/bin/env python3
"""A class migrated to Swift keeps its Objective-C contract.

tests/fixtures/swift-api-contract.json records the public Objective-C selectors
that the former headers declared, which the application's Objective-C code,
nibs, bindings and key-value coding reach by name. Each interface is checked
against the built application and its generated Horos-Swift.h:

- the Swift source names the class with @objc(Name) and makes it public;
- the kept header <Horos/Name.h> imports Horos-Swift.h, and only forward
  declares the class under the bridging header; a header that other classes'
  headers read before their own interface ("forwardOnly": DCMView.h) only
  names the class, and an Objective-C category of it ("objectiveC", a
  +CAPI.m) declares what Swift cannot;
- every class and instance selector and property of the former header is in
  the generated interface of the class, as a class or instance member again,
  unless the entry's "removed" records it, with the reason the class gave it
  up (a feature that left the app); such a member must be one the former
  header declared and that the class no longer declares;
- the executable exports _OBJC_CLASS_$_Name.

The former plugin SDK (Horos.framework, which published these headers) is gone
since the plugin API version 1; "published" in an entry is historical.

An entry with "block" is a block of methods of a class that stays Objective-C,
moved to a Swift extension: each of its "selectors" is declared by the
Swift file and by the generated interface, and no longer defined by the former
implementation; the header is the compatibility header of the block (it
imports Horos-Swift.h, or declares the block's selectors in a category outside
the bridging header); and
every member of the class's former interface is still declared, by the class,
one of its categories or the generated interface.

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
parser.add_argument('--generated', type=Path,
                    default=root / 'build/Intermediates.noindex/Horos.build/Debug/Horos.build/DerivedSources/Horos-Swift.h')
args = parser.parse_args()

app = args.products / 'IsiX DICOM Viewer.app'
generated = args.generated
if not generated.is_file() or not app.is_dir():
    print('skipped: needs a built IsiX DICOM Viewer.app (script/build_and_run.sh): --products DIR', file=sys.stderr)
    raise SystemExit(2)
registry = json.loads((root / 'tests/fixtures/swift-api-contract.json').read_text())
swift_header = generated.read_text(errors='replace')
exported = subprocess.run(['nm', '-gU', str(app / 'Contents/MacOS/IsiX DICOM Viewer')], capture_output=True, text=True).stdout


def members(declarations):
    """{('+'|'-', selector)} of an Objective-C interface body."""
    found = set()
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', declarations, flags=re.S)
    # A deprecated property (storedMountedVolume of DicomImage) ends with
    # __deprecated in the former header and SWIFT_DEPRECATED in the generated
    # one; its name is the word before that. NS_SWIFT_NONISOLATED marks
    # a member that other threads call; the selector is the same.
    text = re.sub(r'\s+(?:__deprecated|SWIFT_DEPRECATED(?:_MSG\([^)]*\))?|NS_SWIFT_NONISOLATED)\s*;', ';', text)
    for kind, signature in re.findall(r'^\s*([-+])\s*\([^;{]*?\)\s*([^;{]+)', text, re.M):
        # Without the parameter types, a part is `label:name`, and the label
        # may be empty (`-loadSeries:::keyImagesOnly:`).
        while re.search(r'\([^()]*\)', signature):
            signature = re.sub(r'\([^()]*\)', ' ', signature)
        parts = re.findall(r'(\w*)\s*:\s*\w+', signature)
        found.add((kind, ''.join(p + ':' for p in parts) if parts else signature.split()[0]))
    for attributes, name in re.findall(r'@property\s*(\([^)]*\))?[^;]*?\b(\w+)\s*;', text):
        getter = re.search(r'getter\s*=\s*(\w+)', attributes or '')
        # Swift renames a property whose name is a C++ keyword (`operator` of
        # O2DicomPredicateEditorView) and keeps the selectors in getter=
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
    return re.sub(r'(#(?:el)?if\s+__has_include\("Horos-Swift\.h"\).*?)#else.*?#endif', r'\1#endif', header, flags=re.S)


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
        # A block of methods of a class that stays Objective-C: its
        # selectors, defined in the class's .m before, are now a Swift extension.
        base = entry['base']
        if not re.search(r'extension\s+' + re.escape(base) + r'\b', swift):
            failures.append(f'{name}: {entry["swift"]} does not extend {base}')
        # The header either imports the generated interface or, outside the
        # bridging header, declares in a category every selector of the block
        # that the former header declared: a header imported before other
        # classes' interfaces cannot import the generated interface, which
        # needs them complete.
        declared_in_header = category_members(header, base, None)
        if 'HOROS_BRIDGING_HEADER' not in header or ('#import "Horos-Swift.h"' not in header and not all(
                (member[0], member[1:]) in declared_in_header for member in entry['selectors']
                if (member[0], member[1:]) in former_members)):
            failures.append(f'{name}: {entry["header"]} is not the compatibility header of the contract')
        generated_members = category_members(swift_header, base, 'SWIFT_EXTENSION(Horos)')
        # A removed implementation (the class itself became Swift) defines nothing.
        former_implementation = root / entry['former']['implementation']
        implementation = former_implementation.read_bytes().decode('latin1') if former_implementation.exists() else ''
        still_defined = defined_selectors(implementation)
        for member in entry['selectors']:
            kind, selector = member[0], member[1:]
            if (kind, selector) not in generated_members:
                failures.append(f'{name}: {member} of the "{entry["block"]}" block is not in a Swift extension of {base}')
            if not swift_declares(swift, kind, selector):
                failures.append(f'{name}: {entry["swift"]} does not declare {member}')
            if (kind, selector) in still_defined:
                failures.append(f'{name}: {entry["former"]["implementation"]} still defines {member}')
        if base not in checked_bases:
            # Whatever the former header of the class declared is still declared:
            # by the class's interface, by one of its Objective-C categories, or
            # by the generated interface.
            checked_bases.add(base)
            own_header = without_fallback((root / entry['former']['header']).read_text(errors='replace'))
            kept = members(class_interface(own_header, base) or '')
            # Compatibility actions may move into a category in the same header;
            # selectors there remain part of the public Objective-C contract.
            kept |= category_members(own_header, base, None)
            # A class that became Swift declares the rest in its generated interface.
            kept |= members(interface(swift_header, base, f'SWIFT_CLASS_NAMED("{base}")') or '')
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
        # Members the category gave up on purpose, each with its reason.
        removed = set()
        for member, reason in entry.get('removed', {}).items():
            kind, selector = member[0], member[1:]
            removed.add((kind, selector))
            if (kind, selector) not in old:
                failures.append(f'{name}: {member} is recorded as removed but the former category did not declare it')
            if (kind, selector) in new:
                failures.append(f'{name}: {member} is recorded as removed but the category still declares it')
            if not reason.strip():
                failures.append(f'{name}: {member} is recorded as removed without a reason')
        for kind, selector in sorted(old - new - removed):
            failures.append(f'{name}: {kind}{selector} of the former category is not in a Swift extension of {base}')
        print(f'{name}: {len(old)} former members kept')
        continue
    if f'@objc({name})' not in swift or not re.search(r'(public|open) (final )?class ' + name + r'\b', swift):
        failures.append(f'{name}: {entry["swift"]} does not declare a public @objc({name}) class')
    if 'forwardOnly' in entry:
        # A header that other classes' headers read before their own interface
        # (DCMView.h, PreviewView.h) only names the class: importing the
        # generated interface there would extend those classes before they are
        # declared. The files that send its messages import Horos-Swift.h.
        if '#import "Horos-Swift.h"' in header or not re.search(r'@class [^;]*\b' + name + r'\b', header):
            failures.append(f'{name}: {entry["header"]} is not the forward-only header of the contract')
    elif '#import "Horos-Swift.h"' not in header or not re.search(r'@class [^;]*\b' + name + r'\b', header) or 'HOROS_BRIDGING_HEADER' not in header:
        failures.append(f'{name}: {entry["header"]} is not the compatibility header of the contract')
    old = former_members
    new_interface = interface(swift_header, name, f'SWIFT_CLASS_NAMED("{name}")')
    if new_interface is None:
        failures.append(f'{name}: not in the generated interface {generated.name}')
        continue
    # Members an Objective-C category of the class keeps, declared in the
    # compatibility header (N2View's -layout, which Swift cannot declare).
    # A class split into extensions by responsibility (ROI) has the members
    # of those in the generated header's SWIFT_EXTENSION categories, which
    # plugins import with the class.
    new = members(new_interface) | set().union(*[members(block) for block in re.findall(
        r'@interface\s+' + name + r'\s*\(\s*\w*\s*\)(.*?)\n@end', header, re.S)] or [set()])
    new |= category_members(swift_header, name, 'SWIFT_EXTENSION(Horos)')
    # The methods Swift cannot declare, kept in an Objective-C category of the
    # class in its +CAPI.m (DCMView's float[2][3] methods).
    if 'objectiveC' in entry:
        new |= category_members((root / entry['objectiveC']).read_text(errors='replace'), name, None)
    # Members kept in Objective-C categories of the class's own compatibility
    # headers (Name+Block.h): what Swift cannot declare, such as a method
    # whose arguments are C pointers.
    for path in sorted((root / Path(entry['header']).parent).glob(name + '+*.h')):
        new |= category_members(without_fallback(path.read_text(errors='replace')), name, None)
    # Members the class gave up on purpose, each with its reason: the record
    # must name a member of the former header that the class no longer has.
    removed = set()
    for member, reason in entry.get('removed', {}).items():
        kind, selector = member[0], member[1:]
        removed.add((kind, selector))
        if (kind, selector) not in old:
            failures.append(f'{name}: {member} is recorded as removed but the former header did not declare it')
        if (kind, selector) in new:
            failures.append(f'{name}: {member} is recorded as removed but the Swift class still declares it')
        if not reason.strip():
            failures.append(f'{name}: {member} is recorded as removed without a reason')
    for kind, selector in sorted(old - new - removed):
        failures.append(f'{name}: {kind}{selector} of the former header is not in the Swift class')
    if f'_OBJC_CLASS_$_{name}\n' not in exported + '\n':
        failures.append(f'{name}: the executable does not export _OBJC_CLASS_$_{name}')
    print(f'{name}: {len(old)} former members kept')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
