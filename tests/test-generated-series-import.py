#!/usr/bin/env python3
"""What every export does with the files it wrote is said once, and as each said it.

The viewers, the 3D views, the browser and the study each kept their own copy of
the same steps after an export. GeneratedSeriesImport is that copy. This reads
every export of the last revision before the type existed, found with
isix_modules.revision_before, and says what each one did after indexing: send to
the node, mark as key images, neither. Each must ask the type for the same, in
the same order of files of the same revision.

The type itself is compiled with stand-ins, and driven: the options go through
the single entry with the preset of generated objects; the paths go as they came,
with what `value(forKey: "file")` leaves for a result without a file, so that one
bad entry does not lose the batch; the send and the mark follow the two export
preferences each; no browser means nothing is indexed. An image made for a
given database (a key image, a pasted image) is written at a new path of that
database and indexed in it, not in the browser's; nothing written, nothing
indexed.
"""
from pathlib import Path
import importlib.util
import re
import subprocess
import sys
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)
failures = []

SOURCE = 'Horos/Sources/GeneratedSeriesImport.swift'
# file: (does it send, does it mark) of each export of the revision before, in
# reading order, and the call that says the same now.
EXPORTS = {
    'ViewerController+Export.swift': [(True, False), (True, True)],
    'MPRController.swift': [(True, True)],
    'CPRController.swift': [(True, True)],
    'OrthogonalMPRViewer.swift': [(True, True)],
    'OrthogonalMPRPETCTViewer.swift': [(True, True)],
    'EndoscopyViewer.swift': [(True, True)],
    'EndoscopyMPRView.swift': [(True, True)],
    'FlyThruController.swift': [(True, True)],
    'SceneView.swift': [(True, True)],
}
# Where the exports of a file of the revision before are now.
NOW = {'ViewerController+Export.swift': 'ViewerImageExporter.swift'}
# What goes through `add` from where SceneView's copy was called.
SCENE_CALLERS = ('VRView+Export.swift', 'SRView+Export.swift', 'ROIVolumeView.swift')
# Index only: they keep their own next step, or none.
INDEX_ONLY = {'BrowserController+DICOMExport.swift': 1, 'DicomStudy.swift': 1}
PRODUCED = re.compile(r'\baddFiles\(atPaths: (?:producedFiles\.value\(forKey: "file"\) as\? \[Any\]|paths),')


def shown(revision, path):
    return subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True).stdout.decode('utf-8', 'replace')


def exports(text):
    """(sends, marks) of each export of a file: what follows its call, until the next one."""
    found = []
    calls = list(PRODUCED.finditer(text))
    for number, call in enumerate(calls):
        end = calls[number + 1].start() if number + 1 < len(calls) else len(text)
        after = text[call.start():min(end, call.start() + 1500)]
        # The copy ends with the block of its export: the next member starts at a declaration.
        match = re.search(r'\n\s*(?:@objc|func |override func |private func |static func |nonisolated func )', after)
        after = after[:match.start()] if match else after
        found.append(('afterExportSendToDICOMNode' in after, 'afterExportMarkThemAsKeyImages' in after))
    return found


revision = isix_modules.revision_before(root, SOURCE)
if revision is None:
    print('skipped: this history does not reach the revision before the type', file=sys.stderr)
    sys.exit(SKIPPED)

for name, expected in sorted(EXPORTS.items()):
    before = exports(shown(revision, 'Horos/Sources/' + name))
    if before != expected:
        failures.append(f'{name}: the revision before did {before}, this test says {expected}')
    if name == 'SceneView.swift':
        continue
    code = indicator.swift_code((root / 'Horos/Sources' / NOW.get(name, name)).read_text(encoding='utf-8'))
    now = [('marksKeyImages: false' not in line) for line in code.split('\n') if 'GeneratedSeriesImport.process.add(' in line]
    if now != [marks for _, marks in expected]:
        failures.append(f'{NOW.get(name, name)}: marks {now} now, {[marks for _, marks in expected]} before')
    if 'afterExport' in code:
        failures.append(f'{NOW.get(name, name)} still reads the export preferences itself')
for name in SCENE_CALLERS:
    code = indicator.swift_code((root / 'Horos/Sources' / name).read_text(encoding='utf-8'))
    if 'GeneratedSeriesImport.process.add(' not in code or 'marksKeyImages: false' in code:
        failures.append(f'{name} does not ask for what the 3D export did')
for name, count in INDEX_ONLY.items():
    code = indicator.swift_code((root / 'Horos/Sources' / name).read_text(encoding='utf-8'))
    # add(into:writing:) only writes and indexes, too: it neither sends nor marks.
    if code.count('GeneratedSeriesImport.process.images(indexing:') != count or re.search(r'GeneratedSeriesImport\.process\.add\((?!into:)', code):
        failures.append(f'{name} no longer only indexes')

STANDINS = r'''
import Foundation
import IsiXContracts
import IsiXPreferences

nonisolated(unsafe) var journal: [String] = []

final class DicomImage: NSObject {
    var key: NSNumber?
    func setIsKey(_ value: NSNumber!) { key = value; journal.append("mark") }
}
class DicomDatabase: NSObject {
    var folder = "/browser"
    func objects(withIDs ids: [Any]!) -> [Any]! { ids }
    func uniquePathForNewDataFile(withExtension ext: String!) -> String! { folder + "/new." + ext }
}
/// A shared database: told of the key images it must send once the server has them.
final class RemoteDicomDatabase: DicomDatabase {
    func markAddedImagesAsKeyImages(_ images: [DicomImage]) { journal.append("remote \(images.count)") }
}
final class BrowserController: NSObject {
    var database: DicomDatabase? = DicomDatabase()
    func selectServer(_ objects: [Any]!) { journal.append("send \((objects ?? []).count)") }
}
final class Defaults: PreferenceStore, @unchecked Sendable {
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Bool }
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}
nonisolated(unsafe) var images: [Any]? = nil
struct DatabaseIngest {
    func index(_ paths: [Any]?, preset: IngestPreset, in database: DicomDatabase) -> [Any]? {
        journal.append("index \(preset.name) \(paths?.count ?? -1) \(paths?.contains { $0 is NSNull } == true ? "with a hole" : "whole")")
        if database.folder != "/browser" { journal.append("in \(database.folder): \((paths ?? []).map { "\($0)" }.joined(separator: " "))") }
        return images
    }
}
final class ProcessGraph: @unchecked Sendable {
    static let process = ProcessGraph()
    var browser: BrowserController? = BrowserController()
    let defaults = Defaults()
    @MainActor var currentBrowser: BrowserController? { browser }
    var browserDatabase: DicomDatabase? { browser?.database }
    var preferences: Defaults { defaults }
    var databaseIngest: DatabaseIngest { DatabaseIngest() }
}
'''

DRIVER = r'''
import Foundation

@main struct Driver {
    @MainActor static func main() {
        let graph = ProcessGraph.process
        let series = GeneratedSeriesImport.process
        func expect(_ wanted: [String], _ message: String) {
            if journal != wanted { print("FAIL: \(message): \(journal)"); exit(1) }
            journal = []
        }
        let first = DicomImage(), second = DicomImage()
        images = [first, second]

        series.add(["a", "b"])
        expect(["index generated 2 whole"], "neither preference")
        graph.defaults.values["afterExportSendToDICOMNode"] = true
        series.add(["a", NSNull(), "b"])
        expect(["index generated 3 with a hole", "send 2"], "a result without a file lost the batch, or the send did not follow")
        graph.defaults.values["afterExportMarkThemAsKeyImages"] = true
        series.add(["a"], marksKeyImages: false)
        expect(["index generated 1 whole", "send 2"], "an export that never marked its images marked them")
        series.add(["a"])
        expect(["index generated 1 whole", "send 2", "mark", "mark"], "the send comes first, then the mark")
        let local = graph.browser?.database
        graph.browser?.database = RemoteDicomDatabase()
        series.add(["a"])
        expect(["index generated 1 whole", "send 2", "mark", "mark", "remote 2"], "a shared database is not told of the marks after they are made")
        graph.browser?.database = local
        series.add([])
        expect([], "nothing to index")
        let found = series.images(indexing: ["a"])
        if found?.count != 2 { print("FAIL: the images do not come back"); exit(1) }
        expect(["index generated 1 whole"], "indexing alone sends or marks")
        // An image made for a database the browser does not show: written at a
        // new path of that database and indexed in it, never in the browser's.
        let viewers = DicomDatabase()
        viewers.folder = "/viewer"
        var handed: [String] = []
        let added = series.add(into: viewers) { path in handed.append(path); return path }
        if handed != ["/viewer/new.dcm"] || added?.count != 2 { print("FAIL: the image was not written in its database's folder: \(handed)"); exit(1) }
        expect(["index generated 1 whole", "in /viewer: /viewer/new.dcm"], "the image was not indexed in its own database")
        if series.add(into: viewers, writing: { _ in nil }) != nil { print("FAIL: nothing written, and an answer"); exit(1) }
        expect([], "an image not written was indexed")
        graph.browser = nil
        series.add(["a"])
        expect([], "no browser, nothing to do")
        print("ok")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-generated-series-') as directory:
    folder = Path(directory)
    (folder / 'standins.swift').write_text(STANDINS)
    (folder / 'driver.swift').write_text(DRIVER)
    source = (root / SOURCE).read_text(encoding='utf-8', errors='surrogateescape').replace('import AppKit\n', 'import Foundation\n')
    (folder / 'type.swift').write_text(source)
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'cache'),
                            *isix_modules.module_flags('IsiXContracts', folder / 'internal'),
                            *isix_modules.module_flags('IsiXPreferences', folder / 'internal'),
                            *isix_modules.module_flags('IsiXDatabase', folder / 'internal'),
                            *map(str, (folder / 'standins.swift', folder / 'type.swift', folder / 'driver.swift')),
                            '-o', str(folder / 'tool')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the type does not compile with its stand-ins\n' + built.stderr[-2000:])
    else:
        ran = subprocess.run([str(folder / 'tool')], capture_output=True, text=True, timeout=60)
        if ran.stdout.strip() != 'ok':
            failures.append((ran.stdout + ran.stderr)[-1000:])

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: {sum(len(each) for each in EXPORTS.values())} exports of {revision} ask the type for what each did after indexing, '
      f'{len(INDEX_ONLY)} only index; the type sends, marks and keeps a batch with a hole as they did')
