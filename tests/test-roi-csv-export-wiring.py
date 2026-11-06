#!/usr/bin/env python3
"""ROI > Export ROIs as CSV… and the ROI Manager's Export CSV… write the
series' ROIs through IsiXROI's format.

The format (header, numbers, quoting) is IsiXROI's ROICSVExport, tested in
the module (`swift test --package-path Modules --filter ROICSVExportTests`).
This checks what the module cannot see:

- the item is in the ROI menu right after "Save All ROIs of this Series...",
  sent to the study commands object of the nib, which validates it, and the
  JSON export the app adds goes after it;
- the ROI Manager's button runs the same export;
- the real ViewerROICSVExport.swift, compiled with IsiXROI over stand-ins of
  the viewer, its images and ROIs, reads one row per ROI of the time point on
  screen: an oval's area and pixel statistics, a Length's length, a
  rectangle on an image without pixel spacing in pixels, a text whose name
  needs quoting, a ROI shown on every image once, a length between images by
  its patient ends, no layer; and writes the points file beside the ROI file;
- the file is compiled by the app's target.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

failures = []
ACTION = 'roiExportCSV:'
TITLE = 'Export ROIs as CSV…'

# --- The menu item ----------------------------------------------------------
menu = ET.parse(root / 'Horos/Resources/en.lproj/MainMenu.xib').getroot()
roi_menu = next((m for m in menu.iter('menu') if m.get('id') == '1400'), None)
if roi_menu is None or roi_menu.get('title') != 'ROI':
    failures.append('the ROI menu (id 1400) is missing from MainMenu.xib')
else:
    items = roi_menu.findall('items/menuItem')
    actions = [[a.get('selector') for a in item.iter('action')] for item in items]
    if ['roiSaveSeries:'] not in actions:
        failures.append('the ROI menu has no "Save All ROIs of this Series..."')
    else:
        following = items[actions.index(['roiSaveSeries:']) + 1]
        action = next(following.iter('action'), None)
        if following.get('title') != TITLE or action is None or action.get('selector') != ACTION:
            failures.append(f'the item after "Save All ROIs of this Series..." is {following.get("title")!r}, not {TITLE!r}')
        elif action.get('target') != 'Vsc-cm-Obj':
            failures.append('the item is not sent to the study commands object of the nib')

commands = (root / 'Horos/Sources/ViewerStudyCommands.swift').read_text()
for needed in ('@objc(roiExportCSV:)', 'ViewerROICSVExport.runExportPanel(for: viewer)',
               'case #selector(roiExportCSV(_:)):', 'ViewerROICSVExport.hasROIs(',
               '@objc(exportROIsOfViewer:asCSVToURL:includingPoints:error:)'):
    if needed not in commands:
        failures.append(f'ViewerStudyCommands no longer has {needed}')

interchange = (root / 'Horos/Sources/ViewerROIInterchange.swift').read_text()
install = interchange[interchange.index('static func installMenuItems()'):]
install = install[:install.index('\n    }\n')]
if install.find('ViewerStudyCommands.roiExportCSV') < 0 or \
        install.find('ViewerStudyCommands.roiExportCSV') > install.find('ViewerController.roiSaveSeries'):
    failures.append('the JSON export item is not put after the CSV one')

manager = (root / 'Horos/Sources/ROIManagerController.swift').read_text()
if 'NSLocalizedString("Export CSV…"' not in manager or '#selector(saveCSV(_:))' not in manager:
    failures.append('the ROI Manager has no Export CSV… button')
save = manager[manager.index('@objc func saveCSV('):]
if 'ViewerROICSVExport.runExportPanel(for: viewer, sheetOn: window)' not in save[:save.index('\n    }\n')]:
    failures.append("the ROI Manager's button does not run the series export")

export = (root / 'Horos/Sources/ViewerROICSVExport.swift').read_text()
if re.search(r'Export ROIs\b(?! as)', export) or 'ExportROIs' in export:
    failures.append('the export takes a name of the plugin it replaces, which may still be loaded')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if project.count('ViewerROICSVExport.swift in Sources') != 2:
    failures.append('ViewerROICSVExport.swift is not in the Sources phase of the app')

# --- The values, through the real file ----------------------------------------
DOUBLES = r'''
import AppKit

public enum ToolMode: Int16 {
    case tMesure = 5, tROI = 6, tOval = 9, tOPolygon = 10, tCPolygon = 11, tAngle = 12, tText = 13
    case tArrow = 14, tPencil = 15, t2DPoint = 19, tPlain = 20, tLayerROI = 24
}

public class MyPoint: NSObject {
    public var point: NSPoint
    init(_ p: NSPoint) { point = p }
}

public class ROI: NSObject {
    public var type: ToolMode
    public var name: String!
    public var rect: NSRect = .zero
    public var stored: [NSPoint] = []
    public var points: NSMutableArray! { NSMutableArray(array: stored.map { MyPoint($0) }) }
    public var isAliased = false
    public var originalIndexForAlias: Int32 = 0
    public var pixelSpacingX: Double
    public var pixelSpacingY: Double
    /// What the image answers for the pixels inside.
    public var samples: [Float] = []
    public var areaCm2: Float = 0
    public var pixels2: Float = 0
    public var lengthCm: Float = 0
    init(_ type: ToolMode, _ name: String, spacing: Double = 0.5) {
        self.type = type; self.name = name; pixelSpacingX = spacing; pixelSpacingY = spacing
    }
    public func roiArea() -> Float { areaCm2 }
    public func ellipseArea() -> Float { pixels2 }
    public func plainArea() -> Float { pixels2 }
    public func area() -> Float { pixels2 }
    public func mesureLength(_ pixels: UnsafeMutablePointer<Float>!) -> Float { lengthCm }
}

public class HorosVolumeLengthROI: ROI {
    public var volumeLength: [AnyHashable: Any]!
    public var distanceMM: Double = 0
    public class func validPayload(_ payload: [AnyHashable: Any]!) -> Bool { payload["a"] != nil }
}

public class DicomSeries: NSObject {
    public var name: String! = "Abdomen, portal"
    public var seriesDICOMUID: String! = ""
    public var seriesInstanceUID: String! = "3 1.2.840.99"
}

public class DicomImage: NSObject {
    public var series: DicomSeries!
    public var instanceNumber: NSNumber!
    init(_ series: DicomSeries, _ number: Int) { self.series = series; instanceNumber = NSNumber(value: number) }
}

/// An axial image, 0.5 mm pixels, at z.
public class DCMPix: NSObject {
    let image: DicomImage
    let z: Float
    init(_ image: DicomImage, z: Float) { self.image = image; self.z = z }
    public func imageObj() -> DicomImage? { image }
    public func getROIValue(_ count: UnsafeMutablePointer<Int>?, _ roi: ROI?,
                            _ locations: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?) -> UnsafeMutablePointer<Float>! {
        let samples = roi?.samples ?? []
        count?.pointee = samples.count
        let values = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
        for (i, v) in samples.enumerated() { values[i] = v }
        return values
    }
    public func convertX(_ x: Float, pixY y: Float, toDICOMCoords d: UnsafeMutablePointer<Float>, pixelCenter: Bool) {
        d[0] = -100 + x * 0.5; d[1] = -50 + y * 0.5; d[2] = z
    }
}

public class DCMViewDouble: NSObject { public var flippedData = false }

public enum HorosAlertPanel {
    @discardableResult
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { 0 }
}

@MainActor public class ViewerController: NSObject {
    public var window: NSWindow? = nil
    var pixes = NSMutableArray()
    var files = NSMutableArray()
    var rois = NSMutableArray()
    let view = DCMViewDouble()
    public var horos_curMovieIndex: Int16 { 0 }
    public func horos_pixList(at i: Int) -> NSMutableArray? { pixes }
    public func horos_fileList(at i: Int) -> NSMutableArray? { files }
    public func horos_roiList(at i: Int) -> NSMutableArray? { rois }
    public var horos_imageView: DCMViewDouble? { view }
    public func fileList() -> NSMutableArray! { files }
}
'''

MAIN = r'''
import AppKit
import IsiXROI

var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let series = DicomSeries()
let images = (0..<3).map { DicomImage(series, 10 + $0) }
let viewer = ViewerController()
viewer.files = NSMutableArray(array: images)
viewer.pixes = NSMutableArray(array: images.enumerated().map { DCMPix($0.element, z: Float($0.offset) * 5) })

let oval = ROI(.tOval, "liver \"left\"")
oval.areaCm2 = 12.5; oval.samples = [10, 20, 30, 40]; oval.stored = [NSMakePoint(10, 20)]
let length = ROI(.tMesure, "span")
length.lengthCm = 4.25; length.stored = [NSMakePoint(0, 0), NSMakePoint(17, 0)]
let layer = ROI(.tLayerROI, "fusion")
let text = ROI(.tText, "a, b\nc")
text.rect = NSMakeRect(4, 6, 30, 14)
let square = ROI(.tROI, "no spacing", spacing: 0)
square.rect = NSMakeRect(1, 2, 3, 4); square.samples = [5]
let alias = ROI(.tCPolygon, "everywhere")
alias.isAliased = true; alias.originalIndexForAlias = 1; alias.areaCm2 = 2; alias.samples = [1, 3]
let between = HorosVolumeLengthROI(.tMesure, "3D")
between.originalIndexForAlias = 2; between.distanceMM = 25
between.volumeLength = ["a": [1.0, 2.0, 3.0], "b": [4.0, 6.0, 3.0], "id": "x"]
viewer.rois = NSMutableArray(array: [NSMutableArray(array: [oval, length, layer, alias]),
                                      NSMutableArray(array: [text, square, alias, between]),
                                      NSMutableArray(array: [alias, between])])

check(ViewerROICSVExport.hasROIs(viewer), "the series has ROIs")
let entries = ViewerROICSVExport.entries(of: viewer)
check(entries.map(\.name) == ["liver \"left\"", "span", "a, b\nc", "no spacing", "everywhere", "3D"], "the rows are \(entries.map(\.name))")
check(entries.map(\.image) == [1, 1, 2, 2, 2, 3] && entries.first?.instanceNumber == 10, "the images are \(entries.map(\.image))")
check(entries.allSatisfy { $0.seriesDescription == "Abdomen, portal" && $0.seriesInstanceUID == "1.2.840.99" }, "the series")
let o = entries[0]
check(o.area == 12.5 && o.unit == .centimetre && o.statistics?.mean == 25 && o.statistics?.minimum == 10 && o.statistics?.maximum == 40,
      "the oval: \(o)")
check(abs((o.statistics?.deviation ?? 0) - (500.0 / 3).squareRoot()) < 1e-4, "the oval's sample deviation")
check(o.points == [ROICSVExport.Point(x: 10, y: 20, patient: [-95, -40, 0])], "the oval's points \(o.points)")
check(entries[1].length == 4.25 && entries[1].area == nil && entries[1].statistics == nil, "the Length: \(entries[1])")
check(entries[2].points.first?.x == 4 && entries[2].points.first?.y == 6, "the text's anchor is its point")
check(entries[3].unit == .pixel && entries[3].area == 12 && entries[3].statistics?.mean == 5, "the rectangle without spacing: \(entries[3])")
check(entries[5].length == 2.5 && entries[5].unit == .centimetre && entries[5].points.map(\.patient) == [[1, 2, 3], [4, 6, 3]]
      && entries[5].points.allSatisfy { $0.x == nil }, "the length between images: \(entries[5])")

let url = work.appendingPathComponent("Abdomen ROIs.csv")
let pointsURL = try! ViewerROICSVExport.write(entries, to: url, points: true)
check(pointsURL?.lastPathComponent == "Abdomen ROIs points.csv", "the points go to \(String(describing: pointsURL))")
let csv = String(decoding: try! Data(contentsOf: url).dropFirst(3), as: UTF8.self)
check(csv.hasPrefix(ROICSVExport.csv([ROICSVExport.roiHeader]))
      && csv.contains("1,\"Abdomen, portal\",1.2.840.99,1,10,Oval,\"liver \"\"left\"\"\",12.5000,,cm,25.000,12.910,10.000,40.000\r\n"),
      "the ROI file:\n\(csv)")
let points = String(decoding: try! Data(contentsOf: pointsURL!).dropFirst(3), as: UTF8.self)
check(points.contains("6,3,3D,2,,,4.000,6.000,3.000\r\n"), "the points file:\n\(points)")
try! ViewerROICSVExport.write(entries, to: work.appendingPathComponent("only.csv"), points: false)
check(!FileManager.default.fileExists(atPath: work.appendingPathComponent("only points.csv").path), "a points file nobody asked for")

viewer.rois = NSMutableArray(array: [NSMutableArray(array: [layer]), NSMutableArray(), NSMutableArray()])
check(!ViewerROICSVExport.hasROIs(viewer) && ViewerROICSVExport.entries(of: viewer).isEmpty, "a series with a layer only has nothing to export")

for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("PASS: one row per ROI of the series, read from the ROIs and their images, and the points beside them") }
exit(failures.isEmpty ? 0 : 1)
'''


def extract(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n    }\n', start) + 7]


if not shutil.which('xcrun'):
    print('SKIP: xcrun is not available')
    sys.exit(2)

state = (root / 'Horos/Sources/ViewerController+ROIState.swift').read_text()
start = state.index('@MainActor struct ViewerROISlices {')
slices = state[start:state.index('\n}\n', start) + 3]
moved = ('@MainActor enum ViewerROIInterchange {\n'
         + extract(interchange, '    static func volumeLengthEndpoints(')
         + extract(interchange, '    static func seriesInstanceUID(of series: DicomSeries?)')
         + '}\n')

with tempfile.TemporaryDirectory(prefix='horos-roi-csv-') as tmp:
    tmp = Path(tmp)
    shutil.copy(root / 'Horos/Sources/ViewerROICSVExport.swift', tmp / 'ViewerROICSVExport.swift')
    (tmp / 'Doubles.swift').write_text(DOUBLES + slices + moved)
    (tmp / 'main.swift').write_text(MAIN)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                            *isix_modules.module_flags('IsiXROI', tmp / 'modules'),
                            str(tmp / 'ViewerROICSVExport.swift'), str(tmp / 'Doubles.swift'), str(tmp / 'main.swift'),
                            '-o', str(tmp / 'harness')], capture_output=True, text=True)
    if build.returncode != 0:
        failures.append('the harness does not compile:\n' + (build.stdout + build.stderr)[-4000:])
    else:
        warnings = [line for line in build.stderr.splitlines() if 'ViewerROICSVExport.swift' in line and 'warning:' in line]
        if warnings:
            failures.append('ViewerROICSVExport.swift compiles with warnings:\n' + '\n'.join(warnings))
        run = subprocess.run([str(tmp / 'harness'), str(tmp)], capture_output=True, text=True)
        print(run.stdout.strip())
        if run.returncode != 0:
            failures.append('the harness failed' + (': ' + run.stderr.strip()[-2000:] if run.stderr.strip() else ''))

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: ROI > Export ROIs as CSV… follows Save All ROIs of this Series..., the ROI Manager exports the same, and the app file reads the ROIs')
