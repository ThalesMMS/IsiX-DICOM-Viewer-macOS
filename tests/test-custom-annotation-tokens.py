#!/usr/bin/env python3
"""The Annotations pane saves unknown tokens safely and lists each field once.

Found when CIALayoutController moved to Swift with its behaviour:

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
4. The layout stores the titles of its annotations in English: those the
   application ships ("Image Size") and the name a new annotation is given
   ("Annotation 3"), which the pane shows in the user's language. Named from
   the catalog, a new annotation was stored as "注釈 3" in Japanese and showed
   so in every other language. Checked in Japanese, with a catalog of its own.
5. The content field showed the stored keys ("Special_Image Size",
   "DICOM_PatientsName") in every language. It now shows the name of each
   key's field, translated where the catalog has it, and keeps the key as the
   token's value, for editing and for the pasteboard. Checked in Japanese.
6. The pane's own save action wrote the layout under the title of the
   modalities pop-up, whose first item is "Default" in the user's language:
   in Japanese the default layout would be stored as "デフォルト", a key nothing
   reads. It now saves under the modality's key.

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
pane.contentTokenField = NSTokenField()
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
case "titles":
    // Run in Japanese with a catalog that names "Annotation" and "Image Size": the layout keeps English titles, which
    // the pane shows in the user's language, so that a layout saved in one language reads the same in another.
    if Bundle.main.localizedString(forKey: "Annotation", value: nil, table: nil) != "注釈" {
        failures.append("the harness does not read its Japanese catalog")
    }
    let fresh = CIAAnnotation(frame: NSRect(x: 0, y: 0, width: 75, height: 22))
    if fresh.title != "Annotation" { failures.append("a new annotation is named \(fresh.title ?? "nil") in the layout, not Annotation") }
    SHOWN_TITLES
case "modality":
    // Run in Japanese: the modalities pop-up starts with "Default" in the user's language, and the layouts are
    // stored under "Default". The pane's own save must write the layout shown under that key.
    pane.modalitiesPopUpButton = NSPopUpButton()
    pane.layoutView = layoutView
    pane.willSelect()
    pane.didSelect()
    let shownFirst = pane.modalitiesPopUpButton.itemTitle(at: 0)
    if shownFirst != "デフォルト" { failures.append("the modalities pop-up starts with \(shownFirst), not the translated Default") }
    pane.modalitiesPopUpButton.selectItem(at: 0)
    let own = pane.layoutController()!
    let annotation = CIAAnnotation(frame: NSRect(x: 10, y: 10, width: 75, height: 22))
    annotation.setContent(["Special_Zoom"] as NSArray)
    let placeHolder = layoutView.placeHolderArray[0]
    placeHolder.annotationsArray().removeAllObjects()
    placeHolder.addAnnotation(annotation, animate: false)
    pane.saveAnnotationLayout(nil)
    let layouts = own.annotationsLayoutDictionary()!
    if layouts[shownFirst] != nil { failures.append("the layout is saved under the pop-up's title \(shownFirst)") }
    let saved = ((layouts["Default"] as? NSDictionary)?["LowerLeft"] as? NSArray)?.firstObject as? NSDictionary
    if (saved?["content"] as? [String]) != ["Special_Zoom"] { failures.append("the layout shown is not saved under Default: \(String(describing: saved))") }
case "display":
    // Run in Japanese: the content field shows each key by the name of its field, translated where the catalog has
    // it, and keeps the key itself as the token's value, for editing and for the pasteboard.
    let field = pane.contentTokenField!
    let delegate = controller as NSTokenFieldDelegate
    let keys = ["Special_Image Size", "Special_Zoom", "Special_", "DICOM_patientsname", "DICOM_0x0018_0x0050_Thickness",
                "DICOM_0x0020_0x0013", "DICOM_", "DB_study.name", "DB_series.modality", "DB_", "text"]
    let shown = keys.map { delegate.tokenField?(field, displayStringForRepresentedObject: $0) ?? "(raw) \($0)" }
    let expected = ["画像サイズ", "Zoom", "その他の情報…", "PatientsName", "Thickness (0018,0050)", "(0020,0013)",
                    "DICOM fields…", "検査: name", "Series: modality", "Database fields…", "text"]
    if shown != expected { failures.append("the content field shows \(shown), expected \(expected)") }
    let editing = keys.map { delegate.tokenField?(field, editingStringForRepresentedObject: $0) ?? "(display)" }
    if editing != keys { failures.append("the tokens are edited as \(editing), not as their keys") }
    let board = NSPasteboard(name: NSPasteboard.Name("horos-annotation-tokens-\(ProcessInfo.processInfo.processIdentifier)"))
    let written = delegate.tokenField?(field, writeRepresentedObjects: keys, to: board) ?? false
    let read = delegate.tokenField?(field, readFrom: board) as? [String]
    if !written || read != keys { failures.append("the pasteboard carries \(read ?? []), not the keys") }
    board.releaseGlobally()
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
    # The panes load their nib through instantiatePaneNib, which reads its texts from the catalog.
    if any('instantiatePaneNib(' in Path(source).read_text() for source in sources):
        loader = p / 'PaneCatalogTranslation.swift'
        loader.write_bytes(read_bytes(loader.name, 'Preference Panes'))
        sources.append(str(loader))
    (p / 'Doubles.swift').write_text(doubles)
    # What the pane shows for a stored title, where the sources have it.
    annotation_source = (p / 'CIAAnnotation.swift').read_text() if (p / 'CIAAnnotation.swift').exists() else ''
    shown_titles = ('''
    let shown = ["Annotation 3", "Image Size", "My notes", "Annotation 3b"].map { CIAAnnotation.displayedTitle($0) ?? "nil" }
    if shown != ["注釈 3", "画像サイズ", "My notes", "Annotation 3b"] { failures.append("the stored titles show as \\(shown)") }
    let kept = [CIAAnnotation.storedTitle("注釈 3", replacing: "Annotation 3"), CIAAnnotation.storedTitle("Mine", replacing: "Annotation 3")]
    if kept != ["Annotation 3", "Mine"] { failures.append("a title edited in the pane is stored as \\(kept)") }
''' if 'static func displayedTitle(' in annotation_source
                    else '    failures.append("the pane shows the stored (English) titles as they are")\n')
    (p / 'main.swift').write_text(main.replace('    SHOWN_TITLES\n', shown_titles), encoding='utf-8')
    # The catalog the titles mode reads, in Japanese.
    (p / 'ja.lproj').mkdir()
    (p / 'ja.lproj' / 'Localizable.strings').write_text('"Annotation" = "注釈";\n"Image Size" = "画像サイズ";\n'
                                                        '"Study" = "検査";\n"Other infos" = "その他の情報";\n"Default" = "デフォルト";\n',
                                                        encoding='utf-8')
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
            runs = [(what, subprocess.run([str(p / harness), *mode], capture_output=True, text=True, timeout=120))
                    for mode, what in ((['menu'], 'selecting the pane'), (['dicom'], 'saving DICOM_ tokens'),
                                       (['db'], 'saving DB_ tokens'),
                                       (['titles', '-AppleLanguages', '(ja)'], 'naming annotations in Japanese'),
                                       (['display', '-AppleLanguages', '(ja)'], 'showing tokens in Japanese'),
                                       (['modality', '-AppleLanguages', '(ja)'], 'saving from the pane in Japanese'))]
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
      'the database fields menu lists each field once however often the pane is selected, '
      'annotations are stored with English titles that show in the user\'s language, '
      'and the content field shows each token by its field\'s name while keeping the key')
