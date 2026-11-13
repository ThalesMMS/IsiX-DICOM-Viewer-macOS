#!/usr/bin/env python3
"""An archive handed to the importer ends with a statement of what it held.

Measured before the change on the development build, three archives dropped into
the incoming folder of a running Horos:

  - `no-dicom.zip` and `mixed.zip` left the incoming folder and were never
    mentioned again;
  - `corrupt.zip` stayed in the decompression folder for ever - nothing rescans
    that folder, so the file was neither imported nor reported.

The same run exposed why the earlier archive measurements looked like nothing at
all happened: `Decompress`, the helper that expands archives, was signed with the
hardened runtime and no entitlements, so it could not load the ad-hoc frameworks
beside it and died in dyld before running. That is checked here too, because
without it the whole path is untestable. The archives are now expanded by the
application itself, around the Decompress XPC service (IsiXDatabase's
DecompressConversion), as the helper expanded them.

An archive unzip only warned about is taken when every file it lists came out,
so the ledger has to count the files as unzip sees them. unzip turns the \\ of
a name into / when the entry says it was made on a FAT system and the name holds
no /, which makes a directory of `ST_1\\`; anywhere else a name ending in \\ is
a file. The count is compared here with what the unzip of this system writes.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from sources import class_text

root = Path(__file__).resolve().parents[1]
failures = []

ledger_source = root / 'Horos/Sources/ArchiveImportLedger.swift'
# DicomDatabase is Swift (DicomDatabase.swift and its DicomDatabase+*.swift
# extensions); the assertions read its Swift spelling.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources as dicom_database_sources  # noqa: E402
database = dicom_database_sources.class_text('DicomDatabase')
decompress = (root / 'Modules/IsiXDatabase/Sources/DecompressConversion.swift').read_text(encoding='utf-8')
launcher = (root / 'script/build_and_run.sh').read_text()

DRIVER = '''
func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }
let ledger = ArchiveImportLedger.shared

emit("entry", ArchiveImportLedger.archiveComponent(ofRelativePath: "a.zip/x.dcm") ?? "nil")
emit("deep", ArchiveImportLedger.archiveComponent(ofRelativePath: "a.OSIRIXZIP/sub/x.dcm") ?? "nil")
emit("archive-itself", ArchiveImportLedger.archiveComponent(ofRelativePath: "a.zip") ?? "nil")
emit("plain-folder", ArchiveImportLedger.archiveComponent(ofRelativePath: "folder/x.dcm") ?? "nil")

// An archive that expanded to nothing still gets a line.
emit("empty", ledger.verdictForArchive("/in/empty.zip", keptDirectoryName: "NOT READABLE"))

// The case the issue is about: it expanded, and none of it was DICOM.
for _ in 0..<3 { ledger.recordKeptEntry(inArchive: "/in/no-dicom.zip") }
emit("no-dicom", ledger.verdictForArchive("/in/no-dicom.zip", keptDirectoryName: "NOT READABLE"))

// Mixed, with the deleting preference on for one of them.
ledger.recordIndexedEntry(inArchive: "/in/mixed.zip")
ledger.recordIndexedEntry(inArchive: "/in/mixed.zip")
ledger.recordKeptEntry(inArchive: "/in/mixed.zip")
ledger.recordDeletedEntry(inArchive: "/in/mixed.zip")
emit("mixed", ledger.verdictForArchive("/in/mixed.zip", keptDirectoryName: "NOT READABLE"))

// A DICOM sent for transcoding is still a DICOM entry of the archive, and an
// archive within the archive is counted but reported on its own.
ledger.recordQueuedEntry(inArchive: "/in/nested.zip")
ledger.recordNestedArchive(inArchive: "/in/nested.zip")
emit("nested", ledger.verdictForArchive("/in/nested.zip", keptDirectoryName: "NOT READABLE"))

// Reporting consumes the tally: the expansion is gone and nothing can be added.
emit("consumed", ledger.hasArchive("/in/mixed.zip") ? "yes" : "no")

// How many files each archive given lists, for the comparison with what unzip
// writes.
for archive in CommandLine.arguments.dropFirst() {
    let listed = ArchiveImportLedger.fileEntryCount(ofArchive: archive)
    emit("listed " + (archive.split(separator: "/").last ?? ""), listed.map { String($0) } ?? "nil")
}
'''

# The systems an entry can say it was made on, as the ZIP format numbers them.
FAT, UNIX, NTFS = 0, 3, 11
FOLDER, FILE = 0x10, 0x20
UNIX_FOLDER, UNIX_FILE = (0o40755 << 16) | FOLDER, 0o100644 << 16
# Synthetic archives, each entry as (name, system, attributes), and the number of
# files unzip writes from each. Every entry that is not a folder holds bytes,
# so that only the name tells unzip what it is.
LISTED = {
    # The folder an image is in, with \ and no entry of its own.
    'backslash.zip': (2, [('ST_1\\IM1', FAT, FILE), ('ST_1\\IM2', FAT, FILE)]),
    # The same with entries for the folders, one of them with spaces.
    'backslash-folders.zip': (3, [('ST_1\\', FAT, FOLDER), ('ST_1\\IM1', FAT, FILE), ('ST_1\\ SE 1\\', FAT, FOLDER),
                                  ('ST_1\\ SE 1\\IM2', FAT, FILE), ('ST_1\\ SE 1\\IM 3', FAT, FILE)]),
    # A name that holds a / keeps its \: `C/D\` is a file of the folder C.
    'both-separators.zip': (3, [('A/', FAT, FOLDER), ('A/x', FAT, FILE), ('B\\', FAT, FOLDER), ('B\\y', FAT, FILE),
                                ('C/D\\', FAT, FILE)]),
    # Made on other systems, a \ is a character of the name like another.
    'unix-names.zip': (3, [('dir/', UNIX, UNIX_FOLDER), ('dir/file\\', UNIX, UNIX_FILE), ('odd\\', UNIX, UNIX_FILE),
                           ('plain', UNIX, UNIX_FILE)]),
    'ntfs-names.zip': (2, [('ST_1\\', NTFS, FILE), ('ST_1\\IM1', NTFS, FILE)]),
    'folders.zip': (2, [('ST_1/', UNIX, UNIX_FOLDER), ('ST_1/IM1', UNIX, UNIX_FILE), ('ST_1/IM2', FAT, FILE)]),
}


def listed_archives(directory):
    """Writes the archives of LISTED into `directory`; for each, its path and the
    number of files /usr/bin/unzip writes from it."""
    written = {}
    for name, (_, entries) in LISTED.items():
        archive = Path(directory) / name
        with zipfile.ZipFile(archive, 'w') as zipped:
            for entry, system, attributes in entries:
                info = zipfile.ZipInfo(entry)
                info.create_system, info.external_attr = system, attributes
                zipped.writestr(info, b'' if attributes & FOLDER else b'synthetic bytes')
        expansion = Path(directory) / (name + '.expanded')
        expansion.mkdir()
        unzip = subprocess.run(['/usr/bin/unzip', '-qq', '-o', '-d', str(expansion), str(archive)],
                               stdin=subprocess.DEVNULL, capture_output=True)
        if unzip.returncode not in (0, 1):
            failures.append('unzip ended with %d on %s' % (unzip.returncode, name))
        written[name] = (archive, sum(len(files) for _, _, files in os.walk(expansion)))
    return written


# --- what the archive's closing line says -------------------------------------
results = {}
if not ledger_source.exists():
    failures.append('there is no archive ledger, so no archive can be summed up')
else:
    swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
    if swiftc.returncode != 0:
        failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
    else:
        with tempfile.TemporaryDirectory(prefix='horos-archive-') as directory:
            # Top-level statements are only allowed in a file called main.swift.
            (Path(directory) / 'main.swift').write_text(DRIVER)
            binary = Path(directory) / 'ledger'
            built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                    str(ledger_source), str(Path(directory) / 'main.swift')],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                failures.append('the archive ledger does not compile:\n%s' % built.stderr[-1500:])
            else:
                archives = listed_archives(directory)
                run = subprocess.run([str(binary)] + [str(archive) for archive, _ in archives.values()],
                                     capture_output=True, text=True)
                if run.returncode != 0:
                    failures.append('the driver failed: %s' % run.stderr[-800:])
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results[key] = value
                # --- an archive lists as many files as unzip writes from it -----------
                for name, (_, extracted) in archives.items():
                    expected = LISTED[name][0]
                    if extracted != expected:
                        failures.append('unzip wrote %d files from %s, and this test says %d: the rule '
                                        'the ledger counts by is no longer the one of this unzip'
                                        % (extracted, name, expected))
                    got = results.get('listed ' + name)
                    if got != str(expected):
                        failures.append('%s lists %s files to the ledger, and unzip writes %d: the archive '
                                        'would be %s' % (name, got, expected,
                                                         'refused whole' if (got or '').isdigit() and int(got) > expected
                                                         else 'taken with a file missing'))

if results:
    expected = {
        'entry': 'a.zip',
        'deep': 'a.OSIRIXZIP',
        # An archive is not an entry of itself, and an ordinary folder is not one.
        'archive-itself': 'nil',
        'plain-folder': 'nil',
        'empty': 'empty.zip: no entries',
        'no-dicom': 'no-dicom.zip: 3 entries, no DICOM; 3 kept in NOT READABLE',
        'mixed': 'mixed.zip: 4 entries, 2 DICOM; 1 kept in NOT READABLE, 1 deleted',
        'nested': 'nested.zip: 2 entries, 1 DICOM; 1 nested archive expanded separately',
        'consumed': 'no',
    }
    for key, want in expected.items():
        got = results.get(key)
        if got != want:
            failures.append('%s: %r, expected %r' % (key, got, want))

# --- the incoming scan has to feed it and then say it -------------------------
if 'ArchiveImportLedger' not in database:
    failures.append('the incoming scan never records anything about an archive')
else:
    if 'archiveComponent(ofRelativePath:' not in database:
        failures.append('the scan does not work out which archive an entry came from')
    at = database.find('let dirContainsStuff')
    window = database[at:at + 1400] if at >= 0 else ''
    if 'verdictForArchive' not in window:
        failures.append('an expansion that has run out is deleted without the archive being '
                        'summed up: that is the only moment at which anything still knows')
    if 'isArchiveName' not in window:
        failures.append('every emptied folder would be reported as an archive')
    for recorder in ('recordIndexedEntry(inArchive:', 'recordKeptEntry(inArchive:',
                     'recordDeletedEntry(inArchive:', 'recordNestedArchive(inArchive:',
                     'recordQueuedEntry(inArchive:'):
        if recorder not in database:
            failures.append('%s is never called, so that outcome is missing from the count'
                            % recorder)

    # A multipart response is split into separate files and deleted; carrying on
    # would test a path that no longer exists and call it unreadable.
    # The parts are written by -unpackWADORSMultipart:, which says it split
    # the file, and the scan goes on to the next one.
    at = database.find('case .split:')
    window = database[at:at + 900] if at >= 0 else ''
    split = database.find('if unpackWADORSMultipart(srcPath, enclosingArchive: enclosingArchive) {')
    if 'return true' not in window or split < 0 or 'continue' not in database[split:split + 120]:
        failures.append('a split multipart response falls through to the readability test on a '
                        'file that has just been deleted')

# --- an archive is recognised whatever the case of its extension ---------------
# Exporters write STUDY.ZIP as often as study.zip. A case-sensitive test sent the
# former to the DICOM importer as a plain file, which could not read it.
# The browser's drop and import is DroppedFilesImport.swift, its archives ArchiveImport.swift.
browser = (class_text('BrowserController')
           + (root / 'Horos/Sources/DroppedFilesImport.swift').read_text()
           + (root / 'Horos/Sources/ArchiveImport.swift').read_text())
scan = (root / 'Horos/Sources/MediaVolumeScan.swift').read_text(encoding='utf-8')
# The importer's tests are the ones that also accept .osirixzip; the export's own
# lowercase .zip files are not looked for this way.
case_sensitive = re.compile(r'pathExtension\]?\s*isEqualToString:\s*@"osirixzip"')
for name, text in (('BrowserController', browser), ('DicomDatabase', database),
                   ('MediaVolumeScan.swift', scan)):
    live = re.sub(r'//[^\n]*', '', text)
    for match in case_sensitive.finditer(live):
        line = live.count('\n', 0, match.start()) + 1
        failures.append('%s:%d tells an archive by a case-sensitive extension' % (name, line))
    if 'isArchiveName' not in live:
        failures.append('%s no longer recognises archives through the ledger' % name)
helper = re.sub(r'//[^\n]*', '', decompress)
if 'let fileExtension = (file as NSString).pathExtension.lowercased()' not in helper:
    failures.append('DecompressConversion.swift tells an archive by a case-sensitive extension')

# --- an archive that cannot be expanded is handed back, not stranded ----------
if 'surrenderUnreadableArchive' not in decompress:
    failures.append('an archive that cannot be expanded still stays in the decompression folder, '
                    'which nothing ever rescans')
else:
    # One list loop serves compress and decompressList, so one call site.
    if decompress.count('let outcome = extractDICOMArchive(') != 1 or 'if outcome != .extracted' not in decompress:
        failures.append('the archive call site no longer reports what happened')
    if 'case expandedNotCleared' not in decompress:
        failures.append('an archive whose contents are already in place would be handed back and '
                        'imported twice')
    # An archive that could not be expanded because the destination was full or
    # unwritable is not a bad archive. Disposing of it there destroys something
    # the next attempt could read perfectly well.
    if 'case notExpandedForNow' not in decompress:
        failures.append('a destination that is full or unwritable is treated as a bad archive, '
                        'so the archive is disposed of instead of being tried again')
    if 'returnArchiveForRetry' not in decompress:
        failures.append('nothing puts such an archive back for another attempt')
    if 'status == 50' not in decompress:
        failures.append("unzip's disk-full status is not told apart from an archive that is at "
                        'fault')
    if 'status != 0 && status != 1' not in decompress:
        failures.append('unzip exit 1 is a warning with the contents extracted; treating it as a '
                        'failure throws away everything that came out')
    at = decompress.find('static func surrenderUnreadableArchive')
    window = decompress[at:at + 1200]
    if 'horos-unexpanded' not in window:
        failures.append('the archive is handed back under a name that still reads as an archive, '
                        'so it is sent straight back to the decompression folder')
    if 'could not be expanded as an archive' not in database:
        failures.append("the application's own log never says the file it is disposing of was an "
                        'archive it failed to expand')
    if 'unzip exited with' not in decompress:
        failures.append('nothing says why the archive could not be expanded')

# --- and the helper that expands them has to be able to run -------------------
if '--options runtime' in launcher and '--entitlements "$entitlements"' not in launcher:
    failures.append('the development bundle signs the helpers in Resources with the hardened '
                    'runtime and no entitlements: library validation then stops Decompress from '
                    'loading the frameworks beside it, and every archive silently does nothing')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an archive says how many entries it held, how many were DICOM and where the rest '
      'went, and one that cannot be expanded is handed back for the same verdict instead of '
      'being left in a folder nothing reads')
