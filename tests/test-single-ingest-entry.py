#!/usr/bin/env python3
"""Every DICOM goes into the database through one entry, and nothing else
writes the studies, series and images of a DICOM database.

The sources of the app, of its modules, of Nitrogen and of the legacy plugin
bridge (Horos/Sources, Modules, Nitrogen and IsiXLegacyBridge/Sources, the
.swift, .m and .mm files git tracks) are read with comments and strings blanked,
as tools/swift-idiom-indicator.py reads them, and every place is found that:

- inserts an object (`insert`): `NSEntityDescription.insertNewObject(forEntityName:into:)`,
  the database's `newObject(forEntity:)`, both through `perform(#selector(...))`,
  any wrapper whose name holds `insertNewObject` or that is called `newObject(...)`
  (the web portal's objcInsertNewObject), `init(entity:insertInto:)`, a Core Data class made with
  `(entity:` or `(context:`, and in Objective-C `insertNewObjectForEntityForName:`,
  `newObjectForEntity:` and `initWithEntity:`. The entity is read on the call:
  a literal "Study", "Series" or "Image", or studyEntity(), seriesEntity() or
  imageEntity(), is a DICOM entity; another literal or accessor (an album, a log
  entry, a recent study, a user) is not; a variable is not known, and counts;
- reaches the index (`index`): `addFiles(...)`, `addFilesDescribed(...)`, a
  `DicomFileIndexer(...)`, in Objective-C `addFilesAtPaths:`,
  `addFilesDescribedInDictionaries:` and `addFiles:`, and a selector string that
  starts with one of them;
- reaches the incoming folder (`incoming`): `incomingDirPath`, `incomingDirPathC`,
  the import of the folder (`importFilesFromIncomingDir`,
  `importFiles(fromIncomingDir:`, `initiateImportFilesFromIncomingDirUnlessAlreadyImporting`)
  and a literal "INCOMING.noindex".

Insertions of a DICOM entity (or of an entity not known) are allowed only in the
indexer, DicomFileIndexer; the index and the incoming folder only in the single
entry, DatabaseIngest. Every other place is named in EXCEPTIONS, by file and by
the function it is in (not by line), with how many places of each kind and
why: a real exception, or a false positive (the Study entity of the web
portal's own database, a routing method that happens to be called addFiles).
A place that is not named fails, and so does a name whose places changed in
number or went away.

The tests of the modules are not read: each builds a Core Data model of its
own in memory, which is not a database of the app.

The test proves on itself, in a working copy of those folders in a temporary
directory, that it refuses an insertion, an addFiles and a use of the incoming
folder injected in each of their spellings, and one more insertion in a named
function; and that it accepts an album, a comment and a string.

    python3 tests/test-single-ingest-entry.py [--list]
"""
from pathlib import Path
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

SCOPES = ('Horos/Sources/', 'Modules/', 'Nitrogen/', 'IsiXLegacyBridge/Sources/')
SUFFIXES = ('.swift', '.m', '.mm')

# The two places that may do it.
INDEXER = 'Horos/Sources/DicomFileIndexer.swift'
SINGLE_ENTRY = 'Horos/Sources/DatabaseIngest.swift'
ALLOWED = {
    INDEXER: {'insert'},
    SINGLE_ENTRY: {'index', 'incoming'},
}

# (file, function) -> ({kind: places}, reason). A function of None is the whole file.
EXCEPTIONS = {
    # --- insertions: real exceptions ---------------------------------------------------
    ('Horos/Sources/DatabaseModelUpgrade.swift', 'run.copyStudy.insert'):
        ({'insert': 1}, 'the upgrade of the schema copies each object of the old store, whatever its '
                        'entity, into a store of the new model; it adds nothing that was not there'),
    ('Horos/Sources/CoreDataAlbumStore.swift', 'importStudy'):
        ({'insert': 2}, 'the albums of a plist name their studies by a study and a series of marker, '
                        'which hold only the instance UIDs, not files, when the database lacks them'),
    ('Modules/IsiXDatabase/Sources/SeriesReparse.swift', 'write'):
        ({'insert': 1}, 'splitting a series by its parsed images makes the new series of the same '
                        'study for images already indexed, on the context of the caller'),
    ('Nitrogen/Sources/N2ManagedDatabase+CAPI.m', 'newObjectForEntity'):
        ({'insert': 2}, "the database's own newObjectForEntity:, which the indexer and the wrappers "
                        'call; its callers are read here by the entity they pass'),
    ('Horos/Sources/WebPortalConnection+Data.swift', 'objcInsertNewObject'):
        ({'insert': 2}, "the web portal's wrapper of insertNewObject(forEntityName:into:), whose "
                        'callers are read here by the entity they pass'),
    # --- insertions: false positives, the Study entity of the web portal's database ----
    ('Horos/Sources/PortalStudyLinks.swift', 'link'):
        ({'insert': 1}, "a Study of the web portal's own database: the link of a study to a user, "
                        'added to it or notified, not a DICOM study'),
    ('Horos/Sources/WebPortalConnection.swift', 'addUploadedStudy'):
        ({'insert': 1}, "a Study of the web portal's own database: the study a user uploaded, "
                        'linked to that user, not a DICOM study'),
    ('Horos/Sources/WebPortalConnection+Data.swift', 'studyPage'):
        ({'insert': 1}, "a Study of the web portal's own database: the study shared with another "
                        'user, not a DICOM study'),
    # --- the index ---------------------------------------------------------------------
    (INDEXER, None):
        ({'index': 20}, 'the selectors of the database, one calling the next, that make an indexer, '
                        'and the call of the last one by the indexer itself'),
    ('Horos/Sources/RemoteDicomDatabase.swift', 'addFilesDescribed'):
        ({'index': 2}, 'the override of a shared database, which indexes in its cache through the '
                       'local indexer and then sends the files to its server'),
    ('IsiXLegacyBridge/Sources/IsiXLegacyDicomDatabase.m', None):
        ({'index': 16, 'incoming': 1}, "the database of the legacy plugin shim: its addFilesAtPaths: "
                                        "hands the files to the plugin kit's import, and so to the single "
                                        "entry, and its folders are the kit's"),
    # --- the incoming folder -----------------------------------------------------------
    ('Horos/Sources/DicomDatabase+Instance.swift', None):
        ({'incoming': 2}, 'the accessor of the folder, in the data folder of the database'),
    ('Modules/IsiXStorage/Sources/DocumentsLocation.swift', None):
        ({'incoming': 1}, "the folder's name in the data folder, for the path that the database's accessor and "
                          'the deprecated accessor of the plugin API (-INCOMINGPATH) hand out; nothing is written or read there'),
    ('Horos/Sources/DicomDatabase.swift', None):
        ({'incoming': 7}, 'the folders a database makes when it opens and the C copy of the path that '
                          "the listener's threads read"),
    ('Horos/Sources/IncomingAdmission.swift', 'hasFilesToImport'):
        ({'incoming': 1}, 'whether the folder holds files, which the pass of the single entry asks '
                          'before it scans'),
    ('Horos/Sources/IncomingAdmission.swift', 'importAdmittedFilesFromIncomingDir'):
        ({'incoming': 3}, 'the scan of the folder, which the pass of the single entry runs'),
    ('Horos/Sources/IncomingAdmission.swift', 'unpackWADORSMultipart'):
        ({'incoming': 1}, 'the parts of a multipart file the scan found, written back in the folder '
                          'for the same pass of the single entry'),
    ('Horos/Sources/IncomingAdmission.swift', 'importFiles'):
        ({'incoming': 3}, 'a selector of the IncomingImport category, which plugins and the '
                          'Objective-C call, forwarding to the single entry'),
    ('Horos/Sources/IncomingAdmission.swift', 'importFilesFromIncomingDir'):
        ({'incoming': 2}, 'a selector of the IncomingImport category, which plugins and the '
                          'Objective-C call, forwarding to the single entry'),
    ('Horos/Sources/IncomingAdmission.swift', 'importFilesFromIncomingDirThread'):
        ({'incoming': 1}, 'a selector of the IncomingImport category, which plugins and the '
                          'Objective-C call, forwarding to the single entry'),
    ('Horos/Sources/IncomingAdmission.swift', 'initiateImportFilesFromIncomingDirUnlessAlreadyImporting'):
        ({'incoming': 1}, 'a selector of the IncomingImport category, which plugins and the '
                          'Objective-C call, forwarding to the single entry'),
    ('Horos/Sources/ImportDisposal.swift', 'returnFilesToIncomingDir'):
        ({'incoming': 1}, 'what a cancelled pass of the single entry took and did not index goes '
                          'back to the folder it came from'),
    ('Horos/Sources/BrowserController+Plugins.swift', 'cfixedIncomingDirectory'):
        ({'incoming': 1}, 'a deprecated accessor of the folder that the plugin API keeps'),
    ('Horos/Sources/BrowserController+Plugins.swift', 'cfixedIncomingNoIndexDirectory'):
        ({'incoming': 1}, 'a deprecated accessor of the folder that the plugin API keeps'),
    ('Horos/Sources/RemoteDicomDatabase.swift', 'initiateImportFilesFromIncomingDirUnlessAlreadyImporting'):
        ({'incoming': 1}, 'the override of a shared database, which asks the single entry for a pass '
                          'only when its own folder holds files'),
}

# --- what is found -------------------------------------------------------------------
INSERT_SWIFT = re.compile(r'\b\w*[iI]nsertNewObject\w*\s*\(|\bnewObject\s*\(|\binit\s*\(\s*entity\s*:'
                          r'|\b(?:NSManagedObject|DicomStudy|DicomSeries|DicomImage)\s*\(\s*(?:entity|context)\s*:')
INSERT_OBJC = re.compile(r'\binsertNewObjectForEntityForName\s*:|\bnewObjectForEntity\s*:|\binitWithEntity\s*:')
INDEX_SWIFT = re.compile(r'\baddFiles\s*\(|\baddFilesDescribed\s*\(|\bDicomFileIndexer\s*\(')
INDEX_OBJC = re.compile(r'\baddFilesAtPaths\s*:|\baddFilesDescribedInDictionaries\s*:|\baddFiles\s*:')
INDEX_SELECTOR = re.compile(r'"addFiles(?:AtPaths|DescribedInDictionaries)?:')
INCOMING = re.compile(r'\bincomingDirPathC?\b|\bimportFilesFromIncomingDir(?:Thread)?\b|\bimportFiles\s*\(\s*fromIncomingDir\b'
                      r'|\binitiateImportFilesFromIncomingDirUnlessAlreadyImporting\b')
INCOMING_LITERAL = re.compile(r'"INCOMING\.noindex"')
DICOM_ENTITY = re.compile(r'"(?:Study|Series|Image)"|\b(?:study|series|image)Entity\s*\(')
OTHER_ENTITY = re.compile(r'"\w+"|\b\w+Entity\s*\(|\b(?!forEntityName\b)\w+EntityName\b')

# Functions, initializers and computed properties: a stored or local `let` or
# `var` is not a place of its own.
SWIFT_DECLARATION = re.compile(r'\bfunc\s+(\w+)|\b(init|deinit|subscript)\b|\bvar\s+(\w+)\s*:[^=\n{]*\{')
OBJC_DECLARATION = re.compile(r'^[ \t]*[-+][ \t]*\([^)]*\)[ \t]*(\w+)|^[ \t]*(?:static[ \t]+)?[\w \t\*]*?\b(\w+)[ \t]*\([^;{}]*\)[ \t]*$',
                              re.M)


def braces(code, start):
    """The index after the brace that closes the one at `start`."""
    depth = 0
    for at in range(start, len(code)):
        if code[at] == '{':
            depth += 1
        elif code[at] == '}':
            depth -= 1
            if depth == 0:
                return at + 1
    return len(code)


def bodies(code, swift):
    """(start, end, name) of every function body, so that a place is named by the innermost."""
    found = []
    matches = list((SWIFT_DECLARATION if swift else OBJC_DECLARATION).finditer(code))
    for index, match in enumerate(matches):
        name = next(group for group in match.groups() if group)
        brace = match.end() - 1 if code[match.end() - 1] == '{' else code.find('{', match.end())
        if brace < 0:
            continue
        following = matches[index + 1].start() if index + 1 < len(matches) else len(code)
        # A declaration without a body of its own (a stored property, a prototype).
        if following < brace and swift:
            continue
        if not swift and code[match.end():brace].strip(' \t\n') not in ('', ) and ';' in code[match.end():brace]:
            continue
        # From the declaration, so that a place in the signature is the function's.
        found.append((match.start(), braces(code, brace), name))
    return found


def statement(code, start):
    """From `start` to the end of the line where the call that starts there has closed."""
    depth, at = 0, start
    while at < len(code):
        if code[at] in '([':
            depth += 1
        elif code[at] in ')]':
            depth -= 1
        elif code[at] == '\n' and depth <= 0:
            break
        at += 1
    return start, at


def places(path, text):
    """[(kind, function, entity, line)] of one file."""
    swift = path.endswith('.swift')
    code = indicator.swift_code(text) if swift else indicator.objc_code(text)
    assert len(code) == len(text), path
    functions = bodies(code, swift)

    def function(at):
        inside = [(start, name) for start, end, name in functions if start <= at < end]
        # Outer to inner, as in run.copyStudy.insert for a helper nested in a function.
        return '.'.join(name for _, name in sorted(inside)) if inside else None

    def line(at):
        return code.count('\n', 0, at) + 1

    found = []
    for match in (INSERT_SWIFT if swift else INSERT_OBJC).finditer(code):
        start, end = statement(code, match.start())
        call = text[start:end]
        entity = 'dicom' if DICOM_ENTITY.search(call) else 'other' if OTHER_ENTITY.search(call) else 'unknown'
        if entity != 'other':
            found.append(('insert', function(match.start()), entity, line(match.start())))
    for match in (INDEX_SWIFT if swift else INDEX_OBJC).finditer(code):
        found.append(('index', function(match.start()), None, line(match.start())))
    # Literals are read in the text, where the code keeps their quote: not in a
    # comment. A selector string, not a log line that quotes the selector after "-[".
    for kind, pattern in (('index', INDEX_SELECTOR), ('incoming', INCOMING_LITERAL)):
        for match in pattern.finditer(text):
            if code[match.start()] == '"':
                found.append((kind, function(match.start()), None, line(match.start())))
    for match in INCOMING.finditer(code):
        found.append(('incoming', function(match.start()), None, line(match.start())))
    # One place per line and kind, as the indicator counts.
    unique = {}
    for kind, name, entity, number in found:
        unique.setdefault((kind, number), (kind, name, entity, number))
    return sorted(unique.values(), key=lambda place: place[3])


def tracked(root):
    listed = subprocess.run(['git', '-C', str(root), 'ls-files', '--', *SCOPES], capture_output=True, text=True)
    if listed.returncode != 0:
        return None
    return [path for path in listed.stdout.splitlines()
            if path.endswith(SUFFIXES) and '/Tests/' not in path and (root / path).is_file()]


def judge(root, paths):
    """The problems of the tree at `root`: places not named, and names whose places changed."""
    problems, seen = [], {}
    for path in paths:
        for kind, name, entity, number in places(path, (root / path).read_text(encoding='utf-8', errors='replace')):
            if kind in ALLOWED.get(path, ()):
                continue
            key = (path, name) if (path, name) in EXCEPTIONS else (path, None)
            if key not in EXCEPTIONS or kind not in EXCEPTIONS[key][0]:
                what = {'insert': f'inserts a {"DICOM" if entity == "dicom" else "not known"} entity outside DicomFileIndexer',
                        'index': 'reaches the index outside DatabaseIngest',
                        'incoming': 'reaches the incoming folder outside DatabaseIngest'}[kind]
                problems.append(f'{path}:{number} ({name or "file scope"}) {what}')
                continue
            seen.setdefault(key, {}).setdefault(kind, []).append(number)
    for key, (counts, reason) in sorted(EXCEPTIONS.items(), key=lambda item: (item[0][0], item[0][1] or '')):
        for kind, expected in counts.items():
            lines = seen.get(key, {}).get(kind, [])
            if len(lines) != expected:
                where = f'{key[0]} {key[1] or "(file)"}'
                problems.append(f'{where}: {len(lines)} {kind} place(s) where {expected} are named '
                                f'(lines {", ".join(map(str, lines)) or "none"}): name each with its reason')
    return problems


def main():
    paths = tracked(ROOT)
    if paths is None:
        print(f'skipped: {ROOT} is not a git checkout', file=sys.stderr)
        sys.exit(2)
    for key, (counts, reason) in EXCEPTIONS.items():
        assert len(reason.split()) >= 4, key

    if '--list' in sys.argv:
        for path in paths:
            for place in places(path, (ROOT / path).read_text(encoding='utf-8', errors='replace')):
                print(path, *place)
        return

    failures = judge(ROOT, paths)
    for failure in failures:
        print('FAIL:', failure)

    def fail(message):
        print('FAIL:', message)
        failures.append(message)

    # --- the test on itself, in a working copy ---------------------------------------
    INJECTED = 'Horos/Sources/SingleIngestProbe.swift'
    SWIFT_PROBES = {
        'insertNewObject(forEntityName:)': 'let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)',
        'newObject(forEntity:)': 'let s = database.newObject(forEntity: database.seriesEntity())',
        'perform(#selector(insertNewObject))':
            'let s = NSEntityDescription.perform(#selector(NSEntityDescription.insertNewObject(forEntityName:into:)), with: "Image", with: context)',
        'perform(#selector(newObject))': 'let s = database.perform(#selector(N2ManagedDatabase.newObject(forEntity:)), with: entity)',
        'a private wrapper': 'let s = self.newObject(self.studyEntity())',
        'init(entity:insertInto:)': 'let s = DicomImage(entity: entity, insertInto: context)',
        'addFiles(atPaths:)': 'let s = database.addFiles(atPaths: paths, postNotifications: true)',
        'addFilesDescribed(inDictionaries:)': 'let s = database.addFilesDescribed(inDictionaries: entries, postNotifications: true, rereadExistingItems: false, generatedByOsiriX: false)',
        'an indexer': 'let s = DicomFileIndexer(database: database, processGraph: .process)',
        'a selector string': 'let s = NSSelectorFromString("addFilesAtPaths:postNotifications:")',
        'incomingDirPath': 'let s = (database.incomingDirPath() as NSString).appendingPathComponent(name)',
        'importFilesFromIncomingDir': 'let s = database.importFilesFromIncomingDir()',
        'a literal INCOMING.noindex': 'let s = base + "/" + "INCOMING.noindex"',
    }
    OBJC_PROBES = {
        'insertNewObjectForEntityForName:': '[NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: context];',
        'newObjectForEntity:': '[database newObjectForEntity: database.studyEntity];',
        'addFilesAtPaths:': '[database addFilesAtPaths: paths];',
        'incomingDirPath': '[database.incomingDirPath stringByAppendingPathComponent: name];',
    }
    ACCEPTED = {
        'an album': 'let s = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)',
        'a comment': '// NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) and addFiles(atPaths:)',
        'a string': 'let s = "database.addFiles(atPaths: paths) into incomingDirPath()"',
    }
    probes = 0
    with tempfile.TemporaryDirectory(prefix='horos-single-ingest-') as directory:
        copy = Path(directory)
        for path in paths:
            (copy / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, copy / path)
        if judge(copy, paths) != failures:
            fail('the working copy is not judged as the checkout')

        def judged(name, source, objc=False):
            target = INJECTED.replace('.swift', '.m') if objc else INJECTED
            (copy / target).write_text(f'func probe() {{\n    {source}\n}}\n' if not objc
                                       else f'void probe(void)\n{{\n    {source}\n}}\n')
            try:
                return judge(copy, paths + [target])
            finally:
                (copy / target).unlink()

        for name, source in SWIFT_PROBES.items():
            probes += 1
            if not any(INJECTED in problem for problem in judged(name, source)):
                fail(f'an injected {name} is not refused')
        for name, source in OBJC_PROBES.items():
            probes += 1
            if not any(INJECTED.replace('.swift', '.m') in problem for problem in judged(name, source, objc=True)):
                fail(f'an injected Objective-C {name} is not refused')
        for name, source in ACCEPTED.items():
            probes += 1
            if any(INJECTED in problem for problem in judged(name, source)):
                fail(f'{name} is refused')

        # One more insertion inside a named function, and a named place that went away.
        albums = copy / 'Horos/Sources/CoreDataAlbumStore.swift'
        original = albums.read_text(encoding='utf-8')
        marker = 'guard let marker = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context) as? DicomStudy else { return }'
        if marker not in original:
            fail('CoreDataAlbumStore.swift no longer makes its marker study with ' + repr(marker))
        else:
            probes += 1
            albums.write_text(original.replace(marker, marker + '\n_ = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)', 1))
            if not any('importStudy' in problem for problem in judge(copy, paths)):
                fail('one more insertion in a named function is not refused')
            probes += 1
            albums.write_text(original.replace(marker, 'let marker = DicomStudy()', 1))
            if not any('importStudy' in problem for problem in judge(copy, paths)):
                fail('a named place that went away is not refused')
            albums.write_text(original)
        # An addFiles injected into an existing file outside the single entry.
        probes += 1
        queue = copy / 'Horos/Sources/BrowserController+DeleteQueue.swift'
        queue.write_text(queue.read_text(encoding='utf-8') +
                         '\nextension BrowserController {\n    func probe() { _ = database.addFiles(atPaths: []) }\n}\n')
        if not any('BrowserController+DeleteQueue.swift' in problem for problem in judge(copy, paths)):
            fail('an addFiles injected into an existing file is not refused')

    if failures:
        sys.exit(1)
    print(f'PASS: Study, Series and Image are inserted only in DicomFileIndexer, the index and the incoming folder are '
          f'reached only in DatabaseIngest, with {len(EXCEPTIONS)} named exceptions and their reasons; '
          f'{probes} injections in a working copy are judged as they should be')


if __name__ == '__main__':
    main()
