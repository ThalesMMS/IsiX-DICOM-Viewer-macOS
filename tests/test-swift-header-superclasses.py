#!/usr/bin/env python3
"""Every superclass in the generated Swift header must be declared by the prefix
header.

`Horos-Swift.h` re-declares each `@objc` Swift class for Objective-C, including
its superclass, and the framework imports it writes for those superclasses sit
behind `#if __has_feature(objc_modules)`. This target compiles without modules,
so those imports vanish and the superclass has to come from somewhere else. When
it does not, every file that includes the generated header stops compiling:

    Horos-Swift.h:2418:36: error: cannot find interface declaration for
    'NSPreferencePane', superclass of 'HorosMenuShortcutPref'

This check compiles one probe against nothing but the prefix header, which is
the same question the build asks, without needing a full build.

A superclass the project declares is not the prefix header's business: the
generated header imports the bridging header, which declares it. Now
Swift classes also subclass project classes outside Horos/Sources
(WebPortalDatabase is an N2ManagedDatabase, WebPortalServer an HTTPServer), so
the project's other header folders count as well.

The bridging header also imports system framework headers, directly or through
the project headers it imports (SFHorosAuthorizationView.h brings in
SFAuthorizationView, the superclass of the Swift class of that name). Those
declarations reach the generated header the same way, so the probe imports
them after the prefix header; a superclass that neither declares still fails.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
prefix = root / 'Horos/prefix.pch'
failures = []

declaration = re.compile(
    r'@objc\((\w+)\)\s*(?:@\w+\s*)*(?:public\s+|internal\s+|final\s+|open\s+)*'
    r'class\s+(\w+)\s*:\s*(\w+)')

superclasses = {}
for source in sorted((root / 'Horos/Sources').glob('*.swift')):
    text = source.read_text(encoding='utf-8', errors='replace')
    for match in declaration.finditer(text):
        superclasses.setdefault(match.group(3), set()).add(source.name)

if not superclasses:
    print('FAIL: no @objc Swift class was found to check', file=sys.stderr)
    sys.exit(1)

# A superclass declared in the checkout comes from a project header, not from a
# framework, so the prefix header is not responsible for it.
project_classes = set()
for pattern in ('Horos/Sources/*.h', 'Horos/Sources/*.swift', 'Nitrogen/Sources/*.h'):
    for source in root.glob(pattern):
        text = source.read_text(encoding='utf-8', errors='replace')
        # Only a real class declaration counts; `@interface NSPreferencePane
        # (Horos)` is a category on a framework class, not a definition of it.
        project_classes.update(re.findall(r'@interface\s+(\w+)\s*:', text))
        project_classes.update(re.findall(r'@objc\((\w+)\)', text))

# The internal modules' classes come with the module's own generated header,
# which Horos-Swift.h imports; Swift writes the superclass by its Swift name.
for source in root.glob('Modules/*/Sources/**/*.swift'):
    text = source.read_text(encoding='utf-8', errors='replace')
    project_classes.update(match.group(2) for match in declaration.finditer(text))
    project_classes.update(re.findall(r'@objc\(\w+\)\s*(?:@\w+\s*)*(?:public\s+|open\s+|final\s+)*class\s+(\w+)', text))

external = sorted(name for name in superclasses if name not in project_classes)

sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True)
if sdk.returncode != 0:
    print('needs an installed SDK: %s' % sdk.stderr.strip(), file=sys.stderr)
    raise SystemExit(2)
frameworks = Path(sdk.stdout.strip()) / 'System/Library/Frameworks'

# The system framework headers the bridging header imports, itself or through
# the project headers it imports in turn.
header_folders = [root / 'Horos/Sources', root / 'Nitrogen/Sources']
bridging = root / 'Horos/Sources/Horos-Bridging-Header.h'
if not bridging.is_file():
    print('FAIL: no bridging header at %s' % bridging.relative_to(root), file=sys.stderr)
    sys.exit(1)
system_imports, seen, todo = [], set(), [bridging]
while todo:
    header = todo.pop(0)
    text = header.read_bytes().decode('latin1')
    for quoted, angled in re.findall(r'^\s*#\s*(?:import|include)\s+(?:"([^"]+)"|<([^>]+)>)', text, re.M):
        if angled:
            framework = angled.split('/')[0]
            if '/' in angled and (frameworks / f'{framework}.framework').is_dir() and angled not in system_imports:
                system_imports.append(angled)
            continue
        found = next((folder / quoted for folder in [header.parent] + header_folders
                      if (folder / quoted).is_file()), None)
        if found and found.resolve() not in seen:
            seen.add(found.resolve())
            todo.append(found)

def resolves(names, tmp):
    """Compile one probe subclassing each name; return the names clang rejected."""
    if not names:
        return []
    probe = Path(tmp) / ('probe-%d.m' % abs(hash(tuple(names))))
    body = ['// Generated by tests/test-swift-header-superclasses.py']
    body += ['#import <%s>' % name for name in system_imports]
    for index, name in enumerate(names):
        body.append('@interface HorosPrefixProbe%d : %s\n@end' % (index, name))
        body.append('@implementation HorosPrefixProbe%d\n@end' % index)
    probe.write_text('\n'.join(body) + '\n')
    done = subprocess.run(
        ['xcrun', 'clang', '-x', 'objective-c', '-fsyntax-only',
         '-isysroot', sdk.stdout.strip(),
         '-include', str(prefix), str(probe)],
        capture_output=True, text=True)
    if done.returncode == 0:
        return []
    rejected = []
    for line in done.stderr.splitlines():
        if 'error:' not in line:
            continue
        for name in names:
            if "'%s'" % name in line:
                rejected.append((name, line.split('error:')[-1].strip()))
                break
        else:
            rejected.append((None, line.strip()))
    return rejected


with tempfile.TemporaryDirectory(prefix='horos-swift-superclass-') as tmp:
    rejected = resolves(external, tmp)
    for name, message in rejected:
        if name is None:
            failures.append(message)
            continue
        # The Swift overlay renames some Foundation classes, and the generated
        # header emits the Objective-C name: Formatter is NSFormatter there.
        if not name.startswith('NS') and not resolves(['NS' + name], tmp):
            continue
        failures.append('%s is a superclass in %s but the prefix header does not '
                        'declare it: %s' % (name, ', '.join(sorted(superclasses[name])), message))

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: %d framework superclass(es) reachable from the prefix header: %s'
      % (len(external), ', '.join(external)))
