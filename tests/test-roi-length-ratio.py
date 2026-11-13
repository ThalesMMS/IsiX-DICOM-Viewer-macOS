#!/usr/bin/env python3
"""ROI > Ratio of Two Lengths divides the Length selected first by the other,
in a text ROI that follows them.

The first half reads the sources: the command is on the viewer, in the ROI
menu, in the two contextual menus and in the ROI Manager, enabled by what it
can do; the tie between the label and its Lengths is archived with the ROI
and kept by a copy; every language names the command.

The second half compiles the app's own ViewerLengthRatio.swift and
ViewerROICSVExport.swift against doubles of the viewer and of the ROI, with
the real module IsiXROI, and uses them as the app does: the pair the
selection names and its order, the label and where it goes, the label written
again when a Length changes (on its image or on another one), a copy of a
ratio dividing its own copies, the labels removed with a deleted Length, and
the rows of the CSV file.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

failures = []
TITLE = 'Ratio of Two Lengths'
ACTION = 'ViewerLengthRatio.menuItem()'


def source(name):
    return (root / 'Horos/Sources' / name).read_text()


# --- The command and where it is offered ------------------------------------
commands = source('ViewerStudyCommands.swift')
if '@IBAction @objc(ratioOfSelectedLengths:)' not in commands or 'ViewerLengthRatio.add(in: viewer)' not in commands:
    failures.append('the study commands have no -ratioOfSelectedLengths: that asks ViewerLengthRatio')
case = commands.find('case #selector(ratioOfSelectedLengths(_:)):')
if case < 0 or 'ViewerLengthRatio.canAdd(in: $0)' not in commands[case:case + 300]:
    failures.append('the menu item is not enabled by what the command can do')
if 'ratioOfSelectedLengths' in source('ViewerController+ROIGeometry.swift') + source('ViewerMenuValidation.swift'):
    failures.append('the command is on the viewer, which is not to grow with it: it is a study command')

ratio = source('ViewerLengthRatio.swift')
install = ratio[ratio.index('static func installMenuItem()'):]
install = install[:install.index('\n    }\n')]
for needed in ('ViewerStudyCommands.createPointsBetweenTwoPoints', 'item.keyEquivalent = "/"', '[.command, .option]',
               'anchor.target as? ViewerStudyCommands', 'commands = target'):
    if needed not in install:
        failures.append(f'the ROI menu item is not installed with {needed}')
if f'NSLocalizedString("{TITLE}"' not in ratio:
    failures.append('the command has no localized title')
if 'groupID' in ratio:
    failures.append('the label is tied by a group, which ungrouping breaks and which a Length has only one of')

lifecycle = source('ApplicationLifecycle.swift')
for needed in ('ViewerLengthRatio.installMenuItem()', 'ROIRatioLabels.start()'):
    if needed not in lifecycle:
        failures.append(f'the launch does not call {needed}')

item = ratio[ratio.index('static func menuItem()'):]
if 'item.target = commands' not in item[:item.index('\n    }\n')]:
    failures.append('an item of the command is not sent to the object that runs and enables it')

menus = source('ViewerContextualMenuBuilder.swift')
menu_roi = menus[menus.index('    func contextualMenu(for roi: ROI?'):menus.index('    func removeROI(of source:')]
if 'roi?.type == .tMesure {\n                menu.addItem(ViewerLengthRatio.menuItem())' not in menu_roi:
    failures.append('the contextual menu of a Length does not offer the ratio')
if ACTION not in menus[menus.index('/******************* Tools menu ***************************/'):
                       menus.index('/******************* WW/WL menu items **********************/')]:
    failures.append('the contextual menu of the image does not offer the ratio')

manager = source('ROIManagerController.swift')
if 'add(ViewerLengthRatio.title, #selector(addRatioFromMenu(_:)))' not in manager or 'selectionSequence' not in manager:
    failures.append('the ROI Manager does not offer the ratio of two selected rows, in the order they were selected')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if project.count('ViewerLengthRatio.swift in Sources') != 2:
    failures.append('ViewerLengthRatio.swift is not in the Sources phase of the app')

# --- The tie is archived, and kept by a copy --------------------------------
roi = source('ROI.swift')
for needed in ('final var ratioLink = ROIRatioLink.none', 'ratioLink = ROIRatioLink(archived: record.link as String?)',
               'record.link = ratioLink == .none ? nil : ratioLink.archived as NSString', 'c.ratioLink = ratioLink'):
    if needed not in roi:
        failures.append(f'ROI.swift no longer has: {needed}')
coder = (root / 'Modules/IsiXROI/Sources/ROIArchiveCoder.swift').read_text()
if 'public static let currentVersion = 16' not in coder:
    failures.append('the class version of the ROI archive changed: the released versions refuse every ROI of a version they do not know')

# --- Every language names the command ---------------------------------------
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    raw = catalog.read_bytes()
    text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8')
    found = re.search(r'^"%s" = "([^"]+)";$' % TITLE, text, re.M)
    language = catalog.parent.name
    if not found:
        failures.append(f'{language} does not name the command')
    elif language != 'en.lproj' and found.group(1) == TITLE:
        failures.append(f'{language} names the command in English')

# --- The command, through the real files ------------------------------------
DOUBLES = r'''
import AppKit
import IsiXROI

public enum ToolMode: Int16 {
    case tMesure = 5, tROI = 6, tOval = 9, tOPolygon = 10, tCPolygon = 11, tAngle = 12, tText = 13
    case tArrow = 14, tPencil = 15, t2DPoint = 19, tPlain = 20, tLayerROI = 24
}

extension Notification.Name {
    static let OsirixROIChange = Notification.Name("roiChange")
    static let OsirixRemoveROI = Notification.Name("removeROI")
    static let OsirixROISelected = Notification.Name("roiSelected")
    static let OsirixAddROI = Notification.Name("addROI")
    static let OsirixROIRemovedFromArray = Notification.Name("roiRemovedFromArray")
}

public class MyPoint: NSObject {
    public var point: NSPoint
    init(_ p: NSPoint) { point = p }
}

/// A ROI that announces its changes as the app's does: of its points, of its
/// name and of its mode.
public class ROI: NSObject {
    public var type: ToolMode
    public var name: String! { didSet { if name != oldValue { announce() } } }
    public var rect: NSRect = .zero
    public var stored: [NSPoint] = [] { didSet { announce() } }
    public var points: NSMutableArray! { NSMutableArray(array: stored.map { MyPoint($0) }) }
    public var isAliased = false
    public var originalIndexForAlias: Int32 = 0
    public var pixelSpacingX: Double
    public var pixelSpacingY: Double
    public var roImode = 0 { didSet { if roImode != oldValue { announce() } } }
    var ratioLink = ROIRatioLink.none
    public var pix: DCMPix?
    public var curView: DCMView?
    public var samples: [Float] = []

    init(_ type: ToolMode, _ name: String, spacing: Double = 0.5) {
        self.type = type; self.name = name; pixelSpacingX = spacing; pixelSpacingY = spacing
    }
    public init!(type: ToolMode, _ spacingX: Float, _ spacingY: Float, _ origin: NSPoint) {
        self.type = type; pixelSpacingX = Double(spacingX); pixelSpacingY = Double(spacingY)
    }
    func announce() { NotificationCenter.default.post(name: .OsirixROIChange, object: self) }
    /// A copy as the pasteboard and the undo make it: the tie goes with it.
    func duplicate() -> ROI {
        let copy = ROI(type, name, spacing: pixelSpacingX)
        copy.stored = stored; copy.rect = rect; copy.ratioLink = ratioLink
        return copy
    }

    public func roiArea() -> Float { 0 }
    public func ellipseArea() -> Float { 0 }
    public func plainArea() -> Float { 0 }
    public func area() -> Float { 0 }
    /// In cm, or in pixels without pixel spacing.
    public func mesureLength(_ pixels: UnsafeMutablePointer<Float>!) -> Float {
        let length = hypot(stored[1].x - stored[0].x, stored[1].y - stored[0].y)
        return Float(pixelSpacingX != 0 ? length * pixelSpacingX / 10 : length)
    }
}

public class HorosVolumeLengthROI: ROI {
    public var volumeLength: [AnyHashable: Any]!
    public var distanceMM: Double = 0
    public class func validPayload(_ payload: [AnyHashable: Any]!) -> Bool { payload["a"] != nil }
}

public class DicomSeries: NSObject {
    public var name: String! = "Head"
    public var seriesDICOMUID: String! = ""
    public var seriesInstanceUID: String! = "3 1.2.840.99"
}

public class DicomImage: NSObject {
    public var series: DicomSeries!
    public var instanceNumber: NSNumber!
    init(_ series: DicomSeries, _ number: Int) { self.series = series; instanceNumber = NSNumber(value: number) }
}

/// An axial image of 256 x 256, 0.5 mm pixels unless said otherwise.
public class DCMPix: NSObject {
    let image: DicomImage
    public var pixelSpacingX = 0.5, pixelSpacingY = 0.5
    public var pwidth = 256, pheight = 256
    init(_ image: DicomImage) { self.image = image }
    public func imageObj() -> DicomImage? { image }
    public class func originCorrected(accordingToOrientation pix: DCMPix!) -> NSPoint { .zero }
    public func getROIValue(_ count: UnsafeMutablePointer<Int>?, _ roi: ROI?,
                            _ locations: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?) -> UnsafeMutablePointer<Float>! {
        count?.pointee = 0
        return UnsafeMutablePointer<Float>.allocate(capacity: 1)
    }
    public func convertX(_ x: Float, pixY y: Float, toDICOMCoords d: UnsafeMutablePointer<Float>, pixelCenter: Bool) {
        d[0] = x * 0.5; d[1] = y * 0.5; d[2] = 0
    }
}

public class DCMView: NSObject {
    public var flippedData = false
    public var curImage = 0
    public var needsDisplay = false
    public func roiSet(_ roi: ROI!) { roi?.curView = self }
}

public enum HorosAlertPanel {
    @discardableResult
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { 0 }
}

/// The lengths as their labels write them, with one decimal unless changed.
enum LengthPresentation {
    static let changedNotification = "HorosLengthPresentationDidChange"
    nonisolated(unsafe) static var decimals = 1
    static func string(centimetres: Double) -> String { String(format: "%.*f cm", decimals, centimetres) }
    static func string(pixels: Double) -> String { String(format: "%.*f pix", decimals, pixels) }
}

func viewerArrayAdd(_ object: Any?, to array: NSMutableArray) { array.add(object!) }

@MainActor public class ViewerStudyCommands: NSObject {
    @objc func createPointsBetweenTwoPoints(_ sender: Any?) {}
    @objc func ratioOfSelectedLengths(_ sender: Any?) {}
}

@MainActor public class ViewerController: NSObject {
    static var displayed: [ViewerController] = []
    public var window: NSWindow? = nil
    var pixes = NSMutableArray()
    var files = NSMutableArray()
    var rois = NSMutableArray()
    let view = DCMView()
    var undoSteps = 0
    var closing = false
    public var horos_curMovieIndex: Int16 { 0 }
    public var horos_maxMovieIndex: Int16 { 1 }
    public func horos_pixList(at i: Int) -> NSMutableArray? { pixes }
    public func horos_fileList(at i: Int) -> NSMutableArray? { files }
    public func horos_roiList(at i: Int) -> NSMutableArray? { rois }
    public var horos_imageView: DCMView? { view }
    public func fileList() -> NSMutableArray! { files }
    public func add(toUndoQueue kind: String!) { undoSteps += 1 }
    public func windowWillClose() -> Bool { closing }
    public class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray(array: displayed) }
    func ratioOfSelectedLengths(_ sender: Any!) { ViewerLengthRatio.add(in: self) }
}
'''

MAIN = r'''
import AppKit
import IsiXROI

var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
/// One turn of the main queue: the labels of a deleted Length go then.
func turn() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

let series = DicomSeries()
let images = (0..<3).map { DicomImage(series, 10 + $0) }
let viewer = ViewerController()
viewer.files = NSMutableArray(array: images)
viewer.pixes = NSMutableArray(array: images.map { DCMPix($0) })
let lists = (0..<3).map { _ in NSMutableArray() }
viewer.rois = NSMutableArray(array: lists)
ViewerController.displayed = [viewer]
ROIRatioLabels.start()

func length(_ name: String, _ a: NSPoint, _ b: NSPoint, on image: Int, spacing: Double = 0.5) -> ROI {
    let roi = ROI(.tMesure, name, spacing: spacing)
    roi.stored = [a, b]
    lists[image].add(roi)
    return roi
}
func labels(on image: Int) -> [ROI] { (lists[image] as! [ROI]).filter { $0.type == .tText } }
func select(_ rois: ROI...) {
    for list in lists { for case let roi as ROI in list { roi.roImode = ROISelection.sleep } }
    for roi in rois { roi.roImode = ROISelection.selected }
}

// 30 mm over 100 mm, both on the first image.
let horns = length("frontal horns", NSMakePoint(40, 100), NSMakePoint(100, 100), on: 0)
let skull = length("skull", NSMakePoint(20, 120), NSMakePoint(220, 120), on: 0)
check(!ViewerLengthRatio.canAdd(in: viewer), "nothing selected names no pair")
select(horns)
check(!ViewerLengthRatio.canAdd(in: viewer), "one selected Length names no pair")

// --- The Length selected first is the numerator
select(horns, skull)
check(ViewerLengthRatio.canAdd(in: viewer), "two selected Lengths make a ratio")
check(ViewerLengthRatio.pair(in: viewer)?.numerator.roi === horns, "the first selected is the numerator")
viewer.ratioOfSelectedLengths(nil)
let evans = labels(on: 0).first
check(labels(on: 0).count == 1 && evans?.name == "3.0 cm / 10.0 cm = 0.30", "the label: \(labels(on: 0).map(\.name))")
check(viewer.undoSteps == 1, "the label is one undo step, not \(viewer.undoSteps)")
check(evans?.curView === viewer.view && evans?.pix === viewer.pixes[0] as? DCMPix && viewer.view.needsDisplay, "the label is set on its image")
check((evans?.rect.origin.y ?? 0) > 100 && (evans?.rect.origin.y ?? 999) < 256, "the label goes under the Length, on the image: \(String(describing: evans?.rect))")
let hornsID = horns.ratioLink.measureIdentifier, skullID = skull.ratioLink.measureIdentifier
check(hornsID != nil && skullID != nil && hornsID != skullID, "each Length has its identifier")
check(evans?.ratioLink == .label(numerator: hornsID ?? "", denominator: skullID ?? ""), "the label names its two Lengths: \(String(describing: evans?.ratioLink))")

// --- The same ratio again adds nothing
viewer.ratioOfSelectedLengths(nil)
check(labels(on: 0).count == 1 && viewer.undoSteps == 1, "the same ratio twice is one label")

// --- Selected the other way round, the other ratio
select(skull, horns)
check(ViewerLengthRatio.pair(in: viewer)?.numerator.roi === skull, "the first selected is the numerator, whatever the order of the list")
viewer.ratioOfSelectedLengths(nil)
let inverse = labels(on: 0).last
check(labels(on: 0).count == 2 && inverse?.name == "10.0 cm / 3.0 cm = 3.33", "the inverse: \(labels(on: 0).map(\.name))")
check(horns.ratioLink.measureIdentifier == hornsID && skull.ratioLink.measureIdentifier == skullID, "a Length keeps its identifier in a second ratio")

// --- A Length that changes changes its labels
horns.stored = [NSMakePoint(40, 100), NSMakePoint(120, 100)]
check(evans?.name == "4.0 cm / 10.0 cm = 0.40" && inverse?.name == "10.0 cm / 4.0 cm = 2.50", "after the numerator changed: \(labels(on: 0).map(\.name))")
skull.stored = [NSMakePoint(20, 120), NSMakePoint(180, 120)]
check(evans?.name == "4.0 cm / 8.0 cm = 0.50", "after the denominator changed: \(String(describing: evans?.name))")

// --- A denominator of no length: no ratio, and no new one
skull.stored = [NSMakePoint(20, 120), NSMakePoint(20, 120)]
check(evans?.name == "4.0 cm / 0.0 cm = \u{2013}", "a denominator of zero: \(String(describing: evans?.name))")
select(horns, skull)
check(!ViewerLengthRatio.canAdd(in: viewer), "a denominator of zero makes no ratio")
select(skull, horns)
check(ViewerLengthRatio.canAdd(in: viewer), "a numerator over a length does")
skull.stored = [NSMakePoint(20, 120), NSMakePoint(220, 120)]
check(evans?.name == "4.0 cm / 10.0 cm = 0.40", "the ratio is back with the length")

// --- Three selected, or two units, name no ratio
let third = length("third", NSMakePoint(0, 0), NSMakePoint(10, 0), on: 0)
select(horns, skull, third)
check(!ViewerLengthRatio.canAdd(in: viewer), "three selected Lengths name no pair")
let unscaled = length("pixels", NSMakePoint(0, 0), NSMakePoint(10, 0), on: 0, spacing: 0)
select(horns, unscaled)
check(!ViewerLengthRatio.canAdd(in: viewer), "centimetres over pixels are no ratio")
lists[0].remove(third); lists[0].remove(unscaled)

// --- Two images: the label goes on the one shown, and follows the other
let tendon = length("tendon", NSMakePoint(10, 10), NSMakePoint(10, 100), on: 2)
select(horns)                     // left selected on the first image
viewer.view.curImage = 2
tendon.roImode = ROISelection.selected
check(ViewerLengthRatio.pair(in: viewer)?.numerator.roi === horns && ViewerLengthRatio.pair(in: viewer)?.denominator.roi === tendon,
      "one on the image shown and one on another image are the pair, the first selected first")
viewer.ratioOfSelectedLengths(nil)
let between = labels(on: 2).first
check(labels(on: 2).count == 1 && labels(on: 0).count == 2 && between?.name == "4.0 cm / 4.5 cm = 0.89", "between images: \(labels(on: 2).map(\.name))")
check((between?.rect.origin.y ?? 0) > 100, "the label is beside the Length of the image shown: \(String(describing: between?.rect))")
horns.stored = [NSMakePoint(40, 100), NSMakePoint(130, 100)]
check(between?.name == "4.5 cm / 4.5 cm = 1.00" && evans?.name == "4.5 cm / 10.0 cm = 0.45", "a Length changed on another image: \(String(describing: between?.name))")

// --- A selection left on an image that is not shown does not count
viewer.view.curImage = 0
select(horns, skull)
tendon.roImode = ROISelection.selected
check(ViewerLengthRatio.pair(in: viewer)?.denominator.roi === skull, "two on the image shown are the pair")

// --- A ratio copied whole divides its copies
let copies = [horns, skull, evans!].map { $0.duplicate() }
for copy in copies { lists[1].add(copy) }
copies[0].stored = [NSMakePoint(40, 100), NSMakePoint(60, 100)]
check(copies[2].name == "1.0 cm / 10.0 cm = 0.10" && evans?.name == "4.5 cm / 10.0 cm = 0.45",
      "a copied ratio follows its copies: \(String(describing: copies[2].name)), \(String(describing: evans?.name))")

// --- The lengths are written as their Lengths write them
LengthPresentation.decimals = 2
NotificationCenter.default.post(name: Notification.Name(LengthPresentation.changedNotification), object: nil)
check(evans?.name == "4.50 cm / 10.00 cm = 0.45" && between?.name == "4.50 cm / 4.50 cm = 1.00", "with two decimals: \(String(describing: evans?.name))")
LengthPresentation.decimals = 1
NotificationCenter.default.post(name: Notification.Name(LengthPresentation.changedNotification), object: nil)

// --- The CSV file says what each label divides
let entries = ViewerROICSVExport.entries(of: viewer)
let names = entries.map(\.name)
func row(_ roi: ROI?) -> Int? { names.firstIndex(of: roi?.name ?? "?").map { $0 + 1 } }
let evansRow = entries[names.firstIndex(of: "4.5 cm / 10.0 cm = 0.45")!]
check(evansRow.ratio?.numerator == 1 && evansRow.ratio?.denominator == 2 && abs((evansRow.ratio?.value ?? 0) - 0.45) < 1e-6,
      "the row of the label: \(String(describing: evansRow.ratio))")
let betweenRow = entries[names.firstIndex(of: "4.5 cm / 4.5 cm = 1.00")!]
check(betweenRow.image == 3 && betweenRow.ratio?.numerator == 1 && betweenRow.ratio?.denominator == row(tendon),
      "the row of the label between images: \(String(describing: betweenRow.ratio))")
check(entries[0].ratio == nil && entries[1].ratio == nil, "a Length has no ratio of its own")
let csv = ROICSVExport.csv(ROICSVExport.roiRows(entries))
check(csv.contains(",Text,4.5 cm / 10.0 cm = 0.45,,,cm,,,,,0.4500,1,2\r\n"), "the file:\n\(csv)")

// --- A deleted Length takes its labels, and only them
select(skull, tendon)
viewer.view.curImage = 0
viewer.ratioOfSelectedLengths(nil)
check(labels(on: 0).count == 3, "skull over tendon: \(labels(on: 0).map(\.name))")
// A second ratio of one Length goes under the first, not on it.
let underSkull = labels(on: 0).filter { $0.name.hasPrefix("10.0 cm") }.map(\.rect.origin)
check(underSkull.count == 2 && underSkull[0].x == underSkull[1].x && underSkull[1].y - underSkull[0].y > 5,
      "two ratios of one Length are one under the other: \(underSkull)")
ROIEventEmitter.willRemove(horns)
lists[0].removeObject(identicalTo: horns)
ROIEventEmitter.removedFromList()
check(labels(on: 0).count == 3, "the labels are there until the Length has left")
turn()
check(labels(on: 0).map(\.name) == ["10.0 cm / 4.5 cm = 2.22"] && labels(on: 2).isEmpty,
      "the labels of the deleted Length are gone, the other stays: \(labels(on: 0).map(\.name)) \(labels(on: 2).map(\.name))")
check(labels(on: 1).count == 1, "the copy of the ratio keeps its label, which divides the copies")

// --- A label whose Lengths are not in its series keeps its text, and is left alone
let other = ViewerController()
other.files = NSMutableArray(array: [images[0]])
other.pixes = NSMutableArray(array: [DCMPix(images[0])])
let pasted = evans!.duplicate()
let otherList = NSMutableArray(array: [pasted])
other.rois = NSMutableArray(array: [otherList])
ViewerController.displayed = [viewer, other]
skull.stored = [NSMakePoint(20, 120), NSMakePoint(120, 120)]
check(pasted.name == "4.5 cm / 10.0 cm = 0.45", "a label pasted without its Lengths is a text: \(String(describing: pasted.name))")
check(labels(on: 0).map(\.name) == ["5.0 cm / 4.5 cm = 1.11"], "the label of the series follows: \(labels(on: 0).map(\.name))")
ROIEventEmitter.willRemove(skull)
lists[0].removeObject(identicalTo: skull)
turn()
check(labels(on: 0).isEmpty && otherList.count == 1, "a label is removed where its Length was, and only there: \(labels(on: 0).count) \(otherList.count)")

// --- A Length moved to another image is not deleted: its label stays
select(tendon)
viewer.view.curImage = 2
copies[1].roImode = ROISelection.sleep
let moving = length("moving", NSMakePoint(0, 50), NSMakePoint(100, 50), on: 2)
moving.roImode = ROISelection.selected
viewer.ratioOfSelectedLengths(nil)
check(labels(on: 2).map(\.name) == ["4.5 cm / 5.0 cm = 0.90"], "tendon over moving: \(labels(on: 2).map(\.name))")
ROIEventEmitter.willRemove(moving)
lists[2].removeObject(identicalTo: moving)
lists[1].add(moving)
turn()
check(labels(on: 2).count == 1, "the label of a Length moved to another image stays")

// --- A viewer that is closing is left alone
viewer.closing = true
copies[1].stored = [NSMakePoint(20, 120), NSMakePoint(40, 120)]
check(copies[2].name == "1.0 cm / 10.0 cm = 0.10", "a closing viewer's labels are not written")

for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("PASS: the ratio of the two selected Lengths, its label kept true to them, and its rows in the CSV file") }
exit(failures.isEmpty ? 0 : 1)
'''


def extract(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n    }\n', start) + 7]


def whole(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}\n', start) + 3]


if not shutil.which('xcrun'):
    print('SKIP: xcrun is not available')
    sys.exit(2)

if not failures:
    interchange = source('ViewerROIInterchange.swift')
    moved = ('@MainActor enum ViewerROIInterchange {\n'
             + extract(interchange, '    static func findItem(')
             + extract(interchange, '    static func volumeLengthEndpoints(')
             + extract(interchange, '    static func seriesInstanceUID(of series: DicomSeries?)')
             + '}\n')
    slices = whole(source('ViewerController+ROIState.swift'), '@MainActor struct ViewerROISlices {')
    shown = whole(source('ViewerController+ROI+Editing.swift'), '@MainActor struct ViewerShownROIs {')
    with tempfile.TemporaryDirectory(prefix='horos-roi-ratio-') as tmp:
        tmp = Path(tmp)
        for name in ('ViewerLengthRatio.swift', 'ViewerROICSVExport.swift', 'ROIEventEmitter.swift'):
            shutil.copy(root / 'Horos/Sources' / name, tmp / name)
        (tmp / 'Doubles.swift').write_text(DOUBLES + slices + shown + moved)
        (tmp / 'main.swift').write_text(MAIN)
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                                *isix_modules.module_flags('IsiXROI', tmp / 'modules'),
                                str(tmp / 'ViewerLengthRatio.swift'), str(tmp / 'ViewerROICSVExport.swift'),
                                str(tmp / 'ROIEventEmitter.swift'), str(tmp / 'Doubles.swift'), str(tmp / 'main.swift'),
                                '-o', str(tmp / 'harness')], capture_output=True, text=True)
        if build.returncode != 0:
            failures.append('the harness does not compile:\n' + (build.stdout + build.stderr)[-6000:])
        else:
            warnings = [line for line in build.stderr.splitlines() if 'ViewerLengthRatio.swift' in line and 'warning:' in line]
            if warnings:
                failures.append('ViewerLengthRatio.swift compiles with warnings:\n' + '\n'.join(warnings))
            run = subprocess.run([str(tmp / 'harness')], capture_output=True, text=True, timeout=120)
            print(run.stdout.strip())
            if run.returncode != 0:
                failures.append('the harness failed' + (': ' + run.stderr.strip()[-2000:] if run.stderr.strip() else ''))

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: ROI > Ratio of Two Lengths is offered where Lengths are, archived with the ROIs, and follows its Lengths')
