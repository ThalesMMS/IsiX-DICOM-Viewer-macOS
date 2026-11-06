"""The indexer's gated methods, pasted into a test double of the database.

The tests of the writer gate (test-import-writer-gate.py) and of the SQL
rebuild's direct writers (test-sql-rebuild-direct-writer.py) compile
-addFilesDescribedInDictionaries: and indexDescribedFiles as they are in the
checkout and in an earlier revision, over a stand-in N2ManagedDatabase called
ImportDatabase that indexes one file with a double (`indexFile`) and keeps
the gate (`databaseWriterGate`).

Until the indexer was a type of its own the two methods were members of
DicomDatabase, in DicomDatabase+Import.swift; since, they are members of
DicomFileIndexer, in DicomFileIndexer.swift, which reaches the database as
`database` and the alert as `feedback`, and the database's selector forwards
to it. `pasted(source)` gives the Swift to paste for either shape, and
`source_at(revision)` the indexer's file at a revision, under either name.

The Study Instance UIDs of the studies an import can meet were an array beside
the array of the studies. Since the import reads only the studies its files
name, they are DicomDatabaseImportStudyUIDs, which answers the places of a UID
without walking the list. The double of indexFile asks either one through
`ImportStudyUIDList`, and for a source that has the type `pasted(source)` adds
the type and `studies(describedIn:)`, the read of the studies, as written.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import sources  # noqa: E402

FORMER = 'Horos/Sources/DicomDatabase+Import.swift'
FORMER_ADD = ('func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, '
              'generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {')
FORMER_INDEX = 'private final func indexDescribedFiles('
INDEXER = str(sources.source_path('DicomFileIndexer').relative_to(ROOT))
ADD = ('func addDescribedFiles(_ dicomFilesArray: [Any]?, postNotifications: Bool, rereadExistingItems: Bool, '
       'generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]? {')
INDEX = 'private func indexDescribedFiles('
STUDY_UIDS = 'final class DicomDatabaseImportStudyUIDs'
STUDIES = 'private func studies(describedIn files: NSArray) -> NSMutableArray {'

# The list of Study Instance UIDs as the double of indexFile asks it: where the
# first study of a UID is in the array of the studies, and that the study it
# adds to that array has this UID.
UID_LIST = r'''
protocol ImportStudyUIDList {
    func place(of uid: String) -> Int
    func remember(_ uid: String)
}

extension NSMutableArray: ImportStudyUIDList {
    func place(of uid: String) -> Int { index(of: uid) }
    func remember(_ uid: String) { add(uid) }
}
'''

# The same over the type of the indexer, and the association of the reports of
# the cloud as the indexer calls it since: these doubles have no such report,
# for which alone it reads every study.
UID_TYPE_STANDINS = r'''
extension DicomDatabaseImportStudyUIDs: ImportStudyUIDList {
    func place(of uid: String) -> Int { first(uid) }
    func remember(_ uid: String) { append(uid) }
}

func associateCloudReports(_ files: NSArray, allStudies: () -> NSArray, _ context: NSManagedObjectContext?) {}
'''

# What the indexer reaches besides the database, for the shape of a type of its own.
INDEXER_STANDINS = r'''
struct IndexerFeedbackStandIn {
    func alertRejectedReports(_ count: Int) { ImportDatabase.alertedReports(count) }
}

struct DicomFileIndexer {
    let database: ImportDatabase
    let preferences = UserDefaults.standard
    let feedback = IndexerFeedbackStandIn()

    func publish(_ added: DicomDatabaseImportBatch, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool,
                 returnArray: Bool) {
        database.publish(added, postNotifications: postNotifications, rereadExistingItems: rereadExistingItems,
                         generatedByOsiriX: generatedByOsiriX, returnArray: returnArray)
    }

    func indexFile(_ curDict: NSMutableDictionary?, cursor: DicomDatabaseImportCursor, added: DicomDatabaseImportBatch,
                   studiesArray: NSMutableArray, studiesArrayStudyInstanceUID: any ImportStudyUIDList, modifiedStudiesArray: NSMutableArray,
                   defaultDate: Date, today: Date, dataDirPath: String?, reportsDirPath: String?, errorsDirPath: String?,
                   settings: DicomDatabaseImportSettings, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool,
                   preparedReportPath: inout String?) {
        database.indexFile(curDict, cursor: cursor, added: added, studiesArray: studiesArray,
                           studiesArrayStudyInstanceUID: studiesArrayStudyInstanceUID, modifiedStudiesArray: modifiedStudiesArray,
                           defaultDate: defaultDate, today: today, dataDirPath: dataDirPath, reportsDirPath: reportsDirPath,
                           errorsDirPath: errorsDirPath, settings: settings, rereadExistingItems: rereadExistingItems,
                           generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles, preparedReportPath: &preparedReportPath)
    }

    // The key images of the key object selections, which these doubles do not have.
    func markKeyObjectSelections(of added: DicomDatabaseImportBatch) {}
}

// The selector of the database, which forwards to the indexer.
extension ImportDatabase {
    static func alertedReports(_ count: Int) {}

    func addFilesDescribed(inDictionaries dicomFilesArray: [Any]!, postNotifications: Bool, rereadExistingItems: Bool,
                           generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {
        DicomFileIndexer(database: self).addDescribedFiles(dicomFilesArray, postNotifications: postNotifications,
                                                           rereadExistingItems: rereadExistingItems, generatedByOsiriX: generatedByOsiriX,
                                                           importedFiles: importedFiles, returnArray: returnArray)
    }
}
'''


def method(source, signature):
    """The member that starts with `signature`, through its closing brace."""
    start = source.index(signature)
    depth, index = 0, source.index('{', start)
    while True:
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1


def is_type(source):
    """Whether `source` has the indexer as a type of its own."""
    return 'struct DicomFileIndexer' in source


def has_uid_type(source):
    """Whether `source` keeps the Study Instance UIDs in a type of their own."""
    return STUDY_UIDS in source


def gated(source):
    """(the gated import, the indexing) of either shape."""
    if is_type(source):
        return method(source, ADD), method(source, INDEX)
    return method(source, FORMER_ADD), method(source, FORMER_INDEX)


def pasted(source):
    """The Swift that puts the two methods of `source` on the double."""
    add, index = gated(source)
    if not is_type(source):
        return UID_LIST + '\nextension ImportDatabase {\n' + add + '\n\n' + index + '\n}\n'
    standins, members = UID_LIST + INDEXER_STANDINS, [add, index]
    if has_uid_type(source):
        standins += '\n' + method(source, STUDY_UIDS) + '\n' + UID_TYPE_STANDINS
        members.append(method(source, STUDIES))
    return standins + '\nextension DicomFileIndexer {\n' + '\n\n'.join(members) + '\n}\n'


def source_at(revision):
    """The indexer's file at `revision`, under its name then or now."""
    for path in (INDEXER, FORMER):
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, path)], capture_output=True, text=True)
        if shown.returncode == 0:
            return shown.stdout
    raise FileNotFoundError('no indexer at %s' % revision)


def current():
    return (ROOT / INDEXER).read_text()
