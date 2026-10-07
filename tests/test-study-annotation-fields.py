#!/usr/bin/env python3
"""Saved DB annotation tokens must use the study value without reparsing files."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DicomStudy.swift').read_text()
start = source.index('    public override func value(forUndefinedKey key: String)')
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth:
    depth += {'{': 1, '}': -1}.get(source[end], 0)
    end += 1
method = source[start:end]

driver = r'''import Foundation
import Darwin

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func dicomStudyOnQueue<T>(_ context: Any?, _ body: () -> T) -> T { body() }
func dicomStudyTry(_ label: String, _ body: () -> Void) { body() }
func dicomStudyEnumerate(_ objects: NSSet?) -> [Any] { objects?.allObjects ?? [] }
func dicomStudyValue(_ object: Any, _ key: String) -> Any? {
    (object as? NSObject)?.value(forKey: key)
}
class DicomFile {
    static var reads = 0
    static func getDicomField(_ key: String, forFile path: String?) -> String? {
        reads += 1
        check(path == "/synthetic/image.dcm", "fallback must use an image path")
        return "value-from-file"
    }
}
class DicomImage: NSObject {
    func completePath() -> String { "/synthetic/image.dcm" }
}
class Series: NSObject {
    @objc dynamic var images = NSSet(object: DicomImage())
}
class DicomStudy: NSObject {
    var managedObjectContext: Any? = nil
    var series: NSSet? = NSSet(object: Series())
    @objc dynamic var institutionName: String? = "Synthetic institution"
''' + method + r'''
}

let study = DicomStudy()
// Opening a 575-image series, then switching to another of the same size.
for _ in 0..<1150 {
    check(study.value(forKey: "InstitutionName") as? String == "Synthetic institution",
          "the saved InstitutionName token must read the database property")
}
check(DicomFile.reads == 0, "study annotations must not reparse a DICOM per image")
study.institutionName = "Updated institution"
check(study.value(forKey: "InstitutionName") as? String == "Updated institution",
      "an edited database value must not return a stale annotation")
study.institutionName = nil
check(study.value(forKey: "InstitutionName") == nil, "an absent database value stays absent")
check(DicomFile.reads == 0, "an absent institution must not trigger file reads")
check(study.value(forKey: "StudyComments") as? String == "value-from-file",
      "other DICOM keywords must retain the file fallback")
check(DicomFile.reads == 1, "the real DICOM fallback must still read its file")
print("PASS: 1,150 saved annotation queries make no file reads; edits, nil and DICOM fallback work")
'''

with tempfile.TemporaryDirectory(prefix='horos-study-annotations-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
