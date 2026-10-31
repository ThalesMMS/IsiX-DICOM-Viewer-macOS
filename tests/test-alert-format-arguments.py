#!/usr/bin/env python3
"""An alert shows a text given to it as it is, whatever characters it has.

A message formatted first and then read as a format a second time turns a "%"
in the reason of a failure, or in a patient's name, into a specifier with no
argument behind it, which shows the wrong text or reads memory that is not an
argument. The application's alerts are Swift and Objective-C; they take the
message to show (HorosAlertPanel, the preference panes' CIARun*AlertPanel and
runAlertPanel, NSAlert's messageText and informativeText). The C variadic
HorosRunAlertPanel, HorosRunInformationalAlertPanel and
HorosRunCriticalAlertPanel take a format, and stay for plugins built against
the former SDK.

- every alert message of the application's sources, Swift or Objective-C, that
  is formatted is formatted from a literal, localized or not, and so is the
  message given to every function that passes its parameter on to an alert
  (a controller's own alert helper); every call of the C variadic functions
  gives a literal as its format;
- the alerts of a capture that fails while copying or exporting an image and the
  confirmation of merging studies are compiled as they are written, the Unify
  Patient Identity alert is compiled from PatientIdentityChoice.swift, all
  against HorosAlertPanel.m, and asked to show values full of specifiers: the
  alert shows them untouched;
- the three C variadic functions, with "%@" as their format, show such a value
  untouched, and compile with -Werror=format-security.

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
FOLDERS = ('Horos/Sources', 'Preference Panes', 'Nitrogen/Sources', 'DICOMPrint')
OWN = 'Horos/Sources/HorosAlertPanel.m'


def source(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8' if path.endswith('.swift') else 'latin1')


def sources():
    if revision:
        listed = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision,
                                          *FOLDERS]).decode().splitlines()
    else:
        listed = [str(p.relative_to(root)) for folder in FOLDERS for p in (root / folder).rglob('*')]
    return sorted(p for p in listed if p.endswith(('.m', '.mm', '.swift')))


# --- reading the sources ------------------------------------------------------

def balanced(text, i, swift):
    """Where the parenthesis opened just before `i` closes, past strings in it."""
    depth = 0
    while i < len(text):
        c = text[i]
        if c == '"' or (swift and c == '#' and re.match(r'#+"', text[i:])) or (not swift and c == "'"):
            i = literal_end(text, i, swift)
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            if depth == 0:
                return i
            depth -= 1
        i += 1
    raise AssertionError('an interpolation that does not close')


def literal_end(text, i, swift):
    """The offset just past the string (or Objective-C character) literal at `i`."""
    n = len(text)
    if not swift:
        quote = text[i]
        j = i + 1
        while j < n and text[j] != quote:
            j += 2 if text[j] == '\\' else 1
        return j + 1
    hashes = len(re.match(r'#*', text[i:]).group())
    i += hashes
    close = '"""' if text.startswith('"""', i) else '"'
    j = i + len(close)
    escape = '\\' + '#' * hashes
    while j < n:
        if text.startswith(close + '#' * hashes, j):
            return j + len(close) + hashes
        if text.startswith(escape + '(', j):
            j = balanced(text, j + len(escape) + 1, True) + 1
        elif text.startswith(escape, j):
            j += len(escape) + 1
        else:
            j += 1
    raise AssertionError('a string that does not close')


def without_comments(text, swift):
    """The text with comments blanked, strings kept, and every offset unchanged."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"' or (swift and c == '#' and re.match(r'#+"', text[i:])) or (not swift and c == "'"):
            j = literal_end(text, i, swift)
            out.append(text[i:j])
            i = j
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif text.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if swift and text.startswith('/*', j):
                    depth, j = depth + 1, j + 2
                elif text.startswith('*/', j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def masked(text, swift):
    """The text with the inside of every literal blanked, offsets unchanged: code
    is searched there, never the words of a message."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"' or (swift and c == '#' and re.match(r'#+"', text[i:])) or (not swift and c == "'"):
            j = literal_end(text, i, swift)
            out.append(c + re.sub(r'[^\n]', ' ', text[i + 1:j - 1]) + text[j - 1])
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def arguments(text, start, swift):
    """The arguments of the call whose opening parenthesis ends at `start`, and where it closes."""
    found, begin, depth, i = [], start, 0, start
    while i < len(text):
        c = text[i]
        if c == '"' or (swift and c == '#' and re.match(r'#+"', text[i:])) or (not swift and c == "'"):
            i = literal_end(text, i, swift)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                found.append(text[begin:i].strip())
                return found, i
            depth -= 1
        elif c == ',' and depth == 0:
            found.append(text[begin:i].strip())
            begin = i + 1
        i += 1
    raise AssertionError('a call that does not close')


def objc_operand(text, start):
    """The expression that starts at `start` and ends before the first comma, the
    next selector part or the bracket that closes the message, at its level."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c in '"\'':
            i = literal_end(text, i, False)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]};':
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (c == ',' or re.match(r'\s+[A-Za-z_]\w*\s*:(?!:)', text[i:])):
            break
        i += 1
    return text[start:i].strip(), i


def swift_expression(text, start):
    """The Swift expression that starts at `start` and ends with its line, unless
    the line ends with an operator or the next one goes on with one."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == '"' or (c == '#' and re.match(r'#+"', text[i:])):
            i = literal_end(text, i, True)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                break
            depth -= 1
        elif c in ';' and depth == 0:
            break
        elif c == '\n' and depth == 0:
            before = text[start:i].rstrip()
            after = text[i:].lstrip()
            if not (re.search(r'(\+|\?\?|\?|:|&&|\|\||=)$', before) or re.match(r'(\.(?!\.)|\+|\?\?|:)', after)):
                break
        i += 1
    return text[start:i].strip()


SWIFT_STRING = r'"(?:[^"\\\n]|\\[^(])*"|"""(?:[^\\]|\\[^(])*?"""'
SWIFT_LITERAL = re.compile(
    rf'({SWIFT_STRING})|NSLocalizedString\s*\(\s*(?:{SWIFT_STRING})\s*(?:,\s*(?:tableName|bundle|value|comment)\s*:\s*'
    rf'(?:{SWIFT_STRING}|nil|Bundle\.main|\.main)\s*)*\)', re.S)
OBJC_STRING = r'@?"(?:[^"\\\n]|\\.)*"'
OBJC_LITERAL = re.compile(
    rf'(?:{OBJC_STRING}\s*)+|NSLocalizedString\s*\(\s*(?:{OBJC_STRING}\s*)+,\s*(?:nil|(?:{OBJC_STRING}\s*)+)\)', re.S)

# Where a format is read: the format is the first argument (Swift) or the operand
# of the selector part (Objective-C). ObjC.format is the Swift spelling of
# +[NSString stringWithFormat:] some classes keep.
SWIFT_FORMATS = re.compile(r'\b(?:NS)?String\s*\(\s*format\s*:|\.localizedStringWithFormat\s*\(|\.appendingFormat\s*\(|'
                           r'\bObjC\s*\.\s*format\s*\(')
OBJC_FORMATS = re.compile(r'\b(?:stringWithFormat|initWithFormat|localizedStringWithFormat|stringByAppendingFormat|appendFormat)\s*:')
VARIADIC = re.compile(r'\bHorosRun(?:Critical|Informational)?AlertPanel\s*\(')

# Where an alert is given its message: (pattern, how the message is found).
SWIFT_ALERTS = [
    (re.compile(r'\bHorosAlertPanel\s*\.\s*(?:run|runInformational|runCritical|begin)\s*\('), 'message'),
    (re.compile(r'\.(?:informativeText|messageText)\s*=(?!=)'), 'assignment'),
]
OBJC_ALERTS = [
    (re.compile(r'\[\s*HorosAlertPanel\s+(?:run|runInformational|runCritical|begin)WithTitle\s*:'), 'message'),
    (re.compile(r'\.(?:informativeText|messageText)\s*=(?!=)'), 'assignment'),
    (re.compile(r'\bset(?:Informative|Message)Text\s*:'), 'operand'),
]


def message_of(text, match, how, swift):
    """The message an alert is given, and where it ends."""
    if how == 'assignment':
        if swift:
            message = swift_expression(text, match.end())
            return message, match.end() + len(message)
        end = match.end()
        while text[end] != ';':
            end = literal_end(text, end, False) if text[end] in '"\'' else end + 1
        return text[match.end():end].strip(), end
    if how == 'operand':
        return objc_operand(text, match.end())
    if not swift and how == 'message':  # [HorosAlertPanel …WithTitle: t message: m …]
        part = re.compile(r'\s+message\s*:').search(text, match.end())
        return objc_operand(text, part.end())
    given, end = arguments(text, match.end(), swift)
    if isinstance(how, int):
        return (given[how] if len(given) > how else None), end
    labeled = [a for a in given if re.match(rf'{how}\s*:(?!:)', a)]
    return (re.sub(rf'^{how}\s*:\s*', '', labeled[0], count=1) if labeled else None), end


def unformatted(expression, swift):
    """The formats read in `expression` that are not literals."""
    wrong = []
    hidden = masked(expression, swift)
    if swift:
        for site in SWIFT_FORMATS.finditer(hidden):
            given, _ = arguments(expression, site.end() if hidden[site.end() - 1] == '(' else hidden.index('(', site.start()) + 1, True)
            fmt = re.sub(r'^format\s*:\s*', '', given[0], count=1)
            if not SWIFT_LITERAL.fullmatch(fmt):
                wrong.append(fmt)
    else:
        for site in OBJC_FORMATS.finditer(hidden):
            fmt, _ = objc_operand(expression, site.end())
            if not OBJC_LITERAL.fullmatch(fmt):
                wrong.append(fmt)
        for site in VARIADIC.finditer(hidden):
            given, _ = arguments(expression, site.end(), False)
            if len(given) < 2 or not OBJC_LITERAL.fullmatch(given[1]):
                wrong.append(given[1] if len(given) > 1 else site.group())
    return wrong


def block_end(hidden, opening):
    """Where the brace at `opening` closes."""
    depth = 0
    for i in range(opening, len(hidden)):
        if hidden[i] == '{':
            depth += 1
        elif hidden[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return len(hidden)


def passed_through(text, hidden, offset, message, swift):
    """When `message` is a parameter of the function the alert at `offset` is in,
    that function as an alert of its own: its name, which of its arguments is
    the message (an index, or a Swift label), and whether only its own file
    calls it. None otherwise."""
    if not re.fullmatch(r'[A-Za-z_]\w*', message):
        return None
    pattern = (re.compile(r'\bfunc\s+(\w+)\s*(?:<[^>{]*>)?\s*\(') if swift
               else re.compile(r'^[A-Za-z_][\w \t*]*?\b(\w+)\s*\(', re.M))
    declarations = [d for d in pattern.finditer(hidden, 0, offset)]
    if not declarations:
        return None
    declaration = declarations[-1]
    try:
        parameters, close = arguments(text, declaration.end(), swift)
    except AssertionError:
        return None
    opening = hidden.find('{', close)
    if opening < 0 or ';' in hidden[close:opening]:
        return None  # a prototype
    if not (opening < offset < block_end(hidden, opening)):
        return None
    for index, parameter in enumerate(parameters):
        parameter = parameter.split('=')[0]
        if swift:
            named = re.match(r'(?:(\w+)\s+)?(\w+)\s*:', parameter)
            if named and named.group(2) == message:
                label = named.group(1) or named.group(2)
                line = hidden[hidden.rfind('\n', 0, declaration.start()) + 1:declaration.start()]
                return declaration.group(1), index if label == '_' else label, bool(re.search(r'\b(?:private|fileprivate)\b', line))
        elif re.search(rf'\b{message}\s*$', parameter):
            return declaration.group(1), index, bool(re.search(r'\bstatic\b', hidden[declaration.start():declaration.end()]))
    return None


# --- every alert of the sources -----------------------------------------------

failures = []
messages = {'swift': 0, 'objc': 0}
variadic_calls = 0
statements = {}
MARKERS = {'copy': 'The image could not be captured', 'merge': 'merge the selected studies to'}
files = {}
for path in sources():
    swift = path.endswith('.swift')
    text = without_comments(source(path), swift)
    files[path] = (swift, text, masked(text, swift))


def where(path, offset):
    return f'{path}:{files[path][1].count(chr(10), 0, offset) + 1}'


def check(path, match, how, direct=True):
    """Checks the message an alert is given; returns the function it is a
    parameter of, if any, as a new alert. A call of a function that passes its
    parameter on, without that argument, is another function of the same name."""
    swift, text, hidden = files[path]
    message, end = message_of(text, match, how, swift)
    if not message:
        if direct:
            failures.append(f'{where(path, match.start())}: an alert whose message was not found')
        return None
    messages['swift' if swift else 'objc'] += 1
    for fmt in unformatted(message, swift):
        failures.append(f'{where(path, match.start())}: the message of an alert is formatted from what is not a literal: {fmt[:90]}')
    for name, marker in MARKERS.items():
        if swift and how == 'message' and marker in message:
            statements.setdefault(name, []).append((where(path, match.start()), text[match.start():end + 1]))
    return passed_through(text, hidden, match.start(), message, swift)


# The alerts of AppKit and of HorosAlertPanel, then every function that passes
# its parameter to one of them as the message, and so on: CIARunAlertPanel,
# the preference panes' runAlertPanel, a controller's own alert helper.
wrappers = set()
pending = []
for path, (swift, text, hidden) in files.items():
    if not swift and path != OWN:
        for match in VARIADIC.finditer(hidden):
            given, _ = arguments(text, match.end(), False)
            variadic_calls += 1
            if len(given) < 5:
                failures.append(f'{where(path, match.start())}: an alert without its three buttons')
            elif not OBJC_LITERAL.fullmatch(given[1]):
                failures.append(f'{where(path, match.start())}: the format of an alert is not a literal: {given[1][:70]}')
    for pattern, how in (SWIFT_ALERTS if swift else OBJC_ALERTS):
        for match in pattern.finditer(hidden):
            found = check(path, match, how)
            if found and found[:2] not in wrappers:
                wrappers.add(found[:2])
                pending.append((path, *found))
while pending:
    home, name, how, private = pending.pop()
    call = re.compile(rf'(?<!\w){name}\s*\(')
    for path, (swift, text, hidden) in files.items():
        if (isinstance(how, str) and not swift) or (private and path != home):
            continue
        for match in call.finditer(hidden):
            line = hidden[hidden.rfind('\n', 0, match.start()) + 1:match.start()]
            if re.search(r'\bfunc\s+$', line) if swift else re.fullmatch(r'[A-Za-z_][\w \t*]*', line) and not re.search(r'\breturn\s*$', line):
                continue  # its declaration
            found = check(path, match, how, direct=False)
            if found and found[:2] not in wrappers:
                wrappers.add(found[:2])
                pending.append((path, *found))

if messages['swift'] < 400:
    failures.append(f'only {messages["swift"]} Swift alert messages were found: the sources are not being read')
if messages['objc'] < 5:
    failures.append(f'only {messages["objc"]} Objective-C alert messages were found: the sources are not being read')
if len({name for name, _ in wrappers}) < 3:
    failures.append(f'only {len(wrappers)} functions that pass their parameter to an alert were found: {sorted(wrappers, key=str)}')
if len(statements.get('copy', ())) < 3:
    failures.append(f'{len(statements.get("copy", ()))} alerts of a failed capture were found, not the three of copying and exporting')
if 'merge' not in statements:
    failures.append('the alert of merging studies was not found')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang, swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

# --- the alerts shown ---------------------------------------------------------

SHOWN_H = r'''
#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
/// The last alert run, which is not shown: runModal answers its first button.
NSAlert * _Nullable ShownAlert(void);
void ForgetShownAlert(void);
/// What each C variadic function shows, given "%@" and `value`.
NSArray<NSString *> *ShownByVariadicFunctions(NSString *value);
NS_ASSUME_NONNULL_END
'''

SHOWN_M = r'''
#import "Shown.h"
#import "HorosAlertPanel.h"

static NSAlert *shown = nil;
@implementation NSAlert (Shown)
- (NSModalResponse)runModal { [shown release]; shown = [self retain]; return NSAlertFirstButtonReturn; }
@end

NSAlert *ShownAlert(void) { return shown; }
void ForgetShownAlert(void) { [shown release]; shown = nil; }

NSArray<NSString *> *ShownByVariadicFunctions(NSString *value) {
    NSMutableArray *texts = [NSMutableArray array];
    ForgetShownAlert();
    HorosRunAlertPanel(@"Title", @"%@", @"OK", nil, nil, value);
    [texts addObject:shown.informativeText ?: @"(nothing shown)"];
    ForgetShownAlert();
    HorosRunInformationalAlertPanel(@"Title", @"%@", @"OK", @"Cancel", nil, value);
    [texts addObject:shown.informativeText ?: @"(nothing shown)"];
    ForgetShownAlert();
    HorosRunCriticalAlertPanel(@"Title", @"%@", @"OK", @"Cancel", @"Other", value);
    [texts addObject:shown.informativeText ?: @"(nothing shown)"];
    ForgetShownAlert();
    return texts;
}
'''

DRIVER = r'''
import AppKit

var failed = false
func fail(_ text: String) {
    FileHandle.standardError.write(("FAIL: " + text + "\n").data(using: .utf8)!)
    failed = true
}

/// Every text the last alert showed: its title, its message, and what its
/// accessory view lists.
func shownTexts() -> [String] {
    guard let alert = ShownAlert() else { return [] }
    var texts = [alert.messageText, alert.informativeText]
    func collect(_ view: NSView) {
        if let popUp = view as? NSPopUpButton { texts += popUp.itemTitles }
        else if let field = view as? NSTextField { texts.append(field.stringValue) }
        else if let textView = view as? NSTextView { texts.append(textView.string) }
        view.subviews.forEach(collect)
    }
    alert.accessoryView.map(collect)
    ForgetShownAlert()
    return texts
}

func expect(_ what: String, _ values: [String]) {
    let texts = shownTexts()
    if texts.isEmpty { fail("\(what): no alert was run"); return }
    for value in values where !texts.contains(where: { $0.contains(value) }) {
        fail("\(what): the alert shows \(texts), without \"\(value)\"")
    }
}

final class Study: NSObject {
    @objc dynamic var name: String
    @objc dynamic var patientID: String
    @objc dynamic var patientUID: String
    @objc dynamic var studyName: String
    @objc dynamic var dateOfBirth: Date? = nil
    init(_ name: String, _ patientID: String, _ studyName: String) {
        self.name = name; self.patientID = patientID; patientUID = name + patientID; self.studyName = studyName
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    // Specifiers with nothing behind them, and a percent sign alone.
    let hostile = "100% of %@ and %d, %s then %n%%"

    for (index, text) in ShownByVariadicFunctions(hostile).enumerated() where text != hostile {
        fail("\(["HorosRunAlertPanel", "HorosRunInformationalAlertPanel", "HorosRunCriticalAlertPanel"][index]) with \"%@\" shows \"\(text)\", not \"\(hostile)\"")
    }
    for (name, run) in [("run", HorosAlertPanel.run), ("runInformational", HorosAlertPanel.runInformational),
                        ("runCritical", HorosAlertPanel.runCritical)] {
        _ = run("Title", hostile, "OK", nil, nil)
        let texts = shownTexts()
        if texts.count < 2 || texts[1] != hostile { fail("HorosAlertPanel.\(name) shows \(texts), not \"\(hostile)\"") }
    }

COPY
    do {
        let nameAndStudy = "\(hostile) / CT %d 50%"
MERGE
    }
    do {
        let studies = [Study(hostile, "ID %@ 50%", "CT %d"), Study("ANON %s", "%n%%", "MR %@ 1%")]
        var chosen: NSObject?
        _ = PatientIdentityChoice.runUnifyAlert(for: studies, preferred: studies[1], chosen: &chosen)
        expect("unify", [hostile, "ID %@ 50%", "CT %d", "ANON %s", "%n%%"])
    }
}
if failed { exit(1) }
print("PASS: a reason, a patient name and an identifier full of specifiers are shown as they are")
'''

copy = ''.join(f'''    do {{
        let reason = hostile
        _ = {statement}
        expect("copy, {place}", [reason])
    }}
''' for place, statement in statements['copy'])
merge = ''.join(f'''        _ = {statement}
        expect("merge, {place}", [nameAndStudy])
''' for place, statement in statements['merge'])
driver = DRIVER.replace('COPY\n', copy).replace('MERGE\n', merge)

with tempfile.TemporaryDirectory(prefix='horos-alert-format-') as folder:
    folder = Path(folder)
    for name in ('HorosAlertPanel.h', 'HorosAlertPanel.m'):
        (folder / name).write_text(source(f'Horos/Sources/{name}'), encoding='latin1')
    (folder / 'Shown.h').write_text(SHOWN_H)
    (folder / 'Shown.m').write_text(SHOWN_M)
    (folder / 'Bridging.h').write_text('#import "HorosAlertPanel.h"\n#import "Shown.h"\n')
    (folder / 'PatientIdentityChoice.swift').write_text(source('Horos/Sources/PatientIdentityChoice.swift'))
    (folder / 'main.swift').write_text(driver)
    objects = []
    for name in ('HorosAlertPanel', 'Shown'):
        built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-Wformat', '-Werror=format-security', '-Werror=format',
                                '-Wno-objc-protocol-method-implementation', '-I', str(folder),
                                str(folder / f'{name}.m'), '-o', str(folder / f'{name}.o')], capture_output=True, text=True, timeout=300)
        if built.returncode:
            print(f'FAIL: {name}.m does not compile with -Werror=format-security')
            print(built.stderr[-3000:], file=sys.stderr)
            sys.exit(1)
        objects.append(str(folder / f'{name}.o'))
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(folder / 'cache'),
                            '-import-objc-header', str(folder / 'Bridging.h'), '-I', str(folder),
                            str(folder / 'PatientIdentityChoice.swift'), str(folder / 'main.swift'), *objects,
                            '-framework', 'Cocoa', '-o', str(folder / 'check')], capture_output=True, text=True, timeout=600)
    if built.returncode:
        print('FAIL: the alerts, as they are written, do not compile')
        print(built.stderr[-3000:], file=sys.stderr)
        sys.exit(1)
    ran = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=120)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        if ran.returncode < 0:
            print(f'FAIL: the alerts ended with signal {-ran.returncode}')
        else:
            print('FAIL: an alert does not show the text it was given as it is')
        sys.exit(1)
    print(ran.stdout.strip())
print(f'PASS: {messages["swift"]} Swift and {messages["objc"]} Objective-C alert messages are formatted, if at all, '
      f'from a literal; {variadic_calls} calls of the C variadic functions give a literal as their format')
