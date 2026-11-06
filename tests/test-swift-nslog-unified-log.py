#!/usr/bin/env python3
"""NSLog called from Swift reaches the unified log, as from Objective-C, from the
application and from the internal modules alike.

Foundation's Swift overlay implements NSLog itself, and its line does not reach
the unified log as an Objective-C one does. The application runs with standard
error going nowhere, so its Swift diagnostics were lost or unreadable while the
Objective-C ones were not. IsiXLogging, the first internal module, has the one
implementation, unifiedLogv, which calls Foundation's C NSLogv. The application
(Horos/Sources/UnifiedLogNSLog.swift) and every internal module that logs
(Modules/<Name>/Sources/UnifiedLogNSLog.swift) declare their own NSLog over it,
which shadows Foundation's inside that module.

NSLogv hands the unified log the format and the arguments apart only when the
format exposes a C string inside a loaded image, as an Objective-C literal does;
otherwise the whole line is one private string, shown as <private>. A Swift
literal of up to 15 UTF-8 bytes bridged from String does not ("Scissor Start"
was <private>, "New pt: %2.2f %2.2f" was not), so NSLog takes a StaticString and
unifiedLogv hands NSLogv a CFString made over the literal's bytes without
copying them (CFStringCreateWithCStringNoCopy, public API). A format of up to 7
bytes still comes out <private>: CoreFoundation keeps it inside the string
reference (a tagged pointer), with no pointer to the executable.

This compiles IsiXLogging, a module made of a module's NSLog file and a caller,
and the application's NSLog file with a caller, runs them in one process with
standard error discarded, and reads its lines in the unified log. From the
application and from the module:

1. literals of 10, 13 and 25 bytes, with and without numbers, read as written;
2. a string argument stays <private>, as from Objective-C (patient data);
3. a format that is not ASCII stays <private>, as an Objective-C one does, and
   so does one of up to 7 bytes (the limit above);
4. a format built at run time does not compile;
5. the files name no private Objective-C method.

It also checks that every internal module whose Swift calls NSLog, and the
Decompress service, which compiles Swift of its own, has the same NSLog file;
that the application and the service compile theirs and link IsiXLogging; and,
when a Debug build is present, that neither the application's objects nor the
internal modules' nor the service's call Foundation's Swift NSLog, and that the
executable holds no _fastCStringContents.

    python3 tests/test-swift-nslog-unified-log.py [--source FILE] [--module-source FILE]

--source compiles another version of the application's file, --module-source
another version of the modules' file (the negative controls: the application's
file before the StaticString format fails 1 for the short literals; an empty
module file, Foundation's NSLog, fails 1 for every module line).
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
arguments = sys.argv[1:]


def option(name, default):
    return Path(arguments[arguments.index(name) + 1]) if name in arguments else default


source = option('--source', root / 'Horos/Sources/UnifiedLogNSLog.swift')
module_source = option('--module-source', root / 'Modules/IsiXImaging/Sources/UnifiedLogNSLog.swift')
logging_source = root / 'Modules/IsiXLogging/Sources/UnifiedLog.swift'
failures = []

LITERAL_NSLOG = 'func NSLog(_ format: StaticString, _ args: CVarArg...)'
STRING_NSLOG = 'func NSLog(_ format: String, _ args: CVarArg...)'


def declares_nslog(text):
    """What a file that declares a module's NSLog lacks."""
    missing = []
    if LITERAL_NSLOG not in text or 'unifiedLogv' not in text or 'import IsiXLogging' not in text:
        missing.append('an NSLog with a literal format that calls IsiXLogging\'s unifiedLogv')
    if '@available(*, unavailable' not in text or STRING_NSLOG not in text:
        missing.append('a String NSLog marked unavailable, so that a format built at run time is refused')
    return missing


text = source.read_text() if source.is_file() else ''
module_text = module_source.read_text() if module_source.is_file() else ''
logging_text = logging_source.read_text() if logging_source.is_file() else ''
if '--source' not in arguments:
    failures += ['Horos/Sources/UnifiedLogNSLog.swift lacks %s' % lack for lack in declares_nslog(text)]
if '--module-source' not in arguments:
    failures += ['the modules\' NSLog file lacks %s' % lack for lack in declares_nslog(module_text)]
if 'public func unifiedLogv(_ format: StaticString, _ arguments: [CVarArg])' not in logging_text \
        or 'NSLogv' not in logging_text:
    failures.append('IsiXLogging does not declare unifiedLogv over NSLogv')
for name, checked in (('the NSLog file', text), ('the modules\' NSLog file', module_text), ('IsiXLogging', logging_text)):
    if '_fastCStringContents' in checked or 'objc_allocateClassPair' in checked:
        failures.append(f'{name} reaches the format through a private Objective-C method')

# IsiXLogging first, so that every module may depend on it; the application
# compiles its NSLog file and links the module.
manifest = (root / 'Modules/Package.swift').read_text()
targets = re.findall(r'\.target\(name: "(\w+)"', manifest)
if not targets or targets[0] != 'IsiXLogging':
    failures.append('IsiXLogging is not the first module of Modules/Package.swift')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
graph = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-',
                                   str(root / 'Horos.xcodeproj/project.pbxproj')],
                                  capture_output=True, text=True, check=True).stdout)['objects']
for target_name in ('Horos', 'Decompress'):
    target = next(v for v in graph.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == target_name)
    phases = [graph[phase] for phase in target['buildPhases']]
    products = {graph[ref].get('productName') for ref in target.get('packageProductDependencies', [])}
    linked = {graph[graph[f]['productRef']].get('productName') for phase in phases
              if phase.get('isa') == 'PBXFrameworksBuildPhase' for f in phase['files'] if 'productRef' in graph[f]}
    compiled = {graph[graph[f]['fileRef']].get('path') for phase in phases
                if phase.get('isa') == 'PBXSourcesBuildPhase' for f in phase['files'] if 'fileRef' in graph[f]}
    if 'IsiXLogging' not in products or 'IsiXLogging' not in linked:
        failures.append(f'the {target_name} target does not link IsiXLogging')
    if 'UnifiedLogNSLog.swift' not in compiled:
        failures.append(f'the {target_name} target does not compile its UnifiedLogNSLog.swift')

# Every internal module whose Swift logs has the same NSLog file, which shadows
# Foundation's there.
reference_shim = (root / 'Modules/IsiXImaging/Sources/UnifiedLogNSLog.swift')
reference_text = reference_shim.read_text() if reference_shim.is_file() else ''
for folder in sorted((root / 'Modules').glob('IsiX*/Sources')) + [root / 'Decompress']:
    module = folder.parent.name if folder.name == 'Sources' else folder.name
    if module == 'IsiXLogging':
        continue
    calls = [path for path in sorted(folder.rglob('*.swift')) if path.name != 'UnifiedLogNSLog.swift'
             and re.search(r'(?<![\w.])NSLog\(', path.read_text())]
    shim = folder / 'UnifiedLogNSLog.swift'
    if calls and not shim.is_file():
        failures.append(f'{module} logs ({calls[0].name}) without its own NSLog: add {shim.relative_to(root)}')
    elif shim.is_file() and shim.read_text() != reference_text:
        failures.append(f'{shim.relative_to(root)} differs from the other modules\' NSLog file')

# Objects of a Debug build: the application's own, and the internal modules'.
build = root / 'build/Build/Intermediates.noindex'
object_sets = {
    'the application\'s Swift': sorted((build / 'Horos.build/Debug/Horos.build/Objects-normal').glob('*/*.o')),
    'the internal modules': sorted(build.glob('IsiXModules.build/Debug/IsiX*.build/Objects-normal/*/*.o')),
    'the Decompress service': sorted((build / 'Horos.build/Debug/Decompress.build/Objects-normal').glob('*/*.o')),
}
for label, objects in object_sets.items():
    calling = []
    for start in range(0, len(objects), 200):
        listed = subprocess.run(['nm', '-u', '-A'] + [str(o) for o in objects[start:start + 200]],
                                capture_output=True, text=True).stdout
        calling += [line.split(':')[0] for line in listed.splitlines() if '$s10Foundation5NSLog' in line]
    if calling:
        failures.append('%s still calls Foundation\'s NSLog: %s'
                        % (label, ', '.join(sorted({str(Path(c).relative_to(build)) for c in calling})[:10])))
    elif objects:
        print(f'ok: {len(objects)} objects of {label} in the Debug build, none calls Foundation\'s NSLog')
executable = root / 'build/Build/Products/Debug/IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer'
if executable.is_file() and b'_fastCStringContents' in executable.read_bytes():
    failures.append('the Debug executable names _fastCStringContents, a private method')


def lines_of(program, count):
    """The messages the program logged, in order, as the unified log shows them."""
    begin = time.time()
    subprocess.run([str(program)], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=True, timeout=60)
    messages = []
    for _ in range(15):
        time.sleep(1)
        shown = subprocess.run(['/usr/bin/log', 'show', '--start',
                                time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(begin - 2)), '--style', 'json',
                                '--predicate', 'process == "%s"' % program.name],
                               capture_output=True, text=True, timeout=120)
        if shown.returncode != 0:
            return None
        try:
            events = json.loads(shown.stdout or '[]')
        except json.JSONDecodeError:
            continue
        messages = [e.get('eventMessage', '') for e in events if e.get('eventType') == 'logEvent']
        if len(messages) >= count:
            return messages
    return messages


tag = uuid.uuid4().hex[:6]
probe_name = 'horos-nslog-' + tag
secret = 'SECRET^' + uuid.uuid4().hex[:8]


def cases(mark):
    """(format, arguments, the line the log must show); `mark` tells the callers apart."""
    return [
        (f'S{mark}{tag} go', '', f'S{mark}{tag} go'),                          # 11 bytes
        (f'M{mark}{tag} Start', '', f'M{mark}{tag} Start'),                    # 14 bytes, as "Scissor Start"
        (f'S{mark}{tag} %d', ', Int32(7)', f'S{mark}{tag} 7'),                 # short, with a number
        (f'L{mark}{tag} new pt: %2.2f %2.2f', ', 1.5, 2.25', f'L{mark}{tag} new pt: 1.50 2.25'),  # as "New pt"
        (f'P{mark}{tag} %@ %ld', f', "{secret}" + String(CommandLine.arguments.count), 3', f'P{mark}{tag} <private> 3'),
        (f'U{mark}{tag} é %d', ', Int32(1)', '<private>'),
        ('go %d', ', Int32(5)', '<private>'),                                  # 5 bytes: a tagged pointer
    ]


def calls(listed):
    return ''.join(f'    NSLog("{fmt}"{args})\n' for fmt, args, _ in listed)


# The marks are not letters CoreFoundation packs into a tagged pointer, so the
# formats of 11 bytes keep their pointer whatever the random tag.
callers = [('the application', cases('#')), ('a module', cases('!'))]
with tempfile.TemporaryDirectory(prefix='horos-nslog-') as directory:
    folder = Path(directory)
    built = None
    try:
        logging = isix_modules.module_flags('IsiXLogging', folder / 'modules')
    except subprocess.CalledProcessError as error:
        failures.append('IsiXLogging does not compile: %s' % (error.stderr or '')[-800:])
        logging = None
    if logging is not None:
        # A module that logs, as IsiXImaging does: its NSLog file and a caller.
        (folder / 'ModuleCaller.swift').write_text('import Foundation\n\npublic func moduleLogs() {\n'
                                                   + calls(callers[1][1]) + '}\n')
        built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'IsiXProbe',
                                '-emit-library', '-static', '-emit-module', '-emit-module-path',
                                str(folder / 'modules/IsiXProbe.swiftmodule'), '-I', str(folder / 'modules'),
                                '-o', str(folder / 'modules/libIsiXProbe.a'), str(module_source),
                                str(folder / 'ModuleCaller.swift')], capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            failures.append('the modules\' NSLog file does not compile: %s' % built.stderr[-800:])
    if built is not None and built.returncode == 0:
        (folder / 'main.swift').write_text('import Foundation\nimport IsiXProbe\n\nfunc applicationLogs() {\n'
                                           + calls(callers[0][1]) + '}\n\napplicationLogs()\nmoduleLogs()\n')
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', *logging,
                                '-lIsiXProbe', str(source), str(folder / 'main.swift'), '-o', str(folder / probe_name)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            failures.append('the NSLog file does not compile: %s' % built.stderr[-800:])
        else:
            expected = [case for _, listed in callers for case in listed]
            messages = lines_of(folder / probe_name, len(expected))
            if messages is None:
                print('SKIP: the unified log cannot be read here (/usr/bin/log show failed)')
                sys.exit(2)
            shown_lines = iter(messages + [None] * len(expected))
            for caller, listed in callers:
                for fmt, _, wanted in listed:
                    shown = next(shown_lines)
                    if shown != wanted:
                        failures.append(f'NSLog("{fmt}") from {caller} shows {shown!r} in the unified log, '
                                        f'{wanted!r} expected')
                    else:
                        print(f'ok: NSLog("{fmt}") from {caller} -> {shown!r}')
            if any(secret in (m or '') for m in messages):
                failures.append('a string argument reached the unified log in the clear')

    # A format built at run time does not compile, in the application or in a module.
    for caller, file, given in (('the application', source, '--source'),
                                ('a module', module_source, '--module-source')):
        if given in arguments or logging is None:
            continue
        dynamic = folder / ('dynamic-' + caller.split()[-1])
        dynamic.mkdir()
        (dynamic / 'caller.swift').write_text('import Foundation\n\nfunc dynamicLog() {\n'
                                              '    let text = CommandLine.arguments[0]\n    NSLog(text)\n}\n')
        refused = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-name', 'Dynamic',
                                  '-typecheck', '-I', str(folder / 'modules'), str(file), str(dynamic / 'caller.swift')],
                                 capture_output=True, text=True, timeout=300)
        if refused.returncode == 0 or 'unavailable' not in refused.stderr:
            failures.append(f'a format built at run time compiles in {caller}: '
                            'it would log the whole line as <private>')
        else:
            print(f'ok: a format built at run time does not compile in {caller}')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: NSLog from the application\'s and the internal modules\' Swift reaches the unified log as from '
      'Objective-C, with standard error discarded')
