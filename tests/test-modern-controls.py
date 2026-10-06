#!/usr/bin/env python3
"""Compile all migrated control xibs; exercise actual fields and panel.

Uses ibtool and an isolated AppKit child process, without a clinical database.
The probe extracts the actual English control trees, including their formatters,
actions and bindings, and supplies only the surrounding owner/window outlets.
"""
from pathlib import Path
import copy
import os
import subprocess
import tempfile
import xml.etree.ElementTree as E

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
viewer_source = (root/'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
suv_start = viewer_source.index('- (IBAction) updateSUVValues:(id) sender')
suv_update = viewer_source[suv_start:viewer_source.index('\n- (void) displaySUV:', suv_start)]
pix_source = (root/'Horos/Sources/DCMPix.m').read_bytes().decode('latin1')
date_start = pix_source.index('if( preferredDate && preferredTime && radioTime)')
date_end = pix_source.index('\n            \n            [self computeTotalDoseCorrected]', date_start)
suv_load_dates = pix_source[date_start:date_end]

MAIN = r'''
import AppKit
// Model boundaries for the actual toolbar window; no viewer or database is opened.
@objcMembers final class ViewerController: NSObject, NSToolbarDelegate {
    var window: NSWindow?
    var toolbarPanel: ToolbarPanelController?
    func fullScreenON() -> Bool { false }
    static func frontMostDisplayed2DViewer(for screen: NSScreen?) -> ViewerController? { nil }
}
@objcMembers final class ToolbarPanelController: NSWindowController {
    var viewer: ViewerController?
    func applicationDidChangeScreenParameters(_ note: Notification?) {}
}
@objcMembers final class AppController: NSObject {
    static func usetoolbarpanel() -> Bool { false }
}
@objc(CLUTOpacityView) final class CLUTOpacityView: NSView {}
@objc(Owner) @objcMembers final class Owner: NSObject {
    dynamic var institution = "Synthetic Institution"
    dynamic var patientsName = "Synthetic Patient"
    dynamic var patientID = "TEST"
    dynamic var patientsDOB = Date(timeIntervalSince1970: 0)
    dynamic var patientsAge = "50"
    dynamic var patientsSex = "O"
    dynamic var studyDate = Date(timeIntervalSince1970: 1_000)
    var actions = 0
    var opened = 0
    var closed = 0
    weak var suv: HorosFormView?
    var acquisition: Date?
    var suvAlerts = 0
    func updateSUVValues(_ sender: Any?) {
        actions += 1
        if let suv, let acquisition { suvAlerts += Int(HorosSUVValidate(suv, acquisition)) }
    }
    func preview(_ sender: Any?) { actions += 1 }
    func drawerDidOpen(_ note: Notification) { opened += 1 }
    func drawerDidClose(_ note: Notification) { closed += 1 }
}
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
_ = NSApplication.shared
let owner = Owner()
var objects: NSArray?
check(NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), bundle: nil).instantiate(withOwner: owner, topLevelObjects: &objects), "probe nib failed")
let annotationBox = objects!.compactMap { $0 as? NSBox }.first { $0.identifier?.rawValue == "annotation-container" }!
check(annotationBox.boxType == .primary && annotationBox.isTransparent, "annotation box appearance contract")
check(annotationBox.contentViewMargins == .zero, "annotation margins changed")
check(annotationBox.frame.size == NSSize(width: 668, height: 158), "annotation container dimensions changed")
check(annotationBox.contentView!.frame == annotationBox.bounds, "annotation content no longer fills borderless box")
annotationBox.setFrameSize(NSSize(width: 800, height: 200))
check(annotationBox.contentView!.frame == annotationBox.bounds, "annotation resize clipped content")
let mprFields = objects!.compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue.hasPrefix("mpr-") == true }
check(mprFields.count == 4, "MPR numeric fields missing")
var numericEvidence: [String: Any] = [:]
for field in mprFields {
    let formatter = field.formatter as! NumberFormatter
    var localeEvidence: [String: Any] = [:]
    for locale in ["en_US", "pt_BR", "de_DE", "ar_SA", "ja_JP"] {
        let copy = formatter.copy() as! NumberFormatter
        copy.locale = Locale(identifier: locale)
        var strings: [String] = []
        for value in [0.0, 1.25, -1.25, 12.34567, -12.34567, 1234.567, -1234.567] {
            let formatted = copy.string(from: NSNumber(value: value))!
            strings.append(formatted)
            let decoded = copy.number(from: formatted)!.doubleValue
            let rounded = (value * 100).rounded() / 100
            check(abs(decoded - rounded) < 0.00001, "MPR positive/negative fraction round trip changed for \(locale)")
        }
        let parses = ["0.00", "1.25", "-1.25", "1234.57", "1,25"].map { copy.number(from: $0)?.doubleValue }
        localeEvidence[locale] = ["strings": strings, "parses": parses.map { $0 as Any? ?? NSNull() }]
    }
    numericEvidence[field.identifier!.rawValue] = ["behavior": formatter.formatterBehavior.rawValue, "locales": localeEvidence]
    check(field.frame.size == NSSize(width: 66, height: 19), "MPR numeric bounds changed")
}
let evidenceData = try! JSONSerialization.data(withJSONObject: numericEvidence, options: [.sortedKeys])
print("MPR_FORMATTER_EVIDENCE " + String(data: evidenceData, encoding: .utf8)!); fflush(stdout)
let demandBoxes = objects!.compactMap { $0 as? NSBox }.filter { $0.identifier?.rawValue.hasPrefix("ondemand-") == true }
check(demandBoxes.count == 2, "Japanese on-demand boxes missing")
for box in demandBoxes {
    let expected = box.identifier!.rawValue == "ondemand-584" ? NSSize(width: 131, height: 173) : NSSize(width: 433, height: 173)
    check(box.frame.size == expected && box.boxType == .custom && box.borderWidth == 1 && box.cornerRadius == 4, "Japanese box border/bounds changed")
    check(box.contentViewMargins == .zero, "Japanese box margins changed")
    check(box.contentView!.frame == box.bounds.insetBy(dx: 1, dy: 1), "Japanese box content geometry changed")
    print("ONDEMAND_BOX_EVIDENCE \(box.identifier!.rawValue) frame=\(box.frame) content=\(box.contentView!.frame) margins=\(box.contentViewMargins)"); fflush(stdout)
}
let toolbarOwner = ToolbarPanelController(window: nil)
var toolbarObjects: NSArray?
check(NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), bundle: nil).instantiate(withOwner: toolbarOwner, topLevelObjects: &toolbarObjects), "Japanese toolbar nib failed")
let toolbarWindow = toolbarOwner.window as! ToolBarNSWindow
check(toolbarWindow.contentView!.frame.size == NSSize(width: 1280, height: 5), "Japanese toolbar content dimensions changed")
check(toolbarWindow.contentMinSize == NSSize(width: 200, height: 5), "Japanese toolbar minimum dimensions changed")
check(toolbarWindow.styleMask.rawValue == 145, "Japanese toolbar current style mask changed")
print("PASS: Japanese toolbar actual window class, bounds, minimum size and style")
let forms = objects!.compactMap { $0 as? HorosFormView }
check(forms.count == 7, "expected seven forms (four raw, SUV, segmentation, calcium)")
for form in forms {
    check(form.numberOfRows > 0, "empty form")
    for index in 0..<form.numberOfRows {
        let field = form.cell(at: index)!
        check(form.cell(atRow: index, column: 0) === field, "index order changed")
        check(!field.title.isEmpty, "missing label")
        check(field.frame.width > 0 && field.frame.maxX <= form.bounds.maxX + 1, "field outside form")
        if index + 1 < form.numberOfRows { check(field.nextKeyView === form.cell(at: index + 1), "keyboard order changed") }
    }
    let frame = form.frame
    form.setFrameSize(NSSize(width: frame.width + 50, height: frame.height))
    check(form.cell(at: 0)!.frame.maxX <= form.bounds.maxX + 1, "field did not resize")
}
let suv = forms.first { $0.numberOfRows == 6 }!
check((0..<6).map { suv.cell(at: $0)!.tag } == [0, 1, 5, 2, 3, 4], "SUV cell tags/order changed")
check((0..<6).map { suv.cell(at: $0)!.isEditable } == [true, true, false, false, false, false], "SUV editability changed")
let dose = suv.cell(at: 1)!
dose.stringValue = "12.5"
check(dose.floatValue == 12.5, "dose stopped being editable numeric data")
check(dose.sendAction(dose.action, to: dose.target) && owner.actions == 1, "SUV action disconnected")
let date = Date(timeIntervalSince1970: 100_000)
for index in [3, 4] {
    let field = suv.cell(at: index)!
    check(field.formatter is DateFormatter, "date formatter lost")
    field.objectValue = date
    check((field.objectValue as? Date) == date, "date objectValue lost")
}
// Exercise real end-editing/Tab focus changes with the production NSDate
// subclass used by DCMPix, rather than only assigning a Foundation Date.
guard let loadedInjection = HorosSUVLoadedDate("20260930", "110000", "120000", true),
      let loadedAcquisition = HorosSUVLoadedDate("20260930", "110000", "120000", false) else {
    fatalError("production DCMPix SUV load lost valid DICOM dates/times")
}
let injection = loadedInjection as NSDate
let acquisition = loadedAcquisition as NSDate
let fractionalInjection = HorosSUVLoadedDate("20260930", "110000.125000", "120000.625000", true)!
let fractionalAcquisition = HorosSUVLoadedDate("20260930", "110000.125000", "120000.625000", false)!
check(abs(fractionalAcquisition.timeIntervalSince(fractionalInjection) - 3600.5) < 0.00001, "SUV loader discarded TM microseconds")
check(HorosSUVLoadedDate("20260930", "1100", "1200", true) == loadedInjection, "SUV loader changed partial TM minute precision")
check(HorosSUVLoadedDate("20260930", "invalid", "120000", true) == nil, "SUV loader accepted invalid TM")
// A wrong time gives a wrong decay correction: only a TM read whole is used.
check(HorosSUVLoadedDate("20260930", "11:00:00.5", "120000", true).map { $0.timeIntervalSince(loadedInjection) } == 0.5, "SUV loader rejected a valid colon TM with fraction")
for radio in ["246000", "116000", "999999", "11000", "110000.12a", "110000.1234567", "1100.5", "110000.125.5", "11x"] {
    check(HorosSUVLoadedDate("20260930", radio, "120000", true) == nil, "SUV loader accepted invalid TM \(radio)")
}
for day in ["2026093X", "20260931", "invalid"] {
    check(HorosSUVLoadedDate(day, "110000", "120000", false) == nil, "SUV loader accepted invalid DA \(day)")
}
suv.cell(at: 3)!.objectValue = injection
suv.cell(at: 4)!.objectValue = acquisition
check(!suv.cell(at: 3)!.stringValue.isEmpty && !suv.cell(at: 4)!.stringValue.isEmpty, "SUV adapter date fields display empty")
print("SUV_DATE_EVIDENCE injection=\(suv.cell(at: 3)!.stringValue) acquisition=\(suv.cell(at: 4)!.stringValue)"); fflush(stdout)
owner.suv = suv
owner.acquisition = acquisition as Date
check(HorosSUVDateInterval(suv.cell(at: 3)!.objectValue, acquisition as Date) == 3600, "valid SUV dates rejected before editing")
let editWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
editWindow.contentView!.addSubview(suv)
let actionsBeforeEditing = owner.actions
for value in ["71", "70", "71", "70"] {
    let weight = suv.cell(at: 0)!
    check(editWindow.makeFirstResponder(weight), "weight could not begin editing")
    weight.selectText(nil)
    let editor = weight.currentEditor()!
    editor.string = value
    check(editWindow.makeFirstResponder(dose), "Tab destination refused editing")
    check(weight.stringValue == value, "weight edit was not committed")
    check(HorosSUVDateInterval(suv.cell(at: 3)!.objectValue, acquisition as Date) == 3600, "Tab changed injection date/type")
    check(HorosSUVDateInterval(suv.cell(at: 4)!.objectValue, acquisition as Date) == 0, "Tab changed acquisition date/type")
}
check(editWindow.makeFirstResponder(nil), "editing did not end")
check(owner.actions > actionsBeforeEditing, "end-editing did not invoke the production SUV callback")
check(owner.suvAlerts == 0, "production SUV callback rejected valid dates on Tab")
suv.cell(at: 3)!.objectValue = acquisition
check(dose.sendAction(dose.action, to: dose.target) && owner.suvAlerts == 1, "equal injection/acquisition must be rejected")
suv.cell(at: 3)!.objectValue = Date(timeInterval: 60, since: acquisition as Date)
check(dose.sendAction(dose.action, to: dose.target) && owner.suvAlerts == 2, "injection after acquisition must be rejected")
suv.cell(at: 3)!.objectValue = injection
owner.suv = nil
print("PASS: production SUV NSDate adapter retains valid 11h/12h dates through repeated weight edits and Tab")
let calcium = forms.first { $0.numberOfRows == 7 }!
check(calcium.cell(at: 0)!.stringValue == owner.institution, "calcium binding disconnected")
let raw = forms.filter { $0.identifier?.rawValue.hasPrefix("raw-") == true }
check(raw.count == 4 && raw.reduce(0) { $0 + $1.numberOfRows } == 10, "raw forms changed")
for form in raw {
    for index in 0..<form.numberOfRows { check(form.cell(withTag: index) != nil, "raw tags changed") }
}
let segmentation = forms.first { $0.identifier?.rawValue == "segmentation" }!
let oldFormatter = segmentation.cell(at: 0)!.formatter
while segmentation.numberOfRows != 0 { segmentation.removeRow(0) }
for count in 1...3 {
    segmentation.addRow()
    segmentation.sizeToCells()
    let field = segmentation.cell(at: count - 1)!
    field.title = "Parameter \(count):"
    field.stringValue = "2.5"
    check(field.floatValue == 2.5 && field.formatter != nil && oldFormatter != nil, "dynamic field lost formatter")
    check(field.title == "Parameter \(count):", "dynamic label not updated")
    check(field.sendAction(field.action, to: field.target), "dynamic preview action lost")
}
let panel = objects!.compactMap { $0 as? HorosCLUTPanel }.first!
let parent = panel.parentWindow!
parent.setFrame(NSRect(x: 100, y: 500, width: 700, height: 300), display: false)
parent.orderFront(nil)
check(panel.state == 0 && panel.isClosed, "panel initially open")
panel.open(onEdge: .minY)
check(panel.state == 2 && panel.isOpen && owner.opened == 1, "open contract changed")
check(parent.childWindows?.count == 1 && panel.contentView?.window != nil, "panel not attached")
parent.setContentSize(NSSize(width: 800, height: 350))
check(panel.isOpen && panel.contentView?.window != nil, "viewer resize lost CLUT controls")
parent.contentView!.addSubview(suv)
check(suv.becomeFirstResponder() && parent.firstResponder is NSTextView, "form did not focus its first editable field")
let child = panel.contentView!.window!
child.setContentSize(NSSize(width: 410, height: 240))
panel.close()
check(panel.isClosed && owner.closed == 1 && parent.childWindows?.isEmpty != false, "close did not detach")
panel.open()
check(panel.contentView!.frame.size == NSSize(width: 410, height: 240) && owner.opened == 2, "panel size not retained")
child.performClose(nil)
check(panel.isClosed && owner.closed == 2, "close button did not synchronize state")
panel.open()
parent.close()
check(panel.isClosed && owner.closed == 3, "closing parent orphaned panel")
print("PASS: seven forms, tags/order/actions/date and value bindings, dynamic rows, resize/key loop, child panel lifecycle and size")
'''

with tempfile.TemporaryDirectory(prefix='horos-modern-controls-') as tmp:
    tmp = Path(tmp)
    xibs = [p for p in resources.rglob('*.xib') if 'customClass="HorosFormView"' in p.read_text() or 'customClass="HorosCLUTPanel"' in p.read_text()]
    assert len(xibs) == 72, f'expected 72 migrated xibs, got {len(xibs)}'
    box_xibs = [p for p in resources.rglob('*.xib') if 'boxType="custom"' in p.read_text() and 'cornerRadius="4"' in p.read_text()]
    base_box_xibs = [p for p in (root/'Preference Panes').glob('*/Base.lproj/*.xib') if 'boxType="custom"' in p.read_text() and 'cornerRadius="4"' in p.read_text()]
    annotation_xibs = [p for p in resources.glob('*.lproj/OSICustomImageAnnotations.xib')] + list((root/'Preference Panes/OSICustomImageAnnotations').glob('*.lproj/OSICustomImageAnnotations.xib'))
    assert len(annotation_xibs) == 10
    mpr_xibs = sorted(resources.glob("*.lproj/MPR.xib"))
    preferences_xibs = sorted(resources.glob("*.lproj/PreferencesWindow.xib"))
    toolbar_xib = resources / "ja-JP.lproj/ToolbarPanel.xib"
    ondemand_xib = root / "Preference Panes/OSIPACSOnDemandPreferencePane/ja-JP.lproj/OSIPACSOnDemand.xib"
    assert len(mpr_xibs) == len(preferences_xibs) == 10
    compiled_xibs = sorted(set(xibs + box_xibs + base_box_xibs + annotation_xibs + mpr_xibs + preferences_xibs + [toolbar_xib, ondemand_xib]))
    doc = E.parse(resources / 'en.lproj/Viewer.xib').getroot()
    for child in list(doc):
        if child.tag not in ('dependencies',): doc.remove(child)
    objects = E.SubElement(doc, 'objects')
    E.SubElement(objects, 'customObject', id='-2', customClass='Owner', userLabel="File's Owner")
    E.SubElement(objects, 'customObject', id='-1', customClass='FirstResponder')
    for name in ['MainMenu', 'Viewer', 'ITKSegmentation', 'CalciumScoring']:
        tree = E.parse(resources / f'en.lproj/{name}.xib')
        for form in tree.findall('.//customView[@customClass="HorosFormView"]'):
            form = copy.deepcopy(form)
            for node in form.iter():
                if 'id' in node.attrib: node.set('id', name+'-'+node.get('id'))
                for attribute in ('destination', 'firstItem', 'secondItem'):
                    if attribute in node.attrib and not node.get(attribute).startswith('-'):
                        node.set(attribute, name+'-'+node.get(attribute))
            form.set('identifier', 'raw-'+form.get('id') if name == 'MainMenu' else 'segmentation' if name == 'ITKSegmentation' else name)
            objects.append(form)
        if name == 'ITKSegmentation':
            defaults = copy.deepcopy(tree.find('.//userDefaultsController[@id="159"]'))
            defaults.set('id', name+'-159')
            objects.append(defaults)
    # Geometry-only extraction of the real annotation container. Its actions
    # and bindings are preserved in full resources; this owner tests geometry,
    # while source-localization tests check unchanged connection trees.
    annotations = E.parse(root/'Preference Panes/OSICustomImageAnnotations/Base.lproj/OSICustomImageAnnotations.xib')
    annotation_box = copy.deepcopy(annotations.find('.//box[@id="379"]'))
    annotation_box.set('identifier', 'annotation-container')
    for node in annotation_box.iter():
        for child in list(node):
            if child.tag == 'connections': node.remove(child)
    objects.append(annotation_box)
    # Actual MPR numeric control trees, excluding only model bindings in this
    # isolated owner; full resource connection trees stay untouched.
    mpr = E.parse(resources / 'en.lproj/MPR.xib')
    for path in mpr_xibs:
        localized = E.parse(path)
        for identifier in ('567', '569', '571', '573'):
            assert E.tostring(localized.find(f'.//numberFormatter[@id="{identifier}"]')) == E.tostring(mpr.find(f'.//numberFormatter[@id="{identifier}"]')), f'{path}: numeric formatter contract differs'
    for field in mpr.findall('.//textField'):
        formatter = field.find('./textFieldCell/numberFormatter')
        if formatter is None or formatter.get('id') not in ('567', '569', '571', '573'): continue
        field = copy.deepcopy(field)
        field.set('identifier', 'mpr-' + formatter.get('id'))
        for node in field.iter():
            if 'id' in node.attrib: node.set('id', 'mpr-' + node.get('id'))
            for child in list(node):
                if child.tag == 'connections': node.remove(child)
        objects.append(field)
    ondemand = E.parse(ondemand_xib)
    for identifier in ('584', '585'):
        box = copy.deepcopy(ondemand.find(f'.//box[@id="{identifier}"]'))
        box.set('identifier', 'ondemand-' + identifier)
        for node in box.iter():
            if 'id' in node.attrib: node.set('id', 'ondemand-' + node.get('id'))
            for child in list(node):
                if child.tag == 'connections': node.remove(child)
        objects.append(box)
    tree = E.parse(resources / 'en.lproj/VR.xib')
    adapter = copy.deepcopy(tree.find('.//customObject[@customClass="HorosCLUTPanel"]'))
    objects.append(adapter)
    content = E.SubElement(objects, 'customView', id='1029', customClass='CLUTOpacityView')
    E.SubElement(content, 'rect', key='frame', x='0', y='0', width='200', height='200')
    window = E.SubElement(objects, 'window', id='144', title='Synthetic parent', releasedWhenClosed='NO', visibleAtLaunch='NO')
    E.SubElement(window, 'windowStyleMask', key='styleMask', titled='YES', closable='YES', resizable='YES')
    E.SubElement(window, 'rect', key='contentRect', x='100', y='500', width='700', height='300')
    E.SubElement(window, 'view', key='contentView', id='probe-parent-content')
    E.ElementTree(doc).write(tmp / 'Probe.xib', encoding='utf-8', xml_declaration=True)
    subprocess.run(['xcrun', 'ibtool', '--minimum-deployment-target', '26.0', '--compile', str(tmp/'Probe.nib'), str(tmp/'Probe.xib')], check=True, capture_output=True)
    subprocess.run(['xcrun', 'ibtool', '--minimum-deployment-target', '26.0', '--compile', str(tmp/'Toolbar.nib'), str(toolbar_xib)], check=True, capture_output=True)
    (tmp/'main.swift').write_text(MAIN)
    (tmp/'DCM').symlink_to(root/'DCM Framework', target_is_directory=True)
    (tmp/'Dates.h').write_text('#import "DCMCalendarDate.h"\nNSTimeInterval HorosSUVDateInterval(id value, NSDate *acquisition);\nNSUInteger HorosSUVValidate(id form, NSDate *acquisition);\nNSDate *HorosSUVLoadedDate(NSString *date, NSString *radio, NSString *time, BOOL injection);\n')
    (tmp/'Dates.m').write_text(r'''
#import "Dates.h"
#import <AppKit/AppKit.h>
@interface NSObject (FormLookup)
- (id)cellAtIndex:(NSInteger)index;
@end
static NSUInteger alerts;
static NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *def, NSString *alt, NSString *other) { alerts++; return 1; }
@interface SUVPix : NSObject
@property(nonatomic, retain) NSDate *acquisitionTime;
@property(nonatomic, retain) NSDate *radiopharmaceuticalStartTime;
@property float radionuclideTotalDose;
@property float radionuclideTotalDoseCorrected;
- (void)computeTotalDoseCorrected;
@end
@implementation SUVPix
- (void)computeTotalDoseCorrected { self.radionuclideTotalDoseCorrected = self.radionuclideTotalDose; }
- (void)dealloc { [_acquisitionTime release]; [_radiopharmaceuticalStartTime release]; [super dealloc]; }
@end
@interface SUVImage : NSObject
@property(nonatomic, retain) SUVPix *curDCM;
@end
@implementation SUVImage
- (void)dealloc { [_curDCM release]; [super dealloc]; }
@end
@interface SUVDriver : NSObject {
@public id suvForm; SUVImage *imageView; NSInteger maxMovieIndex; NSArray *pixList[1];
}
@end
@implementation SUVDriver
''' + suv_update + r'''
@end
NSDate *HorosSUVLoadedDate(NSString *date, NSString *radio, NSString *time, BOOL injection) {
    NSString *preferredDate = [[DCMCalendarDate dicomDate:date] dateString];
    NSString *preferredTime = [[DCMCalendarDate dicomTime:time] timeString];
    NSString *radioTime = [[DCMCalendarDate dicomTime:radio] timeString];
    NSDate *radiopharmaceuticalStartTime = nil, *acquisitionTime = nil;
''' + suv_load_dates + r'''
    NSDate *result = injection ? radiopharmaceuticalStartTime : acquisitionTime;
    [(injection ? acquisitionTime : radiopharmaceuticalStartTime) release];
    return [result autorelease];
}
NSTimeInterval HorosSUVDateInterval(id value, NSDate *acquisition) { return -[value timeIntervalSinceDate:acquisition]; }
NSUInteger HorosSUVValidate(id form, NSDate *acquisition) {
    alerts = 0;
    SUVPix *pix = [SUVPix new];
    pix.acquisitionTime = acquisition;
    pix.radiopharmaceuticalStartTime = [[form cellAtIndex:3] objectValue];
    SUVDriver *driver = [SUVDriver new];
    driver->suvForm = form;
    driver->imageView = [SUVImage new];
    driver->imageView.curDCM = pix;
    driver->maxMovieIndex = 1;
    driver->pixList[0] = @[pix];
    [driver updateSUVValues:nil];
    [driver->imageView release];
    [driver release];
    [pix release];
    return alerts;
}
''')
    date_flags = ['-I', str(tmp), '-I', str(root/'DCM Framework')]
    date_objects = []
    for source in [root/'DCM Framework/DCMCalendarDate.m', tmp/'Dates.m']:
        obj = tmp/(source.stem+'.o')
        subprocess.run(['xcrun', 'clang', '-c', '-Werror', *date_flags, str(source), '-o', str(obj)], check=True)
        date_objects.append(str(obj))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-strict-concurrency=complete', '-warnings-as-errors',
                    *date_flags, '-import-objc-header', str(tmp/'Dates.h'),
                    str(root/'Horos/Sources/HorosModernControls.swift'), str(root/'Horos/Sources/ToolBarNSWindow.swift'),
                    str(root/'Horos/Sources/ToolbarPolicy.swift'), str(root/'Horos/Sources/ToolbarImage.swift'),
                    str(root/'Horos/Sources/ToolbarMenuBridge.swift'), str(tmp/'main.swift'),
                    *date_objects,
                    '-o', str(tmp/'probe')], check=True)
    home = tmp/'home'; home.mkdir()
    subprocess.run([str(tmp/'probe'), str(tmp/'Probe.nib'), str(tmp/'Toolbar.nib')], check=True, timeout=30, env=dict(os.environ, CFFIXED_USER_HOME=str(home)))
    for index, xib in enumerate(compiled_xibs):
        tree = E.parse(xib)
        assert not tree.findall('.//form') and not tree.findall('.//drawer'), xib
        result = subprocess.run(['xcrun', 'ibtool', '--errors', '--warnings', '--minimum-deployment-target', '26.0', '--compile', str(tmp / f'{index}.nib'), str(xib)], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        output = E.fromstring(result.stdout)
        values = list(output.find('dict'))
        warnings = next((values[i+1] for i in range(0, len(values), 2) if values[i].text == 'com.apple.ibtool.document.warnings'), None)
        assert warnings is None or len(warnings) == 0, f'{xib}: {result.stdout}'
    print(f'PASS: {len(compiled_xibs)} migrated controls/box xibs compiled without ibtool warnings')
