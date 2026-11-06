#!/usr/bin/env python3
"""The two axes of modern Swift and organized code only fall.

tools/swift-idiom-indicator.py measures, over the files git tracks:
- axis A, Swift idiom: the lines of each .swift file of Horos/Sources and
  Modules with `nonisolated(unsafe)`, `Thread(target:` or `perform(#selector`
  (which also counts the emulations of a message to nil and the `afterDelay`
  calls), a background start (`performSelector(inBackground:`,
  `Thread.detachNewThread`, `Thread.detachNewThreadSelector`,
  `Thread.performBlock(inBackground:`, `Thread {`, `Thread(block:`,
  `DispatchQueue.global`, `OperationQueue()`), an NS collection, `value(forKey:`, `value(forKeyPath:` or `setValue(`, `as!` and
  HorosObjCException;
- axis B, organization, in the .swift, .m and .mm files of Horos/Sources: the
  lines of each file that reach BrowserController.currentBrowser(),
  AppController.shared or UserDefaults.standard, that post a notification, or
  that reach the index or the incoming folder without the single entry;
  the size of the hub classes ViewerController, BrowserController, DCMView,
  DicomDatabase and AppController, summed by type over the class, its Swift
  extensions and its Objective-C categories wherever they are; and the size of
  each file above 2,000 lines;
- in every .swift file of Horos/Sources and Modules, the lines that read or
  write a preference by a literal key (preference_literal): an accessor with
  `forKey: "..."` and a `"values...."` key path, counted with the strings kept.
Comments and string literals do not count, except the literal keys of
preference_literal. The tool's docstring has the method.

tests/swift-idiom-registry.json keeps every number, one entry per line with
the keys sorted. The checkout must match it exactly:
- a number above its entry fails: a file or hub class that grows, a new file
  that brings a locked pattern without an exception, a new file above 2,000
  lines, a new extension or category of a hub class in any file;
- a number below its entry fails too, so that whoever lowers a count lowers
  the registry in the same change (`python3 tools/swift-idiom-indicator.py
  --lower` does it, and never raises one), as tests/cxx-boundary-registry.json
  refuses an entry that is no longer needed;
- a pattern that has to stay (a binding's KVC, a default a nib reads, a plugin
  entry point) is an exception, "<path> <pattern>": {"count": n, "reason": ...},
  with a technical reason of at least four words;
- `files` takes no new path: the registry is compared with the one of the
  previous revision, HEAD while it differs from HEAD and otherwise the parent
  of HEAD, so that a clean clone answers for its last commit too. A path it did
  not have must be a file git finds renamed from one of its paths. Files
  others left changed in the working tree weigh on neither side.

Checked on the checkout as it is, and on mutations of its measurement that
must be refused: a rise in a registered file, a new file in Horos/Sources and
in Modules with a locked pattern, each form of a background start and of a
direct ingest, a hub class spread into a new Swift
extension file, into a new Objective-C category and through a typealias, a new
file above 2,000 lines, a count that fell without the registry, a file that is
gone, an exception without its reason, and a new path in `files`, the last
also on a throwaway git repository. Patterns quoted only in comments and
strings, an exception with its reason, a renamed file that moves its entry and
a registry lowered by --lower must be accepted.
"""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

files = indicator.measure_tree(root)
if files is None:
    sys.stderr.write(f'{root} is not a git checkout: the indicator counts the files git tracks\n')
    sys.exit(2)
registry_text = (root / indicator.REGISTRY_PATH).read_text()
registry = json.loads(registry_text)
failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


def check(changed=None, removed=(), with_registry=None):
    """The problems of the measured checkout with `changed` texts and `removed` paths."""
    mutated = dict(files)
    for path, text in (changed or {}).items():
        mutated[path] = indicator.measure_file(path, text)
    for path in removed:
        del mutated[path]
    return indicator.problems(indicator.summarize(mutated), with_registry or registry)


summary = indicator.summarize(files)
baseline = indicator.problems(summary, registry)
for problem in baseline:
    fail(problem)
if registry_text != indicator.registry_text(registry):
    fail(f'{indicator.REGISTRY_PATH} is not one entry per line with sorted keys, as --lower writes it')


def text(path):
    return (root / path).read_text()


def first(pattern, kind='.swift'):
    """The first registered file of Horos/Sources with `pattern`."""
    return next(path for path, counts in sorted(registry['files'].items())
                if path.startswith(indicator.APP) and path.endswith(kind) and pattern in counts)


def refused(name, expected, found):
    if not any(expected in problem for problem in found):
        fail(f'the ratchet accepts {name} (expected a problem with {expected!r}, got {found[:3]})')


def accepted(name, found):
    extra = [problem for problem in found if problem not in baseline]
    if extra:
        fail(f'the ratchet refuses {name}: {extra[:3]}')


risen = first('force_cast')
refused('a rise in a registered file', f'{risen}: force_cast rose',
        check({risen: text(risen) + '\nlet idiomRatchetProbe = 0 as! Int\n'}))

probe = 'Horos/Sources/IdiomRatchetProbe.swift'
refused('a new app file with a locked pattern', f'{probe} brings 1 line(s) of nonisolated_unsafe',
        check({probe: 'nonisolated(unsafe) var idiomRatchetProbe = 0\n'}))
module_probe = 'Modules/IsiXStorage/Sources/IdiomRatchetProbe.swift'
refused('a new module file with a locked pattern', f'{module_probe} brings 1 line(s) of ns_collection',
        check({module_probe: 'let idiomRatchetProbe = NSMutableDictionary()\n'}))
refused('a new app file that reads a global', f'{probe} brings 1 line(s) of user_defaults',
        check({probe: 'let idiomRatchetProbe = UserDefaults.standard.bool(forKey: "probe")\n'}))

for form in ('self.performSelector(inBackground: #selector(work), with: nil)',
             'performSelector (inBackground: #selector(work), with: nil)',
             'Thread.detachNewThread { work() }',
             'Thread.detachNewThreadSelector(#selector(work), toTarget: self, with: nil)',
             'let thread = Thread.performBlock(inBackground: { work() })',
             'DispatchQueue.global(qos: .utility).async { work() }',
             'let queue = OperationQueue()',
             'let thread = Thread { work() }',
             'Thread { work() }.start()',
             'return Thread { work() }',
             'func make() -> Thread { Thread { work() } }',
             'let thread = Thread(block: work)',
             'let thread = Thread (block: work)'):
    refused(f'a new file that starts work with {form}', f'{probe} brings 1 line(s) of background_start',
            check({probe: form + '\n'}))
accepted('what only looks like a background start', check({probe: '''DispatchQueue.main.async { work() }
OperationQueue.main.addOperation { work() }
let thread = Thread.current
var queue: OperationQueue? = nil
// Thread.detachNewThread { work() }
// let thread = Thread { work() }
let idiomRatchetProbe = "DispatchQueue.global() OperationQueue() Thread(block: work)"
let block = N2BlockThread { work() }
let other = N2BlockThread(block: work)
final class ProbeThread: Thread {
public extension Thread {
func make() -> Thread {
var current: Thread {
if let thread = object as? Thread {
if object is Thread {
extension Array where Element == Thread {
'''}))

for form in ('let added = database.addFiles(atPaths: paths)',
             'let added = database.addFiles (atPaths: paths)',
             'database.addFilesDescribed(inDictionaries: items, postNotifications: true)',
             'database.importFiles(fromIncomingDir: showGUI)',
             'database.importFilesFromIncomingDir()',
             'database.importFilesFromIncomingDirThread()',
             'database.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()',
             'let folder = database.incomingDirPath()',
             'let folder = database.incomingDirPathC()'):
    refused(f'a new file that ingests with {form}', f'{probe} brings 1 line(s) of direct_ingest',
            check({probe: form + '\n'}))
objc_probe = 'Horos/Sources/IdiomRatchetProbe.m'
for form in ('NSArray *added = [database addFilesAtPaths: paths];',
             '[database addFilesDescribedInDictionaries: items postNotifications: YES rereadExistingItems: NO generatedByOsiriX: NO];',
             '[database importFilesFromIncomingDir];',
             '[database initiateImportFilesFromIncomingDirUnlessAlreadyImporting];',
             'NSString *folder = [database incomingDirPath];'):
    refused(f'a new Objective-C file that ingests with {form}', f'{objc_probe} brings 1 line(s) of direct_ingest',
            check({objc_probe: form + '\n'}))
for form in ('let on = UserDefaults.standard.bool(forKey: "probe")',
             'let count = preferences.integer(forKey: "probe")',
             'let ratio = graph.preferences.float(forKey: "probe")',
             'let text = defaults.string(forKey: "probe")',
             'let stored = defaults?.object(forKey: "probe")',
             'preferences.set(NSNumber(value: 1), forKey: "probe")',
             'UserDefaults.standard.removeObject(forKey: "probe")',
             'store.set(nil, forKey: "probe")',
             'let names = userDefaults.stringArray(forKey: "probe")',
             'control.bind(.value, to: controller, withKeyPath: "values.probe", options: nil)'):
    refused(f'a new file that reads a preference by its text with {form}', f'{probe} brings 1 line(s) of preference_literal',
            check({probe: form + '\n'}))
accepted('what only looks like a preference read by its text', check({probe: '''let value = entry.object(forKey: "probe")
let other = dictionary.string(forKey: "probe")
let title = preferences[NetworkPreferences.aeTitle]
let named = preferences.bool(forKey: key)
preferences.set(true, for: NetworkPreferences.storeSCP)
// UserDefaults.standard.bool(forKey: "probe")
let values = "values"
'''}))
born = dict(registry, files=dict(registry['files'], **{probe: {'preference_literal': 2}}))
without = dict(registry, files={path: {pattern: count for pattern, count in counts.items() if pattern != 'preference_literal'}
                                for path, counts in registry['files'].items()})
accepted('the baseline of preference_literal, born in this registry', indicator.new_paths(born, without, {}))
refused('a new path of preference_literal once the baseline exists', f'{probe} is new in the files',
        indicator.new_paths(born, born | {'files': {**without['files'], 'Horos/Sources/AppController.swift': {'preference_literal': 1}}}, {}))

accepted('what only looks like a direct ingest', check({probe: '''let lock = database.importFilesFromIncomingDirLock
processGraph.databaseIngest.requestImport()
// database.importFilesFromIncomingDir()
let idiomRatchetProbe = "addFiles(atPaths: incomingDirPath"
'''}))

refused('a hub class spread into a new Swift extension file', 'hub class ViewerController rose',
        check({'Horos/Sources/ViewerController+IdiomRatchetProbe.swift':
               'extension ViewerController {\n    func idiomRatchetProbe() {}\n}\n'}))
refused('a hub class spread into a new Objective-C category', 'hub class DCMView rose',
        check({'Horos/Sources/DCMView+IdiomRatchetProbe.m':
               '@implementation DCMView (IdiomRatchetProbe)\n- (void)idiomRatchetProbe {}\n@end\n'}))
refused('a hub class spread through a typealias', 'hub class BrowserController rose',
        check({probe: 'typealias IdiomRatchetBrowser = BrowserController\n'
                      'extension IdiomRatchetBrowser {\n    func idiomRatchetProbe() {}\n}\n'}))
refused('a new file above 2,000 lines', f'{probe} is a new file above {indicator.LARGE} lines',
        check({probe: '\n' * (indicator.LARGE + 1)}))

accepted('patterns only in comments and strings', check({probe: '''// nonisolated(unsafe) as! NSDictionary
/* value(forKey: /* nested */ Thread(target: HorosObjCException */
let idiomRatchetProbe = "perform(#selector UserDefaults.standard \\(1) as! }"
let idiomRatchetRaw = #"BrowserController.currentBrowser() "quoted" as!"#
let idiomRatchetLines = """
    AppController.shared NotificationCenter.default.post(name: x)
    """
'''}))
accepted('a hub extension whose strings and comments hold braces', check({
    'Horos/Sources/ViewerController+IdiomRatchetProbe.swift': '// extension ViewerController {\n'
                                                              'let idiomRatchetProbe = "extension DCMView {"\n'}))

fell = first('kvc')
lines = text(fell).split('\n')
code = indicator.swift_code(text(fell)).split('\n')
index = next(number for number, line in enumerate(code) if indicator.AXIS_A['kvc'].search(line))
refused('a count that fell without the registry', f'{fell}: kvc fell',
        check({fell: '\n'.join(lines[:index] + lines[index + 1:])}))

gone = next(path for path in sorted(registry['files']) if path.startswith('Horos/Sources/ViewerController+'))
found = check(removed=[gone])
refused('a file that is gone', f'{gone} is gone', found)
refused('a hub class that fell without the registry', 'hub class ViewerController fell', found)
mutated = dict(files)
del mutated[gone]
lower = indicator.lowered(indicator.summarize(mutated), registry)
accepted('the registry lowered by --lower', check(removed=[gone], with_registry=lower))
if any(lower['hub_classes'][name] > registry['hub_classes'][name] for name in registry['hub_classes']):
    fail('--lower raises a hub class')

kvc_probe = {probe: 'let idiomRatchetProbe = object.value(forKey: "boundKey")\n'}
# The probe's exception joins the registered ones, which the checkout needs.
excepted = dict(registry, exceptions=dict(registry['exceptions'], **{f'{probe} kvc': {
    'count': 1, 'reason': 'the nib binds this key through Cocoa bindings'}}))
accepted('a new file with an exception and its reason', check(kvc_probe, with_registry=excepted))
unexplained = dict(registry, exceptions=dict(registry['exceptions'], **{f'{probe} kvc': {'count': 1, 'reason': 'needed'}}))
refused('an exception without its reason', 'an exception needs its technical reason', check(kvc_probe, with_registry=unexplained))

previous, moved = indicator.previous_revision(root)
if previous is None:
    print(f'SKIP: no previous revision of {indicator.REGISTRY_PATH} here to compare new paths with')
else:
    for problem in indicator.new_paths(registry, previous, moved):
        fail(problem)

kept = first('kvc')
added = dict(registry, files=dict(registry['files'], **{probe: {'kvc': 1}}))
refused('a new path in files', f'{probe} is new in the files', indicator.new_paths(added, registry, {}))
refused('a new path renamed from a path that was not in files', f'{probe} is new in the files',
        indicator.new_paths(added, registry, {probe: 'Horos/Sources/IdiomRatchetUnregistered.swift'}))
accepted('a renamed file that moves its entry', indicator.new_paths(added, registry, {probe: kept}))


def judged(base):
    """The new paths of the registry at `base`, judged as the checkout is."""
    before, renamed = indicator.previous_revision(base)
    if before is None:
        return []
    return indicator.new_paths(json.loads((base / indicator.REGISTRY_PATH).read_text()), before, renamed)


def registered(base, entries):
    (base / indicator.REGISTRY_PATH).write_text(indicator.registry_text(
        {'exceptions': {}, 'files': entries, 'hub_classes': {}, 'large_files': {}}))


with tempfile.TemporaryDirectory() as folder:
    repository = Path(folder)
    identity = ('-c', 'user.name=ratchet', '-c', 'user.email=ratchet@invalid', '-c', 'commit.gpgsign=false',
                '-c', 'core.hooksPath=/dev/null')

    def git(*arguments):
        subprocess.run(['git', '-C', folder, *identity, *arguments], check=True, capture_output=True)

    def committed(message):
        git('add', '--all')
        git('commit', '-m', message)

    old, plain = indicator.APP + 'IdiomOld.swift', indicator.APP + 'IdiomPlain.swift'
    new, other = indicator.APP + 'IdiomNew.swift', indicator.APP + 'IdiomOther.swift'
    body = ''.join(f'let idiomRatchetLine{number} = object{number} as! Int\n' for number in range(40))
    (repository / indicator.APP).mkdir(parents=True)
    (repository / 'tests').mkdir()
    (repository / old).write_text(body)
    (repository / plain).write_text(body.replace('Line', 'Plain'))
    registered(repository, {old: {'force_cast': 40}})
    git('init', '--quiet')
    if judged(repository):
        fail('a repository without a commit has nothing to compare, and the ratchet refused it')
    committed('first')
    if judged(repository):
        fail('the first commit has no parent to compare, and the ratchet refused it')

    (repository / new).write_text('let idiomRatchetProbe = 0 as! Int\n')
    git('add', new)
    registered(repository, {old: {'force_cast': 40}, new: {'force_cast': 1}})
    refused('a new path left in the working tree', f'{new} is new in the files', judged(repository))
    committed('a path that is not a rename')
    refused('a new path that a clean clone receives in its last commit', f'{new} is new in the files',
            judged(repository))

    git('rm', '--quiet', '--force', new)
    registered(repository, {old: {'force_cast': 40}})
    accepted('a registry that loses a path', judged(repository))
    committed('without it')

    git('mv', old, new)
    registered(repository, {new: {'force_cast': 40}})
    accepted('a file renamed in the index', judged(repository))
    (repository / new).write_text('let idiomRatchetProbe = 0 as! Int\n' * 40)
    accepted('a renamed file rewritten after git mv', judged(repository))
    (repository / new).write_text(body)
    git('mv', plain, other)
    registered(repository, {new: {'force_cast': 40}, other: {'force_cast': 40}})
    refused('a rename of a file that had no entry', f'{other} is new in the files', judged(repository))
    registered(repository, {new: {'force_cast': 40}})
    committed('renamed')
    accepted('a rename that a clean clone receives in its last commit', judged(repository))

if failures:
    sys.exit(1)
axis_a = {pattern: sum(counts.get(pattern, 0) for counts in summary['files'].values()) for pattern in indicator.AXIS_A}
axis_b = {pattern: sum(counts.get(pattern, 0) for counts in summary['files'].values()) for pattern in indicator.AXIS_B_SWIFT}
print('PASS: axis A matches the registry: ' + ', '.join(f'{name} {count}' for name, count in axis_a.items()))
print('PASS: axis B matches the registry: ' + ', '.join(f'{name} {count}' for name, count in axis_b.items())
      + '; hub classes ' + ', '.join(f'{name} {lines}' for name, lines in summary['hub_classes'].items())
      + f'; {len(summary["large_files"])} files above {indicator.LARGE} lines')
print('PASS: a rise, a new file with a pattern, each form of a background start and of a direct ingest, a hub class spread into a new extension, category or typealias, '
      'a new large file, a fall or a gone file left in the registry, an exception without reason and a new path in files are refused; '
      'comments, strings, a reasoned exception, a renamed file and a registry lowered by --lower are accepted')
