#!/usr/bin/env python3
"""An alert shows a text given to it as it is, whatever characters it has.

HorosRunAlertPanel, HorosRunInformationalAlertPanel and HorosRunCriticalAlertPanel
take a format and its arguments. A caller that formats the message first and
passes the result as the format has it read a second time: a "%" in the reason
of a failure, or in a patient's name, becomes a specifier with no argument
behind it, which shows the wrong text or reads memory that is not an argument.

- every call in the application's sources gives a literal, localized or not,
  as its format;
- the three calls that used to format first - the capture that fails while
  copying an image, and the confirmations of unifying a patient's identity and
  of merging studies - are compiled here as they are written, with
  -Werror=format-security, against HorosAlertPanel.m, and asked to show values
  full of specifiers: the alert shows them untouched.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
CALL = re.compile(r'HorosRun(?:Critical|Informational)?AlertPanel\s*\(')
LITERAL = re.compile(r'(NSLocalizedString\s*\(\s*@"(?:[^"\\]|\\.)*"\s*,\s*(?:nil|@"(?:[^"\\]|\\.)*")\s*\)|@"(?:[^"\\]|\\.)*")', re.S)


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def sources():
    if revision:
        listed = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision,
                                          'Horos/Sources', 'Preference Panes', 'Nitrogen/Sources', 'DICOMPrint']).decode().splitlines()
    else:
        listed = [str(p.relative_to(root)) for folder in ('Horos/Sources', 'Preference Panes', 'Nitrogen/Sources', 'DICOMPrint')
                  for p in (root / folder).rglob('*')]
    return sorted(p for p in listed if p.endswith(('.m', '.mm')))


def without_comments(text):
    """The text with comments blanked, strings kept, and every offset unchanged."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
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
            out.append(c)
            i += 1
    return ''.join(out)


def arguments(text, start):
    """The arguments of the call whose opening parenthesis ends at `start`, and where it closes."""
    found, current, depth, i = [], '', 0, start
    while i < len(text):
        c = text[i]
        if c == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            current += text[i:j + 1]
            i = j + 1
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                found.append(current.strip())
                return found, i
            depth -= 1
        elif c == ',' and depth == 0:
            found.append(current.strip())
            current = ''
            i += 1
            continue
        current += c
        i += 1
    raise AssertionError('a call that does not close')


failures = []
calls = 0
statements = {}
for path in sources():
    if path.endswith('HorosAlertPanel.m'):
        continue
    text = without_comments(source(path))
    for match in CALL.finditer(text):
        given, end = arguments(text, match.end())
        calls += 1
        line = text.count('\n', 0, match.start()) + 1
        if len(given) < 5:
            failures.append(f'{path}:{line}: an alert without its three buttons')
        elif not LITERAL.fullmatch(given[1]):
            failures.append(f'{path}:{line}: the format of an alert is not a literal: {given[1][:70]}')
        for name, marker in (('copy', 'The image could not be captured'),
                             ('unify', 'unify the patient identity'), ('merge', 'merge the selected studies to')):
            if marker in given[1]:
                statements[name] = text[match.start():end + 1] + ';'
if calls < 200:
    failures.append(f'only {calls} alert calls were found: the sources are not being read')
for name in ('copy', 'unify', 'merge'):
    if name not in statements:
        failures.append(f'the alert of "{name}" was not found')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import "HorosAlertPanel.h"

static NSString *shown = nil;
// What the alert would show, without showing it.
@implementation NSAlert (Shown)
- (NSModalResponse)runModal { [shown release]; shown = [self.informativeText copy]; return NSAlertFirstButtonReturn; }
@end

@interface Study : NSObject
@property(copy) NSString *name, *patientID, *studyName;
@end
@implementation Study
@end

static int failed = 0;
static void expect(NSString *what, NSString *value) {
    if (shown == nil || [shown rangeOfString:value].location == NSNotFound) {
        fprintf(stderr, "FAIL: %s: the alert shows \"%s\", without \"%s\"\n", what.UTF8String, shown.UTF8String, value.UTF8String);
        failed = 1;
    }
    [shown release]; shown = nil;
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    // Specifiers with nothing behind them, and a percent sign alone.
    NSString *hostile = @"100% of %@ and %d, %s then %n%%";
    {
        NSString *reason = hostile;
        COPY
        expect(@"copy", reason);
    }
    Study *destStudy = [[Study new] autorelease];
    destStudy.name = hostile; destStudy.patientID = @"ID %@ 50%"; destStudy.studyName = @"CT %d";
    {
        UNIFY
        (void)result;
        expect(@"unify", destStudy.name);
    }
    {
        NSString *nameAndStudy = [NSString stringWithFormat: @"%@ / %@", destStudy.name, destStudy.studyName];
        MERGE
        (void)result;
        expect(@"merge", nameAndStudy);
    }
    {
        UNIFY
        (void)result;
        expect(@"unify, the identifier", destStudy.patientID);
    }
    if (failed) return 1;
    puts("PASS: a reason, a patient name and an identifier full of specifiers are shown as they are");
    return 0;
}}
'''
driver = DRIVER.replace('COPY', statements['copy']).replace('MERGE', 'NSInteger result = ' + statements['merge'])
driver = driver.replace('UNIFY', 'NSInteger result = ' + statements['unify'])

with tempfile.TemporaryDirectory(prefix='horos-alert-format-') as folder:
    folder = Path(folder)
    for name in ('HorosAlertPanel.h', 'HorosAlertPanel.m'):
        (folder / name).write_bytes(source(f'Horos/Sources/{name}').encode('latin1'))
    (folder / 'main.m').write_text(driver)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wformat', '-Werror=format-security', '-Werror=format',
                            '-Wno-objc-protocol-method-implementation', '-I', str(folder),
                            str(folder / 'main.m'), str(folder / 'HorosAlertPanel.m'),
                            '-framework', 'Cocoa', '-o', str(folder / 'check')], capture_output=True, text=True)
    if built.returncode:
        print('FAIL: a call does not compile with -Werror=format-security')
        print(built.stderr[-3000:], file=sys.stderr)
        sys.exit(1)
    ran = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=120)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        if ran.returncode < 0:
            print(f'FAIL: the alerts ended with signal {-ran.returncode}')
        sys.exit(1)
    print(ran.stdout.strip())
print(f'PASS: {calls} alert calls give a literal as their format')
