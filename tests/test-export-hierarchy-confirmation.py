#!/usr/bin/env python3
"""Study/series folders that collide within one export are resolved without a dialog."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('latin1')
start = source.index('- (NSArray*) exportDICOMFileInt: (NSMutableDictionary*) parameters')
end = source.index('+ (void) encryptFiles:', start)
export = source[start:end]
# Only a patient folder that predates the export may ask Replace/Cancel/Merge.
assert export.count('confirmDICOMExportFolder:') == 1
study = export.index('// Find the DICOM-STUDY folder')
series = export.index('// Find the DICOM-SERIE folder')
assert export.index('confirmDICOMExportFolder:') < export.index('folderForSource:studySource') < study
assert study < export.index('folderForSource:seriesSource') < series
# Database splits of one DICOM series share its UID and therefore its folder.
assert export.index('series.seriesDICOMUID') < export.index('series.seriesInstanceUID') < export.index('folderForSource:seriesSource')

code = r'''
import Foundation
@main struct Test {
 static func main() throws {
    let root = CommandLine.arguments[1]
    let fm = FileManager.default
    let claims = ExportFolderClaims()
    let proposed = root + "/Cine_1"
    // Twelve database series cut from one DICOM series: one folder, every file kept.
    for clip in 0..<12 {
        let folder = claims.folder(source: "1.2.3", proposed: proposed, componentLimit: 0)
        precondition(folder == proposed)
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("\(clip)".utf8).write(to: URL(fileURLWithPath: folder + "/IM-\(clip).dcm"), options: .withoutOverwriting)
    }
    let written = try fm.contentsOfDirectory(atPath: proposed)
    precondition(written.count == 12)
    // Other DICOM series under the same name: numbered siblings, stable per source.
    let second = claims.folder(source: "1.2.4", proposed: proposed, componentLimit: 0)
    let third = claims.folder(source: "1.2.5", proposed: proposed, componentLimit: 0)
    precondition(second == root + "/Cine_1_2" && third == root + "/Cine_1_3")
    precondition(claims.folder(source: "1.2.4", proposed: proposed, componentLimit: 0) == second)
    precondition(claims.folder(source: "1.2.3", proposed: proposed, componentLimit: 0) == proposed)
    // A name that only differs by case is the same folder on a default volume.
    precondition(claims.folder(source: "1.2.6", proposed: root + "/CINE_1", componentLimit: 0) == root + "/CINE_1_4")
    // A sibling name already held by a series of its own is skipped.
    let other = ExportFolderClaims()
    precondition(other.folder(source: "x", proposed: root + "/A_2", componentLimit: 0) == root + "/A_2")
    precondition(other.folder(source: "a", proposed: root + "/A", componentLimit: 0) == root + "/A")
    precondition(other.folder(source: "b", proposed: root + "/A", componentLimit: 0) == root + "/A_3")
    // The same name under another parent is free.
    precondition(other.folder(source: "b", proposed: root + "/Study/A", componentLimit: 0) == root + "/Study/A")
    // DICOMDIR components stay within eight characters.
    let media = ExportFolderClaims()
    precondition(media.folder(source: "a", proposed: root + "/12345678", componentLimit: 8) == root + "/12345678")
    let bounded = media.folder(source: "b", proposed: root + "/12345678", componentLimit: 8)
    precondition(bounded == root + "/123456_2")
    for copy in 3...11 {
        let name = (media.folder(source: "s\(copy)", proposed: root + "/12345678", componentLimit: 8) as NSString).lastPathComponent
        precondition(name.count <= 8 && name.hasSuffix("_\(copy)"))
    }
    print("PASS: split series share a folder, distinct sources get bounded siblings, no dialog")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-hierarchy-folders-') as d:
    p = Path(d)
    (p / 'test.swift').write_text(code)
    (p / 'exports').mkdir()
    subprocess.run(['xcrun', 'swiftc', '-sanitize=address', str(root / 'Horos/Sources/ExportFolderNaming.swift'), str(p / 'test.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test'), str(p / 'exports')], check=True)
