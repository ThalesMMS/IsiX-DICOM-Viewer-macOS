"""What the single entry does for a transport, for a harness that compiles the
transport with a stand-in of the database and of the process graph.

The real DatabaseIngest reaches the whole database. This one does what a
transport can see of it, over the `DicomDatabase` of the harness: the folder of
the active database, a rename for a publication, and the database's own method
for a request. A harness puts SWIFT beside its other doubles, gives its stand-in
graph `var databaseIngest: DatabaseIngest { DatabaseIngest() }`, and compiles
with IsiXContracts.
"""

SWIFT = r'''
import Foundation
import IsiXContracts

struct DatabaseIngest {
    static let process = DatabaseIngest()
    func admissionFolder() -> IngestFolder { IngestFolder(path: DicomDatabase.activeLocal()?.incomingDirPath() ?? "") }
    func publish(fileAt path: String, named name: String, into folder: IngestFolder, preset: IngestPreset) -> IngestPublication {
        let failed = rename(path, folder.path(named: name)) != 0
        return IngestPublication(errorNumber: failed ? errno : 0, folder: folder)
    }
    func publish(_ draft: IngestDraft, preset: IngestPreset) -> IngestPublication {
        publish(fileAt: draft.path, named: draft.name, into: draft.folder, preset: preset)
    }
    func discard(_ draft: IngestDraft) { try? FileManager.default.removeItem(atPath: draft.path) }
    func requestImport() { DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting() }
}
'''
