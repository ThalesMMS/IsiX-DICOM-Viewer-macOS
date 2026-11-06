#!/usr/bin/env python3
"""A plugin's import still says what became of each file, through the single entry.

importFilesNow of IsiXDatabaseAdapter is taken from the checkout as it is and
compiled with stand-ins of the database and of DatabaseIngest, which indexes what
it is told to, with the preset of plugins. The files of the plugin are only read,
and IsiXImportResult must name, file by file: what could not be copied, what the
database has no room for, and what was copied but not indexed, whose copy goes.

The contract is IsiXPluginKit's: importFilesNow keeps its signature, and this
reads IsiXImportResult from the framework's source.
"""
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def member(source, signature):
    at = source.index(signature)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


adapter = (root / 'Horos/Sources/IsiXDatabaseAdapter.swift').read_text(encoding='utf-8')
method = member(adapter, 'func importFilesNow(at urls: [URL]) throws -> IsiXImportResult {')

STANDINS = r'''
import Foundation
import IsiXContracts

// The types of the kit the method fills, as IsiXDatabase.swift declares them.
public struct IsiXDatabaseImage: Hashable, Sendable { let file: String }
public struct IsiXImportResult: Hashable, Sendable {
    public struct Failure: Hashable, Sendable {
        public let file: URL
        public let reason: String
        public init(file: URL, reason: String) { self.file = file; self.reason = reason }
    }
    public var importedFiles: [URL]
    public var studyInstanceUIDs: [String]
    public var seriesInstanceUIDs: [String]
    public var failures: [Failure]
    public var images: [IsiXDatabaseImage] = []
    public init(importedFiles: [URL], studyInstanceUIDs: [String], seriesInstanceUIDs: [String], failures: [Failure]) {
        self.importedFiles = importedFiles; self.studyInstanceUIDs = studyInstanceUIDs
        self.seriesInstanceUIDs = seriesInstanceUIDs; self.failures = failures
    }
}

final class DicomStudyRecord { var studyInstanceUID: String? = "study" }
final class DicomSeriesRecord { var study: DicomStudyRecord? = DicomStudyRecord() }
final class DicomImage {
    let path: String
    var series: DicomSeriesRecord? = DicomSeriesRecord()
    init(path: String) { self.path = path }
    func completePath() -> String? { path }
}

final class DicomDatabase {
    let folder: String
    var made = 0
    var roomFor = Int.max
    init(folder: String) { self.folder = folder }
    func uniquePathForNewDataFile(withExtension ext: String) -> String? {
        guard made < roomFor else { return nil }
        made += 1
        return folder + "/\(made).\(ext)"
    }
    func object(withID id: Any) -> Any? { id }
}

/// Takes what does not end in "refused"; the options of the call are recorded.
nonisolated(unsafe) var asked: [(Int, String)] = []
struct DatabaseIngest {
    static let process = DatabaseIngest()
    func index(_ paths: [Any]?, preset: IngestPreset, in database: DicomDatabase) -> [Any]? {
        asked.append((paths?.count ?? 0, preset.name))
        return (paths as? [String] ?? []).filter { path in
            !(try! String(contentsOfFile: path, encoding: .utf8)).hasPrefix("refused")
        }.map { DicomImage(path: $0) }
    }
}

final class Adapter {
    let held: DicomDatabase
    init(_ database: DicomDatabase) { held = database }
    func database() throws -> DicomDatabase { held }
    static func image(_ image: DicomImage) -> IsiXDatabaseImage? { IsiXDatabaseImage(file: image.path) }
    static func seriesUID(_ series: DicomSeriesRecord) -> String? { "series" }

    @METHOD@
}
'''

DRIVER = r'''
import Foundation

@main struct Driver {
    static func main() throws {
        func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }
        let work = CommandLine.arguments[1]
        let good = URL(fileURLWithPath: work + "/good.dcm"), refused = URL(fileURLWithPath: work + "/refused.dcm")
        let missing = URL(fileURLWithPath: work + "/missing.dcm")
        try "taken".write(to: good, atomically: true, encoding: .utf8)
        try "refused".write(to: refused, atomically: true, encoding: .utf8)
        let database = DicomDatabase(folder: work + "/data")
        let result = try Adapter(database).importFilesNow(at: [good, missing, refused])
        check(asked.count == 1 && asked[0].0 == 2 && asked[0].1 == "plugin", "the entry was not asked once, with the plugin's preset, for the copies: \(asked)")
        check(result.importedFiles == [good], "imported: \(result.importedFiles)")
        check(result.failures.map(\.file) == [missing, refused], "the failures do not name each file: \(result.failures)")
        check(result.failures[1].reason.contains("not indexed"), "a file the database refused does not say so")
        check(result.studyInstanceUIDs == ["study"] && result.seriesInstanceUIDs == ["series"] && result.images.count == 1, "what was added")
        check(!FileManager.default.fileExists(atPath: work + "/data/2.dcm"), "the copy of the refused file stayed")
        check(FileManager.default.fileExists(atPath: good.path) && FileManager.default.fileExists(atPath: refused.path), "the plugin's files were touched")
        asked = []
        let full = DicomDatabase(folder: work + "/data"); full.roomFor = 0
        let none = try Adapter(full).importFilesNow(at: [good])
        check(asked.isEmpty && none.failures.count == 1 && none.failures[0].file == good, "no room is a failure of that file, and nothing to index")
        print("ok")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-plugin-import-') as directory:
    folder = Path(directory)
    (folder / 'data').mkdir()
    (folder / 'adapter.swift').write_text(STANDINS.replace('@METHOD@', method))
    (folder / 'driver.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', '-module-cache-path', str(folder / 'cache'),
                            *isix_modules.module_flags('IsiXContracts', folder / 'internal'),
                            str(folder / 'adapter.swift'), str(folder / 'driver.swift'), '-o', str(folder / 'tool')], capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL: the method does not compile with its stand-ins\n' + built.stderr[-2500:])
        sys.exit(1)
    ran = subprocess.run([str(folder / 'tool'), str(folder)], capture_output=True, text=True, timeout=60)
    if ran.stdout.strip() != 'ok':
        print((ran.stdout + ran.stderr)[-1200:])
        sys.exit(1)

kit = (root / 'IsiXPluginKit/Sources/IsiXDatabase.swift').read_text(encoding='utf-8')
if 'public var failures: [Failure]' not in kit or 'public func importFiles(at urls: [URL]) async throws -> IsiXImportResult' not in kit:
    print('FAIL: the kit no longer declares the import and its failures as this test reads them')
    sys.exit(1)
print('PASS: a plugin import names what it imported and, file by file, what could not be copied or indexed, through the plugin preset')
