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
                   studiesArray: NSMutableArray, studiesArrayStudyInstanceUID: NSMutableArray, modifiedStudiesArray: NSMutableArray,
                   defaultDate: Date, today: Date, dataDirPath: String?, reportsDirPath: String?, errorsDirPath: String?,
                   settings: DicomDatabaseImportSettings, rereadExistingItems: Bool, generatedByOsiriX: Bool, importedFiles: Bool,
                   preparedReportPath: inout String?) {
        database.indexFile(curDict, cursor: cursor, added: added, studiesArray: studiesArray,
                           studiesArrayStudyInstanceUID: studiesArrayStudyInstanceUID, modifiedStudiesArray: modifiedStudiesArray,
                           defaultDate: defaultDate, today: today, dataDirPath: dataDirPath, reportsDirPath: reportsDirPath,
                           errorsDirPath: errorsDirPath, settings: settings, rereadExistingItems: rereadExistingItems,
                           generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles, preparedReportPath: &preparedReportPath)
    }
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


def gated(source):
    """(the gated import, the indexing) of either shape."""
    if is_type(source):
        return method(source, ADD), method(source, INDEX)
    return method(source, FORMER_ADD), method(source, FORMER_INDEX)


def pasted(source):
    """The Swift that puts the two methods of `source` on the double."""
    add, index = gated(source)
    if is_type(source):
        return INDEXER_STANDINS + '\nextension DicomFileIndexer {\n' + add + '\n\n' + index + '\n}\n'
    return 'extension ImportDatabase {\n' + add + '\n\n' + index + '\n}\n'


def source_at(revision):
    """The indexer's file at `revision`, under its name then or now."""
    for path in (INDEXER, FORMER):
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, path)], capture_output=True, text=True)
        if shown.returncode == 0:
            return shown.stdout
    raise FileNotFoundError('no indexer at %s' % revision)


def current():
    return (ROOT / INDEXER).read_text()
