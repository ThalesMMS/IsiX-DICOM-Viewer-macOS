#!/usr/bin/env python3
"""The harnesses keep the preferences they write in their own process (#923).

Each harness is a bare executable, most often named "test", and its persistent
defaults are ~/Library/Preferences/<name>.plist, shared by every harness of
that name: a test that set a preference there could see another, running
alongside, change it between two of its checks (#874), and the file kept
AUTOCLEANING*, SAVEROIS, stackThickness and every other key the suite wrote.
tests/harness_defaults.py, compiled into a harness, sends the standard
defaults' writes to the process's argument domain.

- scan: no test's harness writes the standard defaults (-set...:forKey:,
  -removeObjectForKey:, set(_:forKey:), removeObject(forKey:), directly or
  through a variable bound to them) without compiling harness_defaults in.
  The two tests whose harness has a domain of its own, removed when it ends,
  are named below. Text quoted from an app source for a check is not a write.
- objc, swift: a harness named "test" with harness_defaults.OBJC (or SWIFT)
  reads back what it set with -setBool:, -setInteger:, -setObject: and Swift's
  set(_:forKey:), removes it, leaves a suite's persistent domain as it was
  given, and leaves nothing in the shared "test" domain.

`<git revision>` as an optional argument reads tests/ from that revision, the
negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

# Harnesses that run under a domain of their own, removed when they end.
OWN_DOMAIN = {
    'test-dicomweb-nodes.py': 'its node service driver is a uniquely named executable that removes its domain',
    'test-table-slider-views.py': 'its probe is an app with a bundle identifier of its own, whose domain it removes',
}

STANDARD = r'(?:\[\s*NSUserDefaults\s+standardUserDefaults\s*\]|NSUserDefaults\s*\.\s*standardUserDefaults|UserDefaults\s*\.\s*standard\b)'
WRITE = r'(?:set(?!VolatileDomain|PersistentDomain)\w*|removeObject\w*)'
DIRECT = re.compile(r'(?<![\'"])' + STANDARD + r'\s*\.?\s*' + WRITE + r'\s*[:(]')
BINDING = re.compile(r'\b(\w+)\s*=\s*(\[\s*\[?\s*NSUserDefaults\b|NSUserDefaults\s*\.|UserDefaults\s*[.(])')


def tests():
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', f'{revision}:tests'],
                                        text=True).split()
        for name in sorted(names):
            if name.startswith('test-') and name.endswith('.py'):
                yield name, subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:tests/{name}']) \
                    .decode('utf-8', errors='replace')
    else:
        for path in sorted((root / 'tests').glob('test-*.py')):
            yield path.name, path.read_text(encoding='utf-8', errors='replace')


def writes(text):
    """The lines that write the standard defaults, directly or through the
    variable last bound to them."""
    found, standard = [], {}
    for number, line in enumerate(text.splitlines(), 1):
        for match in BINDING.finditer(line):
            standard[match.group(1)] = re.match(r'\s*' + STANDARD, line[match.start(2):]) is not None
        hit = DIRECT.search(line)
        for name, bound in standard.items():
            if bound and not hit:
                hit = re.search(r'(?<![\'"\w])(?:\[\s*' + name + r'\s+' + WRITE + r'\s*:|' + name + r'\s*\.\s*'
                                + WRITE + r'\s*\()', line)
        if hit:
            found.append(f'{number}: {line.strip()[:120]}')
    return found


def read(path):
    if revision:
        run = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return run.stdout.decode() if run.returncode == 0 else None
    return (root / path).read_text() if (root / path).exists() else None


failures = []
this = Path(__file__).name
unguarded = []
for name, text in tests():
    if name == this or name in OWN_DOMAIN:
        continue
    lines = writes(text)
    if lines and 'harness_defaults.OBJC' not in text and 'harness_defaults.SWIFT' not in text:
        unguarded.append(f'{name} ({lines[0]}' + (f'; and {len(lines) - 1} more)' if len(lines) > 1 else ')'))
if unguarded:
    failures.append('these harnesses write the standard defaults, shared by every harness of their name, without '
                    'tests/harness_defaults.py: ' + '; '.join(unguarded))
else:
    print('ok: scan - every harness that writes the standard defaults compiles harness_defaults in')

module = read('tests/harness_defaults.py')
KEY = 'HorosHarnessDefaultsProbe923'
SUITE = 'org.horosproject.harness-defaults-probe-923'

OBJC_MAIN = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
#define CHECK(c, what) do { if (!(c)) { printf("FAIL: %s\n", what); failures++; } } while (0)
int main(void) { @autoreleasepool {
    int failures = 0;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"KEY"];
    CHECK([defaults boolForKey:@"KEY"], "setBool was not read back");
    [defaults setInteger:7 forKey:@"KEY"];
    CHECK([defaults integerForKey:@"KEY"] == 7, "setInteger was not read back");
    [defaults setObject:@"eight" forKey:@"KEY"];
    CHECK([[defaults stringForKey:@"KEY"] isEqual:@"eight"], "setObject was not read back");
    [defaults synchronize];
    CHECK([defaults persistentDomainForName:NSProcessInfo.processInfo.processName][@"KEY"] == nil,
          "the key reached the persistent domain");
    [defaults removeObjectForKey:@"KEY"];
    CHECK([defaults objectForKey:@"KEY"] == nil, "removeObjectForKey left the key");
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"SUITE"];
    [suite setInteger:3 forKey:@"KEY"];
    CHECK([[suite persistentDomainForName:@"SUITE"][@"KEY"] integerValue] == 3, "the suite did not keep its key");
    [suite removePersistentDomainForName:@"SUITE"];
    if (!failures) printf("read back, removed, suite kept\n");
    return failures ? 1 : 0;
} }
'''.replace('SUITE', SUITE).replace('KEY', KEY)

SWIFT_MAIN = r'''
import Foundation
var failures = 0
func check(_ c: Bool, _ what: String) { if !c { print("FAIL: " + what); failures += 1 } }
let defaults = UserDefaults.standard
defaults.set(true, forKey: "KEY"); check(defaults.bool(forKey: "KEY"), "set(Bool) was not read back")
defaults.set(7, forKey: "KEY"); check(defaults.integer(forKey: "KEY") == 7, "set(Int) was not read back")
defaults.set("eight", forKey: "KEY"); check(defaults.string(forKey: "KEY") == "eight", "set(String) was not read back")
defaults.synchronize()
check(defaults.persistentDomain(forName: ProcessInfo.processInfo.processName)?["KEY"] == nil,
      "the key reached the persistent domain")
defaults.removeObject(forKey: "KEY"); check(defaults.object(forKey: "KEY") == nil, "removeObject left the key")
let suite = UserDefaults(suiteName: "SUITE")!
suite.set(3, forKey: "KEY")
check(suite.persistentDomain(forName: "SUITE")?["KEY"] as? Int == 3, "the suite did not keep its key")
suite.removePersistentDomain(forName: "SUITE")
if failures == 0 { print("read back, removed, suite kept") }
exit(failures == 0 ? 0 : 1)
'''.replace('SUITE', SUITE).replace('KEY', KEY)


def shared_key():
    """The probe's key in the shared "test" domain, removed if it is there."""
    run = subprocess.run(['defaults', 'read', 'test', KEY], capture_output=True, text=True)
    if run.returncode == 0:
        subprocess.run(['defaults', 'delete', 'test', KEY], capture_output=True)
        return run.stdout.strip()
    return None


if module is None:
    failures.append('objc, swift: there is no tests/harness_defaults.py')
elif shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang, swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)
else:
    namespace = {}
    exec(compile(module, 'harness_defaults.py', 'exec'), namespace)
    with tempfile.TemporaryDirectory(prefix='horos-harness-defaults-') as tmp:
        tmp = Path(tmp)
        for case, source, build in (
                ('objc', OBJC_MAIN + namespace['OBJC'], lambda s, o: ['xcrun', 'clang', '-fobjc-arc', '-framework',
                                                                      'Foundation', str(s), '-o', str(o)]),
                ('swift', namespace['SWIFT'] + SWIFT_MAIN, lambda s, o: ['xcrun', 'swiftc', str(s), '-o', str(o)])):
            folder = tmp / case
            folder.mkdir()
            source_file = folder / ('main.m' if case == 'objc' else 'main.swift')
            source_file.write_text(source)
            built = subprocess.run(build(source_file, folder / 'test'), capture_output=True, text=True)
            if built.returncode:
                failures.append(f'{case}: the harness did not build: {built.stderr[-1500:]}')
                continue
            result = subprocess.run([str(folder / 'test')], capture_output=True, text=True, timeout=60)
            left = shared_key()
            lines = [line for line in result.stdout.splitlines() if line.strip()]
            problems = [line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')]
            if result.returncode and not problems:
                problems.append(f'exit {result.returncode}: {result.stderr.strip()[-300:]}')
            if left is not None:
                problems.append(f'the shared "test" domain kept {KEY} = {left}')
            if problems:
                failures.append(f'{case}: ' + '; '.join(problems))
            else:
                print(f'ok: {case} - {lines[-1] if lines else "exit 0"}; nothing in the shared "test" domain')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: every harness that writes the standard defaults keeps them in its own argument domain, which reads '
      'back what it was given and leaves the shared domain of its name alone')
