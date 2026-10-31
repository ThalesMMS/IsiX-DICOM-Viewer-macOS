#!/usr/bin/env python3
"""Count the two axes of modern Swift and organized code, and keep them from rising.

The code converted from Objective-C behaves the same, but much of it still has
the shape of Objective-C (axis A, Swift idiom), and the large classes were spread
over extension files without becoming smaller (axis B, organization). Both are
measured here over the files git tracks in the checkout (`git ls-files`, read
from the working tree), and tests/swift-idiom-registry.json keeps the numbers,
which may only fall.

Axis A counts, in every .swift file of Horos/Sources and Modules, the lines that
hold each pattern:
- nonisolated_unsafe: `nonisolated(unsafe)`;
- thread_perform: `Thread(target:` and `perform(#selector`. The second is not
  always background work: it also counts the emulations of a message to nil and
  the `afterDelay` calls of a run loop, which is why the count alone does not
  say how many threads a file starts;
- background_start: what starts work off the calling thread without naming a
  thread of a type of its own: `performSelector(inBackground:`,
  `Thread.detachNewThread`, `Thread.detachNewThreadSelector`,
  `Thread.performBlock(inBackground:`, `Thread {`, `Thread(block:`,
  `DispatchQueue.global` and `OperationQueue()`. The name Thread as a type
  (`class Worker: Thread {`, `-> Thread {`) and types such as N2BlockThread do
  not count;
- ns_collection: NSDictionary, NSMutableDictionary, NSArray, NSMutableArray
  (whole identifiers: NSArrayController is not a collection);
- kvc: `value(forKey:`, `value(forKeyPath:` and `setValue(`;
- force_cast: `as!`;
- objc_exception: HorosObjCException and the identifiers that start with it
  (HorosObjCExceptionKey, which reads the caught exception back).

Axis B counts, in the .swift, .m and .mm files of Horos/Sources:
- per file, the lines that reach a global or post a notification, in the form
  of each language:
  - current_browser: `BrowserController.currentBrowser()`,
    `[BrowserController currentBrowser]`;
  - app_controller_shared: `AppController.shared`,
    `[AppController sharedAppController]`;
  - user_defaults: `UserDefaults.standard`, `[NSUserDefaults standardUserDefaults]`;
  - notification_post: `.post(name:`, `NotificationCenter.default.post(`,
    `postNotificationOnMainThread...(`, `#selector(NotificationCenter.post(`,
    `postNotificationName:`, `postNotification:`;
  - direct_ingest: what reaches the index or the incoming folder without the
    single entry, DatabaseIngest: `addFiles(atPaths:`, `addFilesDescribed(`
    (`addFilesAtPaths:`, `addFilesDescribedInDictionaries:`), the imports of
    the folder (`importFiles(fromIncomingDir`, `importFilesFromIncomingDir`,
    `importFilesFromIncomingDirThread`,
    `initiateImportFilesFromIncomingDirUnlessAlreadyImporting`) and
    `incomingDirPath`, `incomingDirPathC`;
- in every .swift file of Horos/Sources and Modules, preference_literal: the
  lines that read or write a preference by a literal key rather than through
  the typed keys of the IsiXPreferences catalog. It is counted on the code with
  its comments blanked and its strings kept: a UserDefaults or preference-store
  accessor with `forKey: "..."` (with any receiver for `bool`, `integer`,
  `float`, `double` and `stringArray`, which only UserDefaults has; with a
  receiver named as the preferences are, `UserDefaults.standard`, `defaults`,
  `userDefaults`, `preferences` or `store`, for `string`, `array`,
  `dictionary`, `data`, `url`, `object`, `set` and `removeObject`, which
  dictionaries have too), and a key path of NSUserDefaultsController,
  `"values.<key>"`. The keys of the system (NS..., Apple...) and the reads of
  the domains of other applications are exceptions with their reason. It was
  born with a baseline made by hand: a path whose only entry is
  preference_literal is not a new path while the previous registry had none;
- per hub class (ViewerController, BrowserController, DCMView, DicomDatabase,
  AppController), the lines of the type, counted by type and not by file name:
  the Swift `class X` and every top-level `extension X` (also through a
  typealias of X), and every Objective-C `@implementation X` and category
  `@implementation X (Category)`, each from its declaration line to its closing
  brace or `@end`. An extension in a new file adds to the same number;
- the files above 2,000 lines (and, printed, those above 4,000), with their size.

Printed but not locked, because they rise and fall for legitimate reasons
(nibs, bindings, Objective-C callers, conversions still entering the app): the
lines with `@objc`, with a `struct` or `enum` declaration and with `async` or
`await`, and the share of Swift lines that live in Modules.

Comments and string literals are blanked before counting, the same way for the
start line and for every check: a pattern quoted in a doc comment, in a log
message or in a selector string does not count, and a brace inside them does
not end a type. Swift block comments nest; Swift strings may be multi-line or
raw (`#"..."#`), and the code inside a `\\(...)` interpolation is still code.
Objective-C comments, strings and character literals are blanked as well; code
under `#if 0` counts. Physical lines are counted: a pattern used twice on one
line counts once, and the size of a type or file includes its blank and
comment lines.

The registry (one entry per line, keys sorted):
- files: per file, the number of lines with each pattern;
- hub_classes: the size of each hub class;
- large_files: the size of each file above 2,000 lines;
- exceptions: "<path> <pattern>" -> {"count": n, "reason": "..."} for a pattern
  that must stay (a binding's KVC, a default a nib reads, a plugin entry point),
  with its technical reason of at least four words.

The allowed number of a pattern in a file is its `files` entry plus its
exception. A measurement above it fails, and so does a new file that brings a
locked pattern without an exception; `files` takes no new path, which the ratchet
test checks against the registry of the previous revision (previous_revision,
new_paths). A measurement below it fails too, until the registry is lowered in
the same change: `--lower` rewrites the registry with every number that fell
(never one that rose), removes what reached zero, the files that are gone and
the files no longer above 2,000 lines. A renamed file moves its entry by hand.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = 'tests/swift-idiom-registry.json'
APP = 'Horos/Sources/'
MODULES = 'Modules/'
HUB_CLASSES = ('AppController', 'BrowserController', 'DCMView', 'DicomDatabase', 'ViewerController')
LARGE = 2000
VERY_LARGE = 4000

# `Thread {` builds a thread only where an expression can stand: after a colon,
# an arrow, a cast, `==` or one of these words the name is a type, as in
# `class Worker: Thread {` or `func make() -> Thread {`.
TYPE_KEYWORDS = 'extension|class|struct|enum|actor|protocol|as|is'
AXIS_A = {
    'nonisolated_unsafe': re.compile(r'\bnonisolated\s*\(\s*unsafe\s*\)'),
    'thread_perform': re.compile(r'\bThread\s*\(\s*target\s*:|\bperform\s*\(\s*#selector\b'),
    'background_start': re.compile(r'\bperformSelector\s*\(\s*inBackground\s*:'
                                   r'|\bThread\s*\.\s*detachNewThread(?:Selector)?\b'
                                   r'|\bThread\s*\.\s*performBlock\s*\(\s*inBackground\s*:'
                                   r'|\bDispatchQueue\s*\.\s*global\b|\bOperationQueue\s*\(\s*\)'
                                   r'|\bThread\s*\(\s*block\s*:'
                                   r'|(?:^|[^\s\w:>?!=&]|(?<![=!<>])=|\b(?!(?:' + TYPE_KEYWORDS + r')\b)\w+)'
                                   r'\s*\bThread\s*\{'),
    'ns_collection': re.compile(r'\bNS(?:Mutable)?(?:Dictionary|Array)\b'),
    'kvc': re.compile(r'\bvalue\s*\(\s*forKey(?:Path)?\s*:|\bsetValue\s*\('),
    'force_cast': re.compile(r'\bas!'),
    'objc_exception': re.compile(r'\bHorosObjCException\w*'),
}
AXIS_B_SWIFT = {
    'current_browser': re.compile(r'\bBrowserController\s*\.\s*currentBrowser\s*\('),
    'app_controller_shared': re.compile(r'\bAppController\s*\.\s*shared(?:AppController)?\b'),
    'user_defaults': re.compile(r'\bUserDefaults\s*\.\s*standard\b'),
    'notification_post': re.compile(r'\.post\s*\(\s*name\s*:|\bNotificationCenter\s*\.\s*default\s*\.\s*post\s*\('
                                    r'|\.postNotificationOnMainThread\w*\s*\(|#selector\s*\(\s*NotificationCenter\s*\.\s*post\s*\('),
    'direct_ingest': re.compile(r'\baddFiles\s*\(\s*atPaths\s*:|\baddFilesDescribed\s*\('
                                r'|\bimportFiles\s*\(\s*fromIncomingDir\b|\bimportFilesFromIncomingDir(?:Thread)?\b'
                                r'|\binitiateImportFilesFromIncomingDirUnlessAlreadyImporting\b|\bincomingDirPathC?\b'),
}
AXIS_B_OBJC = {
    'current_browser': re.compile(r'\[\s*BrowserController\s+currentBrowser\s*\]'),
    'app_controller_shared': re.compile(r'\[\s*AppController\s+sharedAppController\s*\]'),
    'user_defaults': re.compile(r'\[\s*NSUserDefaults\s+standardUserDefaults\s*\]'),
    'notification_post': re.compile(r'\bpostNotification(?:Name|OnMainThread\w*)?\s*:'),
    'direct_ingest': re.compile(r'\baddFilesAtPaths\s*:|\baddFilesDescribedInDictionaries\s*:'
                                r'|\bimportFilesFromIncomingDir(?:Thread)?\b'
                                r'|\binitiateImportFilesFromIncomingDirUnlessAlreadyImporting\b|\bincomingDirPathC?\b'),
}
# Counted on the Swift code with its strings kept (see the docstring).
PREFERENCE_LITERAL = re.compile(
    r'\.\s*(?:bool|integer|float|double|stringArray)\s*\(\s*forKey\s*:\s*"'
    r'|\b(?:UserDefaults\s*\.\s*standard|defaults|userDefaults|preferences|store)\s*[?!]?\s*\.\s*'
    r'(?:string|array|dictionary|data|url|object|set|removeObject)\s*\(.*?\bforKey\s*:\s*"'
    r'|"values\.[^"\s]')
PATTERNS = tuple(AXIS_A) + tuple(AXIS_B_SWIFT) + ('preference_literal',)
INFORMATIONAL = {
    'objc': re.compile(r'@objc(?:Members)?\b'),
    'struct_enum': re.compile(r'\b(?:struct|enum)\s+\w'),
    'async_await': re.compile(r'\b(?:async|await)\b'),
}


def blank(text):
    """`text` with every character but the newlines turned into a space."""
    return re.sub(r'[^\n]', ' ', text)


SWIFT_CODE = re.compile(r'//|/\*|(#*)("""|")')
SWIFT_INTERPOLATION = re.compile(r'//|/\*|(#*)("""|")|[()]')
SWIFT_BLOCK = re.compile(r'/\*|\*/')


def swift_code(text, keep_strings=False):
    """The Swift `text` with its comments and the contents of its string literals blanked;
    with `keep_strings`, its comments only."""
    out = []
    literal = (lambda part: part) if keep_strings else blank

    def comment_end(start):
        depth, at = 0, start
        while True:
            found = SWIFT_BLOCK.search(text, at)
            if not found:
                return len(text)
            depth += 1 if found.group() == '/*' else -1
            at = found.end()
            if depth == 0:
                return at

    def code(at, interpolation):
        depth = 0
        token = SWIFT_INTERPOLATION if interpolation else SWIFT_CODE
        while True:
            found = token.search(text, at)
            if not found:
                out.append(text[at:])
                return len(text)
            out.append(text[at:found.start()])
            word = found.group()
            if word == '//':
                end = text.find('\n', found.start())
                end = len(text) if end < 0 else end
                out.append(blank(text[found.start():end]))
                at = end
            elif word == '/*':
                end = comment_end(found.start())
                out.append(blank(text[found.start():end]))
                at = end
            elif word == '(':
                depth += 1
                out.append(word)
                at = found.end()
            elif word == ')':
                out.append(word)
                at = found.end()
                if depth == 0:
                    return at
                depth -= 1
            else:
                out.append(word)
                at = string(found.end(), found.group(1), found.group(2))

    def string(at, hashes, quote):
        close, escape = quote + hashes, '\\' + hashes
        while True:
            limit = text.find('\n', at) if quote == '"' else -1
            limit = len(text) if limit < 0 else limit
            end = text.find(close, at, limit)
            limit = limit if end < 0 else end
            slash = text.find(escape, at, limit)
            if slash >= 0:
                where, kind = slash, 'escape'
            elif end >= 0:
                where, kind = end, 'close'
            elif limit < len(text):
                where, kind = limit, 'newline'
            else:
                out.append(literal(text[at:]))
                return len(text)
            out.append(literal(text[at:where]))
            if kind == 'close':
                out.append(close)
                return where + len(close)
            if kind == 'newline':
                return where
            after = where + len(escape)
            if text.startswith('(', after):
                out.append(' ' * len(escape) + '(')
                at = code(after + 1, True)
            else:
                out.append(literal(text[where:after + 1]))
                at = after + 1

    code(0, False)
    return ''.join(out)


OBJC_SKIPPED = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'', re.S)


def objc_code(text):
    """The Objective-C `text` with its comments, strings and character literals blanked."""
    def replace(found):
        word = found.group()
        if word[0] in '"\'':
            return word[0] + blank(word[1:-1]) + word[-1]
        return blank(word)
    return OBJC_SKIPPED.sub(replace, text)


SWIFT_TOP = re.compile(r'[{}]|\bimport[ \t]+(?:(?:class|struct|enum|protocol|func|var|let|typealias)[ \t]+)?[\w.]+'
                       r'|\b(class|extension)\s+((?:\w+\s*\.\s*)*\w+)'
                       r'|\btypealias\s+(\w+)\s*=\s*(?:Horos\s*\.\s*)?(\w+)[ \t]*$'
                       r'|\b(?:struct|enum|protocol|actor|func|var|let|typealias|init|subscript|macro)\b', re.M)
OBJC_IMPLEMENTATION = re.compile(r'^\s*@implementation\s+(\w+)', re.M)
OBJC_END = re.compile(r'^\s*@end\b', re.M)


def swift_types(code):
    """([(name, lines)] of the top-level classes and extensions, {alias: name}) of Swift `code`.

    A class or extension at file scope opens its body at the next brace; any
    other declaration in between (an `import class`, a global function) means
    that brace is not its body.
    """
    types, aliases, depth, pending, start = [], {}, 0, None, None
    for found in SWIFT_TOP.finditer(code):
        word = found.group()
        if word == '{':
            if depth == 0 and pending:
                start, pending = pending, None
            depth += 1
        elif word == '}':
            depth = max(0, depth - 1)
            if depth == 0 and start:
                name, first = start
                types.append((name, code.count('\n', 0, found.start()) - first + 1))
                start = None
        elif depth:
            continue
        elif found.group(3):
            aliases[found.group(3)] = found.group(4)
            pending = None
        elif found.group(1):
            name = re.sub(r'\s+', '', found.group(2))
            name = name[len('Horos.'):] if name.startswith('Horos.') else name
            pending = (name, code.count('\n', 0, found.start()))
        else:
            pending = None
    return types, aliases


def objc_types(code):
    """[(name, lines)] of the @implementation blocks of Objective-C `code`."""
    types = []
    for found in OBJC_IMPLEMENTATION.finditer(code):
        end = OBJC_END.search(code, found.end())
        last = code.count('\n', 0, end.start() if end else len(code))
        types.append((found.group(1), last - code.count('\n', 0, found.start()) + 1))
    return types


def measure_file(path, text):
    """What one file contributes: its pattern counts, informational counts, types and size."""
    swift = path.endswith('.swift')
    code = swift_code(text) if swift else objc_code(text)
    lines = code.split('\n')
    patterns = {}
    if swift:
        selected = dict(AXIS_A)
        if path.startswith(APP):
            selected.update(AXIS_B_SWIFT)
    else:
        selected = AXIS_B_OBJC
    for name, pattern in selected.items():
        count = sum(1 for line in lines if pattern.search(line))
        if count:
            patterns[name] = count
    if swift:
        literal = swift_code(text, keep_strings=True).split('\n')
        count = sum(1 for line in literal if PREFERENCE_LITERAL.search(line))
        if count:
            patterns['preference_literal'] = count
    informational = {name: sum(1 for line in lines if pattern.search(line))
                     for name, pattern in INFORMATIONAL.items()} if swift else {}
    if swift:
        types, aliases = swift_types(code)
    else:
        types, aliases = objc_types(code), {}
    return {'patterns': patterns, 'informational': informational, 'types': types,
            'aliases': aliases, 'lines': len(text.splitlines())}


def counted(path):
    """Whether `path` (from the repository root) is part of the indicator."""
    if path.startswith(APP):
        return path.endswith(('.swift', '.m', '.mm'))
    return path.startswith(MODULES) and path.endswith('.swift')


def tracked(base):
    """The counted paths git tracks under `base`, or None outside a git checkout."""
    listed = subprocess.run(['git', '-C', str(base), 'ls-files', '-z', '--', APP, MODULES],
                            capture_output=True)
    if listed.returncode != 0:
        return None
    return sorted(path for path in listed.stdout.decode().split('\0')
                  if path and counted(path) and (base / path).is_file())


def measure_tree(base):
    """{path: measure_file(...)} for the counted files of the checkout at `base`."""
    paths = tracked(base)
    if paths is None:
        return None
    return {path: measure_file(path, (base / path).read_bytes().decode('utf-8', 'replace')) for path in paths}


def summarize(files):
    """The numbers of the indicator from the per-file measurements."""
    aliases = {}
    for measured in files.values():
        aliases.update(measured['aliases'])
    hubs = {name: {'lines': 0, 'files': set()} for name in HUB_CLASSES}
    for path, measured in files.items():
        if not path.startswith(APP):
            continue
        for name, lines in measured['types']:
            name = aliases.get(name, name)
            if name in hubs:
                hubs[name]['lines'] += lines
                hubs[name]['files'].add(path)
    return {
        'present': set(files),
        'files': {path: measured['patterns'] for path, measured in files.items() if measured['patterns']},
        'hub_classes': {name: hub['lines'] for name, hub in hubs.items()},
        'hub_files': {name: len(hub['files']) for name, hub in hubs.items()},
        'large_files': {path: measured['lines'] for path, measured in files.items()
                        if path.startswith(APP) and measured['lines'] > LARGE},
    }


def load_registry(base=ROOT):
    return json.loads((base / REGISTRY_PATH).read_text())


def exception_counts(registry):
    """{(path, pattern): count} of the registered exceptions."""
    counts = {}
    for key, entry in registry['exceptions'].items():
        path, _, pattern = key.rpartition(' ')
        counts[(path, pattern)] = entry.get('count', 0) if isinstance(entry, dict) else 0
    return counts


def problems(summary, registry):
    """What breaks the ratchet: every number must equal its registered one."""
    found = []
    registered, exceptions = registry['files'], exception_counts(registry)
    for key, entry in sorted(registry['exceptions'].items()):
        path, _, pattern = key.rpartition(' ')
        if pattern not in PATTERNS or not path:
            found.append(f'exception {key!r}: the key is "<path> <pattern>", the pattern one of {", ".join(PATTERNS)}')
        if not isinstance(entry, dict) or set(entry) != {'count', 'reason'}:
            found.append(f'exception {key!r}: an exception is {{"count": n, "reason": "..."}}')
            continue
        if not isinstance(entry['count'], int) or isinstance(entry['count'], bool) or entry['count'] < 1:
            found.append(f'exception {key!r}: its count must be a positive integer')
        if not isinstance(entry['reason'], str) or len(entry['reason'].split()) < 4:
            found.append(f'exception {key!r}: an exception needs its technical reason')
    measured, present = summary['files'], summary['present']
    for path, counts in sorted(registered.items()):
        for pattern, count in sorted(counts.items()):
            if pattern not in PATTERNS:
                found.append(f'{path}: unknown pattern {pattern!r}')
            elif not isinstance(count, int) or isinstance(count, bool) or count < 1:
                found.append(f'{path}: {pattern} must be a positive integer')
    for path in sorted(set(registered) | {path for path, _ in exceptions}):
        if path not in present:
            found.append(f'{path} is gone: remove it from {REGISTRY_PATH} (--lower does)')
    keys = {(path, pattern) for path, counts in registered.items() for pattern in counts}
    keys |= set(exceptions) | {(path, pattern) for path, counts in measured.items() for pattern in counts}
    for path, pattern in sorted(keys):
        if pattern not in PATTERNS or path not in present:
            continue
        now = measured.get(path, {}).get(pattern, 0)
        listed = registered.get(path, {}).get(pattern, 0)
        excepted = exceptions.get((path, pattern), 0)
        allowed = listed + excepted
        if now > allowed and not allowed:
            found.append(f'{path} brings {now} line(s) of {pattern} without a registered exception: write it '
                         'without the pattern, or register the exception with its technical reason')
        elif now > allowed:
            found.append(f'{path}: {pattern} rose from {allowed} to {now}')
        elif now < allowed:
            found.append(f'{path}: {pattern} fell from {allowed} to {now}: lower {REGISTRY_PATH} '
                         'in the same change (--lower does)')
    for name in HUB_CLASSES:
        now, limit = summary['hub_classes'][name], registry['hub_classes'].get(name)
        if limit is None:
            found.append(f'hub class {name} is not in {REGISTRY_PATH}')
        elif now > limit:
            found.append(f'hub class {name} rose from {limit} to {now} lines: new code goes to a type of its own')
        elif now < limit:
            found.append(f'hub class {name} fell from {limit} to {now} lines: lower {REGISTRY_PATH} (--lower does)')
    for name in sorted(set(registry['hub_classes']) - set(HUB_CLASSES)):
        found.append(f'{name} is not a hub class: remove it from {REGISTRY_PATH}')
    large, limits = summary['large_files'], registry['large_files']
    for path in sorted(set(large) | set(limits)):
        now, limit = large.get(path), limits.get(path)
        if limit is None:
            found.append(f'{path} is a new file above {LARGE} lines ({now}): split it by responsibility')
        elif now is None:
            found.append(f'{path} is no longer above {LARGE} lines: remove it from {REGISTRY_PATH} (--lower does)')
        elif now > limit:
            found.append(f'{path} rose from {limit} to {now} lines')
        elif now < limit:
            found.append(f'{path} fell from {limit} to {now} lines: lower {REGISTRY_PATH} (--lower does)')
    return found


def lowered(summary, registry):
    """The registry with every number that fell lowered, and nothing raised."""
    measured, exceptions = summary['files'], dict(registry['exceptions'])
    files = {}
    for path, counts in registry['files'].items():
        kept = {}
        for pattern, count in counts.items():
            now = measured.get(path, {}).get(pattern, 0)
            excepted = exceptions.get(f'{path} {pattern}', {}).get('count', 0)
            kept[pattern] = min(count, max(0, now - excepted))
            if kept[pattern] == 0:
                del kept[pattern]
        if kept:
            files[path] = kept
    for key, entry in list(exceptions.items()):
        path, _, pattern = key.rpartition(' ')
        now = measured.get(path, {}).get(pattern, 0)
        if now < entry.get('count', 0):
            if now:
                exceptions[key] = dict(entry, count=now)
            else:
                del exceptions[key]
    hubs = {name: min(limit, summary['hub_classes'].get(name, limit)) for name, limit in registry['hub_classes'].items()}
    large = {path: min(limit, summary['large_files'][path])
             for path, limit in registry['large_files'].items() if path in summary['large_files']}
    return {'exceptions': exceptions, 'files': files, 'hub_classes': hubs, 'large_files': large}


def registry_text(registry):
    """The registry as JSON with one entry per line and the keys sorted."""
    sections = []
    for section in sorted(registry):
        entries = [f'  {json.dumps(key, ensure_ascii=False)}: {json.dumps(value, sort_keys=True, ensure_ascii=False)}'
                   for key, value in sorted(registry[section].items())]
        sections.append(f' {json.dumps(section)}: {{\n' + ',\n'.join(entries) + ('\n' if entries else '') + ' }')
    return '{\n' + ',\n'.join(sections) + '\n}\n'


def git_text(base, *arguments):
    """What git prints at `base`, or None when it fails."""
    done = subprocess.run(['git', '-C', str(base), *arguments], capture_output=True)
    return done.stdout.decode('utf-8', 'replace') if done.returncode == 0 else None


def renames(base, *revisions):
    """{new path: old path} of the counted files git finds renamed across `revisions`.

    At 30% similarity rather than git's 50%: a file moved with `git mv` and then
    rewritten in the same commit, as a type taken out of the hub is, keeps less
    than half of its lines and would otherwise read as new once committed."""
    listed = git_text(base, 'diff', '--find-renames=30%', '--name-status', '-z', *revisions, '--', APP, MODULES) or ''
    found, fields = {}, iter(listed.split('\0'))
    for status in fields:
        if status.startswith('R'):
            old = next(fields)
            found[next(fields)] = old
        elif status:
            next(fields)
    return found


def previous_revision(base=ROOT):
    """(registry, renames) of the revision the checkout is judged against.

    While the registry differs from HEAD, that revision is HEAD, with what is
    renamed since it, staged or not: what others left in the working tree
    weighs on neither side, and the staged side still names a rename whose file
    was rewritten after `git mv`. A registry as committed, as in a clean clone,
    has nothing to say against HEAD, so HEAD answers to its parent. With no
    such revision (no commit yet, the first one, a shallow clone) the registry
    is None and there is nothing to compare.
    """
    committed = git_text(base, 'show', f'HEAD:{REGISTRY_PATH}')
    if committed is None:
        return None, {}
    if committed != (base / REGISTRY_PATH).read_text():
        return json.loads(committed), {**renames(base, '--cached', 'HEAD'), **renames(base, 'HEAD')}
    parent = git_text(base, 'show', f'HEAD^:{REGISTRY_PATH}')
    if parent is None:
        return None, {}
    return json.loads(parent), renames(base, 'HEAD^', 'HEAD')


def new_paths(registry, previous, renamed):
    """The paths of `files` that `previous` did not have and no rename of one of its paths explains.

    preference_literal was born with a baseline: while `previous` has none, a
    path whose only entry is preference_literal is that baseline, not a new path."""
    born = not any('preference_literal' in counts for counts in previous['files'].values())
    return [f'{path} is new in the files of {REGISTRY_PATH}: a new path takes a registered exception with its '
            'technical reason; only a renamed file moves its entry'
            for path in sorted(set(registry['files']) - set(previous['files']))
            if renamed.get(path) not in previous['files']
            and not (born and set(registry['files'][path]) == {'preference_literal'})]


def report(files, summary):
    """The indicator as text."""
    out = []
    scopes = {'Horos/Sources': [p for p in files if p.startswith(APP) and p.endswith('.swift')],
              'Modules': [p for p in files if p.startswith(MODULES)]}
    swift_lines = {scope: sum(files[p]['lines'] for p in paths) for scope, paths in scopes.items()}
    out.append('Axis A, lines with each pattern in the .swift files:')
    out.append(f'  {"pattern":<20}' + ''.join(f'{f"{scope} ({len(paths)} files, {swift_lines[scope]} lines)":>42}'
                                              for scope, paths in scopes.items()))
    for pattern in AXIS_A:
        out.append(f'  {pattern:<20}' + ''.join(
            f'{sum(files[p]["patterns"].get(pattern, 0) for p in paths):>42}' for paths in scopes.values()))
    app = [p for p in files if p.startswith(APP)]
    out.append(f'Axis B, in the .swift, .m and .mm files of Horos/Sources ({len(app)} files, '
               f'{sum(files[p]["lines"] for p in app)} lines):')
    out.append('  hub class sizes (lines, files):')
    for name in HUB_CLASSES:
        out.append(f'    {name:<20}{summary["hub_classes"][name]:>8}{summary["hub_files"][name]:>6}')
    out.append('  global access and notifications (lines, files):')
    for pattern in AXIS_B_SWIFT:
        counts = [files[p]['patterns'].get(pattern, 0) for p in app]
        out.append(f'    {pattern:<22}{sum(counts):>6}{sum(1 for c in counts if c):>6}')
    out.append(f'  files above {LARGE} lines: {len(summary["large_files"])}, above {VERY_LARGE}: '
               f'{sum(1 for lines in summary["large_files"].values() if lines > VERY_LARGE)}')
    out.append('Informational, not locked (lines in the .swift files):')
    for name in INFORMATIONAL:
        out.append(f'  {name:<20}' + ''.join(
            f'{sum(files[p]["informational"].get(name, 0) for p in paths):>42}' for paths in scopes.values()))
    total = sum(swift_lines.values())
    share = 100 * swift_lines['Modules'] / total if total else 0
    out.append(f'  Swift lines in Modules: {swift_lines["Modules"]} of {total} ({share:.1f}%)')
    return '\n'.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--lower', action='store_true', help='lower the registry to every number that fell')
    parser.add_argument('--baseline', action='store_true', help='write the registry when it does not exist yet')
    parser.add_argument('--root', type=Path, default=ROOT, help='the checkout to measure')
    arguments = parser.parse_args()
    files = measure_tree(arguments.root)
    if files is None:
        sys.exit(f'{arguments.root} is not a git checkout')
    summary = summarize(files)
    print(report(files, summary))
    path = arguments.root / REGISTRY_PATH
    if arguments.baseline:
        if path.exists():
            sys.exit(f'{REGISTRY_PATH} exists: a baseline is written once; lower it with --lower')
        path.write_text(registry_text({'exceptions': {}, 'files': summary['files'],
                                       'hub_classes': summary['hub_classes'], 'large_files': summary['large_files']}))
        print(f'wrote {REGISTRY_PATH}')
    elif arguments.lower:
        path.write_text(registry_text(lowered(summary, load_registry(arguments.root))))
        print(f'lowered {REGISTRY_PATH}')


if __name__ == '__main__':
    main()
