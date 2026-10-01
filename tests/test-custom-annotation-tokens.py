#!/usr/bin/env python3
"""The Annotations pane saves unknown tokens safely and lists each field once (#748).

Found in #711, when CIALayoutController moved to Swift with its behaviour:

1. Saving a layout, a DICOM_ token that named no known DICOM field and did not
   read as DICOM_group_element was saved with the group and element of the
   previous DICOM_ token of the save, so the annotation showed that token's
   tag. A token whose group or element only started with hex digits
   (DICOM_Foo_Bar) was read as a tag as well. Such a token now saves no group
   and element; DCMPix shows "-" for it.
2. -awakeFromNib, which the pane sends each time it is selected, appended the
   database fields to the controller's lists again, so the database fields
   menu (and the token completions) listed every field once more per
   selection. The lists are now replaced.
3. A DB_ token without a dot raised NSRangeException on save. It is now left
   out, as an empty DB_ token.

The pane's Swift sources are compiled as they are, with doubles for the alert
functions, -isUnlocked and the preferences window controller that lists the
DICOM fields; the database model is a small one written next to the harness.
The controller saves to the standard user defaults of the harness, whose
domain is its uniquely named executable; the domain is deleted afterwards.
`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
folder = 'Preference Panes/OSICustomImageAnnotations'


def read_bytes(name, source_folder=folder):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{source_folder}/{name}'])
    return (root / source_folder / name).read_bytes()


def names():
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', f'{revision}:{folder}/']).decode().split('\n')
    return [p.name for p in (root / folder).iterdir()]


# The C functions of OSICustomImageAnnotations+CAPI.m, without the alert panels.
c_doubles = r'''
#import <Cocoa/Cocoa.h>
NSComparisonResult compareViewTags(id a, id b, void *context) { return NSOrderedSame; }
NSInteger CIARunAlertPanel(NSString *t, NSString *m, NSString *d, NSString *a, NSString *o) { return 1; }
NSInteger CIARunInformationalAlertPanel(NSString *t, NSString *m, NSString *d, NSString *a, NSString *o) { return 1; }
'''

# NSPreferencePane (OsiriX) of the app.
doubles = r'''
import AppKit
extension OSICustomImageAnnotations { @objc func isUnlocked() -> Bool { true } }
'''

main = r'''
import AppKit
import CoreData

final class PreferencesDouble: NSWindowController {
    @objc func prepareDICOMFieldsArrays() -> NSArray {
        [CIADICOMField(group: 0x0010, element: 0x0010, name: "PatientsName"),
         CIADICOMField(group: 0x0008, element: 0x0060, name: "Modality")]
    }
}

func writeModel() {
    func entity(_ name: String, _ attributes: [String]) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.properties = attributes.map { a in
            let d = NSAttributeDescription(); d.name = a; d.attributeType = .stringAttributeType; return d
        }
        return e
    }
    let model = NSManagedObjectModel()
    model.entities = [entity("Study", ["name", "patientID", "windowsState"]),
                      entity("Series", ["modality", "seriesDescription", "thumbnail"]),
                      entity("Image", ["instanceNumber"])]
    let data = try! NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: false)
    try! data.write(to: URL(fileURLWithPath: (Bundle.main.resourcePath! as NSString).appendingPathComponent("OsiriXDB_DataModel.mom")))
}

// AppKit setup and the synchronous scenarios execute on the main thread.
MainActor.assumeIsolated {
writeModel()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
let preferences = PreferencesDouble(window: window)
let pane = OSICustomImageAnnotations()
pane.mainView = window.contentView!
pane.DICOMFieldsPopUpButton = NSPopUpButton()
pane.databaseFieldsPopUpButton = NSPopUpButton()
pane.specialFieldsPopUpButton = NSPopUpButton()
pane.sameAsDefaultButton = NSButton()
pane.sameAsDefaultButton.setButtonType(.switch)
pane.sameAsDefaultButton.state = .off
let layoutView = CIALayoutView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
window.contentView!.addSubview(layoutView)
let controller = CIALayoutController(window: nil)
@MainActor
func select() {
    controller.setLayoutView(layoutView)
    controller.setPrefPane(pane)
    controller.awakeFromNib()
}

@MainActor
func save(_ tokens: [String]) -> [NSDictionary] {
    let annotation = CIAAnnotation(frame: NSRect(x: 10, y: 10, width: 75, height: 22))
    annotation.setContent(tokens as NSArray)
    let placeHolder = layoutView.placeHolderArray[0]
    placeHolder.annotationsArray().removeAllObjects()
    placeHolder.addAnnotation(annotation, animate: false)
    controller.saveAnnotationLayout(forModality: "Default")
    let layout = controller.annotationsLayoutDictionary()["Default"] as! NSDictionary
    let saved = (layout["LowerLeft"] as! NSArray)[0] as! NSDictionary
    return saved["fullContent"] as! [NSDictionary]
}

var failures: [String] = []
select()
switch CommandLine.arguments[1] {
case "menu":
    let items = pane.databaseFieldsPopUpButton.numberOfItems
    let titles = pane.databaseFieldsPopUpButton.itemArray.map { $0.title }
    // 3 level headers, 2 separators, 2 + 2 + 1 fields (windowsState and thumbnail are left out).
    if items != 10 { failures.append("after the first selection the database menu has \(items) items, not 10: \(titles)") }
    select(); select()
    let again = pane.databaseFieldsPopUpButton.numberOfItems
    if again != items { failures.append("after three selections the database menu has \(again) items instead of \(items)") }
    let studyNames = pane.databaseFieldsPopUpButton.itemArray.filter { ($0.representedObject as? String) == "study.name" }.count
    if studyNames != 1 { failures.append("the database menu lists study.name \(studyNames) times") }
    let dicomItems = pane.DICOMFieldsPopUpButton.numberOfItems
    if dicomItems != 3 { failures.append("the DICOM fields menu has \(dicomItems) items after three selections, not 3") }
case "dicom":
    let content = save(["DICOM_PatientsName", "DICOM_NoSuchField", "DICOM_0x0020_0x0013", "DICOM_Unknown",
                        "DICOM_0x0028_Zeta", "DICOM_Foo_Bar", "DICOM_0x0018_0x0050_Thickness", "DICOM_modality"])
    func tag(_ i: Int) -> String {
        let f = content[i]
        guard let g = f["group"] as? NSNumber, let e = f["element"] as? NSNumber else { return "none" }
        return String(format: "%04x,%04x", g.intValue, e.intValue)
    }
    let expected = ["0010,0010", "none", "0020,0013", "none", "none", "none", "0018,0050", "0008,0060"]
    if content.count != expected.count { failures.append("\(content.count) fields saved for \(expected.count) DICOM_ tokens") }
    for (i, want) in expected.enumerated() where i < content.count {
        let got = tag(i)
        if got != want { failures.append("\(content[i]["tokenTitle"] ?? "?") saved tag \(got), expected \(want)") }
        if (content[i]["type"] as? String) != "DICOM" { failures.append("\(content[i]["tokenTitle"] ?? "?") is not saved as a DICOM field") }
    }
    if content.count > 6, (content[6]["name"] as? String) != "Thickness" { failures.append("the name of DICOM_group_element_name is lost") }
case "db":
    let content = save(["DB_study.name", "DB_nodot", "DB_", "Special_Zoom", "text"])
    let types = content.map { "\($0["type"] ?? "?")" }
    if types != ["DB", "Special", "Manual"] { failures.append("saved field types \(types), expected [DB, Special, Manual]") }
    if let first = content.first, (first["level"] as? String) != "study" || (first["field"] as? String) != "name" {
        failures.append("DB_study.name saved as \(first)")
    }
default:
    failures.append("unknown mode")
}
for f in failures { print("FAIL: \(f)") }
exit(failures.isEmpty ? 0 : 1)
}
'''

failures = []
# Named uniquely: the name is the harness's defaults domain.
harness = f'horos-annotation-tokens-{uuid.uuid4().hex[:12]}'
with tempfile.TemporaryDirectory(prefix='horos-annotation-tokens-') as tmp:
    p = Path(tmp)
    sources = []
    for name in names():
        if name.endswith(('.swift', '.h')):
            (p / name).write_bytes(read_bytes(name))
            if name.endswith('.swift'):
                sources.append(str(p / name))
    # Compile the app's callback bridge when the selected revision uses it.
    if any('assumeMainActor(' in Path(source).read_text() for source in sources):
        callback = p / 'MainActorCallbacks.swift'
        callback.write_bytes(read_bytes(callback.name, 'Horos/Sources'))
        sources.append(str(callback))
    (p / 'Doubles.swift').write_text(doubles)
    (p / 'main.swift').write_text(main)
    (p / 'CDoubles.m').write_text(c_doubles)
    # The pane's headers, as the app's bridging header imports them.
    (p / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import "OSICustomImageAnnotations.h"\n')
    build = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', str(p / 'CDoubles.m'), '-o', str(p / 'CDoubles.o')],
                           capture_output=True, text=True)
    if not build.returncode:
        build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(p / 'Bridging.h'),
                                *sorted(sources), str(p / 'Doubles.swift'), str(p / 'main.swift'), str(p / 'CDoubles.o'),
                                '-o', str(p / harness)], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-3000:])
        failures.append('the Annotations pane sources do not compile with the doubles')
    else:
        try:
            runs = [(what, subprocess.run([str(p / harness), mode], capture_output=True, text=True, timeout=120))
                    for mode, what in (('menu', 'selecting the pane'), ('dicom', 'saving DICOM_ tokens'),
                                       ('db', 'saving DB_ tokens'))]
        finally:
            subprocess.run(['defaults', 'delete', harness], capture_output=True)
            plist = Path.home() / 'Library' / 'Preferences' / f'{harness}.plist'
            if plist.exists():
                plist.unlink()
        for what, done in runs:
            lines = [l[6:] for l in done.stdout.splitlines() if l.startswith('FAIL: ')]
            failures += [f'{what}: {l}' for l in lines]
            if done.returncode and not lines:
                if 'NSRangeException' in done.stderr:
                    failures.append(f'{what}: NSRangeException was raised')
                else:
                    reason = [l for l in done.stderr.splitlines() if 'reason' in l or 'Fatal error' in l]
                    failures.append(f'{what}: the harness stopped with status {done.returncode}: '
                                    f'{reason[0] if reason else done.stderr[-400:]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: unknown DICOM_ tokens save no tag, a DB_ token without a dot is left out, '
      'and the database fields menu lists each field once however often the pane is selected')
