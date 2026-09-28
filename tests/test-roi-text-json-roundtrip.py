#!/usr/bin/env python3
"""ROIs exported as JSON import back, text labels included (#780).

A text ROI keeps its anchor in rect.origin and has no points. The exporter
wrote only roi.points, so a text label left as `points: []` with no rect, and
the decoder, which wants points for every type but rectangle, oval, 2D point
and brush, refused the whole file: "ROI 'GSPS label' on image 1 has no points".
Had it got a point, the importer set it as the label's points and left the
rect at (0, 0).

Now the exporter writes the anchor as the text ROI's one point (the format
already documented text as "1 point"), the importer puts that point back in
rect.origin, and a text ROI written by the old exporter, which has no position
left, is skipped with a reason while the rest of the file imports.

The harness compiles the real ViewerController+ROIInterchange.swift,
ROIInterchange.swift, ROIAssociation.swift, ROIArchiveFormat.swift and
ROIIntersliceGeometry.swift with doubles for ViewerController, ROI, DCMPix and
MyPoint, puts the GSPS fixture's ROIs (a polyline, a 2D point and a text label)
and a Length on two images, exports, clears the ROIs and imports the file.
`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
sources = ['ViewerController+ROIInterchange.swift', 'ROIInterchange.swift', 'ROIAssociation.swift',
           'ROIArchiveFormat.swift', 'ROIIntersliceGeometry.swift']


def read(name):
    path = f'Horos/Sources/{name}'
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


# The .roi import decodes through the restricted unarchiver since #818.
try:
    read('RestrictedUnarchiver.swift')
    sources.append('RestrictedUnarchiver.swift')
except (subprocess.CalledProcessError, FileNotFoundError):
    pass


doubles = r'''
import AppKit

public enum ToolMode: Int16 {
    case tMesure = 5, tROI = 6, tOval = 9, tOPolygon = 10, tCPolygon = 11, tAngle = 12, tText = 13
    case tArrow = 14, tPencil = 15, t3Dpoint = 16, t2DPoint = 19, tPlain = 20, tLayerROI = 24
}

public struct RGBColor { public var red: UInt16 = 0; public var green: UInt16 = 0; public var blue: UInt16 = 0 }

extension Notification.Name { static let OsirixAddROI = Notification.Name("OsirixAddROINotification") }

let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException { static func perform(_ block: () -> Void) throws { block() } }

public class MyPoint: NSObject {
    public var point: NSPoint
    public var x: CGFloat { point.x }
    public var y: CGFloat { point.y }
    init(_ p: NSPoint) { point = p }
    public class func point(_ p: NSPoint) -> MyPoint { MyPoint(p) }
}

/// Only what ROI.m does that the interchange reads: rectangle, oval and 2D point
/// ignore setPoints: and answer points from their rect; a text ROI keeps its
/// anchor in rect.origin and its size follows the label.
public class ROI: NSObject {
    public var type: ToolMode
    public var name: String? { didSet { if type == .tText { rect.size = NSMakeSize(CGFloat((name ?? "").count) * 7, 14) } } }
    public var comments: String?
    public var rect: NSRect = .zero
    private var stored = NSMutableArray()
    public var points: NSMutableArray? {
        get {
            switch type {
            case .t2DPoint: return NSMutableArray(array: [MyPoint(rect.origin)])
            case .tROI: return NSMutableArray(array: [MyPoint(NSMakePoint(rect.minX, rect.minY)), MyPoint(NSMakePoint(rect.minX, rect.maxY)),
                                                      MyPoint(NSMakePoint(rect.maxX, rect.maxY)), MyPoint(NSMakePoint(rect.maxX, rect.minY))])
            default: return stored
            }
        }
        set { if type != .tROI && type != .tOval && type != .t2DPoint { stored = newValue ?? NSMutableArray() } }
    }
    public var thickness: Float = 1
    public var opacity: Float = 1
    public var rgbcolor = RGBColor()
    public var isSpline = false
    public var groupID: Double = 0
    public var textureBuffer: UnsafeMutablePointer<UInt8>? = nil
    public var textureWidth: Int32 = 0
    public var textureHeight: Int32 = 0
    public var textureUpLeftCornerX: Int32 = 0
    public var textureUpLeftCornerY: Int32 = 0
    public var originalIndexForAlias: Int = 0
    public var imageOrigin: NSPoint
    public var pixelSpacingX: Double
    public var pixelSpacingY: Double
    public var pix: DCMPix?

    public init!(type: ToolMode, _ sx: Float, _ sy: Float, _ origin: NSPoint) {
        self.type = type; pixelSpacingX = Double(sx); pixelSpacingY = Double(sy); imageOrigin = origin
    }
    public init!(texture: UnsafeMutablePointer<UInt8>, textWidth: Int32, textHeight: Int32, textName: String,
                 positionX: Int32, positionY: Int32, spacingX: Float, spacingY: Float, imageOrigin: NSPoint) {
        type = .tPlain; pixelSpacingX = Double(spacingX); pixelSpacingY = Double(spacingY); self.imageOrigin = imageOrigin
        super.init()
        name = textName
    }
    public func setOriginAndSpacing(_ sx: Float, _ sy: Float, _ origin: NSPoint) {
        pixelSpacingX = Double(sx); pixelSpacingY = Double(sy); imageOrigin = origin
    }
}

public class HorosVolumeLengthROI: ROI {
    public var volumeLength: [String: Any]?
    public var volumeIdentifier: String? { volumeLength?["id"] as? String }
    public class func validPayload(_ payload: [String: Any]) -> Bool { true }
}

public class DicomImage: NSObject {
    let sop: String
    let keys: [String: String]
    public var instanceNumber: NSNumber?
    init(sop: String, number: Int, keys: [String: String]) { self.sop = sop; instanceNumber = NSNumber(value: number); self.keys = keys }
    public func sopInstanceUID() -> String? { sop }
    public override func value(forKeyPath keyPath: String) -> Any? { keys[keyPath] }
}

/// An axial 64 x 64 image, 0.5 mm pixels, at z.
public class DCMPix: NSObject {
    let image: DicomImage
    public var frameNo = 0
    public var pwidth = 64
    public var pheight = 64
    public var pixelSpacingX = 0.5
    public var pixelSpacingY = 0.5
    public var sliceThickness = 5.0
    public var sliceLocation: Double
    public var originX = -16.0
    public var originY = -16.0
    public var originZ: Double
    public var frameofReferenceUID: String? = "1.2.3.4.for"
    init(sop: String, number: Int, z: Double) {
        image = DicomImage(sop: sop, number: number, keys: ["series.study.studyInstanceUID": "1.2.3.4.study",
                                                             "series.seriesDICOMUID": "1.2.3.4.series",
                                                             "series.modality": "CT", "series.name": "referenced CT"])
        sliceLocation = z; originZ = z
    }
    public func imageObj() -> DicomImage? { image }
    public func orientation(_ o: UnsafeMutablePointer<Float>) {
        for (i, v) in [Float(1), 0, 0, 0, 1, 0, 0, 0, 1].enumerated() { o[i] = v }
    }
    public func convertX(_ x: Float, pixY y: Float, toDICOMCoords d: UnsafeMutablePointer<Float>, pixelCenter: Bool) {
        d[0] = Float(originX) + x * Float(pixelSpacingX); d[1] = Float(originY) + y * Float(pixelSpacingY); d[2] = Float(originZ)
    }
    public class func originCorrected(accordingToOrientation pix: DCMPix) -> NSPoint { NSMakePoint(pix.originX, pix.originY) }
}

public class ImageViewDouble: NSObject {
    public var curImage: Int16 = 0
    public var needsDisplay = false
    public func roiSet(_ roi: ROI) {}
    public func setIndex(_ index: Int16) {}
}

public class ViewerController: NSObject {
    public var window: NSWindow? = nil
    var pixes: [NSMutableArray] = []
    var rois: [NSMutableArray] = []
    let view = ImageViewDouble()
    public func pixList(_ i: Int) -> NSMutableArray! { pixes[i] }
    public func roiList(_ i: Int) -> NSMutableArray! { rois[i] }
    public func maxMovieIndex() -> Int32 { Int32(pixes.count) }
    public func fileList() -> NSMutableArray! { NSMutableArray() }
    public func add(toUndoQueue what: String) {}
    public func roiSelectDeselectAll(_ sender: Any?) {}
    public func imageView() -> ImageViewDouble { view }
    public func add(_ roi: HorosVolumeLengthROI, movieIndex: Int) {}
}
'''

main = r'''
import AppKit

var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
func finish() -> Never {
    for failure in failures { print("FAIL: \(failure)") }
    exit(failures.isEmpty ? 0 : 1)
}

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let viewer = ViewerController()
let pixes = [DCMPix(sop: "1.2.3.4.1", number: 1, z: 0), DCMPix(sop: "1.2.3.4.2", number: 2, z: 5)]
viewer.pixes = [NSMutableArray(array: pixes)]

func make(_ type: ToolMode, _ name: String, on pix: DCMPix) -> ROI {
    let roi: ROI = ROI(type: type, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), DCMPix.originCorrected(accordingToOrientation: pix))
    roi.name = name
    roi.pix = pix
    return roi
}
func fill() {
    let line = make(.tOPolygon, "GSPS", on: pixes[0])
    line.points = NSMutableArray(array: [MyPoint(NSMakePoint(10, 10)), MyPoint(NSMakePoint(30, 20)), MyPoint(NSMakePoint(40, 12))])
    let point = make(.t2DPoint, "GSPS", on: pixes[0])
    point.rect = NSMakeRect(12, 14, 0, 0)
    let text = make(.tText, "GSPS label", on: pixes[0])
    text.rect.origin = NSMakePoint(40.5, 22.25)
    text.comments = "anchored"
    let length = make(.tMesure, "Length", on: pixes[1])
    length.points = NSMutableArray(array: [MyPoint(NSMakePoint(5, 5)), MyPoint(NSMakePoint(20, 5))])
    viewer.rois = [NSMutableArray(array: [NSMutableArray(array: [line, point, text]), NSMutableArray(array: [length])])]
}
func clear() { viewer.rois = [NSMutableArray(array: [NSMutableArray(), NSMutableArray()])] }
func slice(_ i: Int) -> [ROI] { (viewer.roiList(0).object(at: i) as! NSArray).map { $0 as! ROI } }
func points(_ roi: ROI?) -> [NSPoint] { (roi?.points ?? NSMutableArray()).map { ($0 as! MyPoint).point } }

// Export.
fill()
let exported = work.appendingPathComponent("rois780.json")
do { try viewer.exportROIInterchange(to: exported) } catch { failures.append("export refused the series: \(error)"); finish() }
let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as! [String: Any]
let records = (json["images"] as! [[String: Any]]).flatMap { $0["rois"] as! [[String: Any]] }
let textRecord = records.first { $0["type"] as? String == "text" }
let textPoints = textRecord?["points"] as? [[Double]] ?? []
check(textPoints == [[40.5, 22.25]], "the text ROI is exported with points \(textPoints), not its anchor [[40.5, 22.25]]")
check((textRecord?["pointsPatient"] as? [[Double]])?.first == [4.25, -4.875, 0], "the text ROI's patient point is not its anchor in millimetres")

// Import into the cleared series.
clear()
do {
    try viewer.importROIInterchange(fromPath: exported.path)
} catch {
    failures.append("import refused the exported file: \((error as NSError).localizedDescription)")
    finish()
}
let first = slice(0), second = slice(1)
check(first.map { $0.type } == [.tOPolygon, .t2DPoint, .tText], "image 1 holds \(first.map { $0.type.rawValue }), not polyline, 2D point and text")
check(second.map { $0.type } == [.tMesure], "image 2 holds \(second.map { $0.type.rawValue }), not the Length")
let text = first.first { $0.type == .tText }
check(text?.rect.origin == NSMakePoint(40.5, 22.25), "the text ROI is placed at \(String(describing: text?.rect.origin)), not its anchor (40.5, 22.25)")
check(points(text).isEmpty, "the text ROI got points \(points(text)); its anchor belongs in rect.origin")
check(text?.name == "GSPS label" && text?.comments == "anchored", "the text ROI lost its label or comments")
check(first.first { $0.type == .t2DPoint }?.rect.origin == NSMakePoint(12, 14), "the 2D point moved")
check(points(first.first { $0.type == .tOPolygon }) == [NSMakePoint(10, 10), NSMakePoint(30, 20), NSMakePoint(40, 12)], "the polyline changed")
check(points(second.first) == [NSMakePoint(5, 5), NSMakePoint(20, 5)], "the Length changed")

// A file written before the fix: the text ROI has no position left.
var legacy = json
legacy["images"] = (json["images"] as! [[String: Any]]).map { image -> [String: Any] in
    var image = image
    image["rois"] = (image["rois"] as! [[String: Any]]).map { roi -> [String: Any] in
        var roi = roi
        if roi["type"] as? String == "text" { roi["points"] = []; roi.removeValue(forKey: "pointsPatient") }
        return roi
    }
    return image
}
let legacyURL = work.appendingPathComponent("rois722.json")
try! JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
clear()
do {
    try viewer.importROIInterchange(fromPath: legacyURL.path)
    check(slice(0).map { $0.type } == [.tOPolygon, .t2DPoint] && slice(1).map { $0.type } == [.tMesure],
          "an old file without the text position imports \(slice(0).map { $0.type.rawValue }) + \(slice(1).map { $0.type.rawValue })")
    let decoded = try ROIInterchange.decode(Data(contentsOf: legacyURL))
    let skipped = decoded.responds(to: NSSelectorFromString("skippedROIs")) ? decoded.value(forKey: "skippedROIs") as? [String] ?? [] : []
    check(skipped.count == 1 && skipped[0].contains("GSPS label"), "the skipped text ROI is not reported: \(skipped)")
} catch {
    failures.append("an old file whose text ROI has no position is refused whole: \((error as NSError).localizedDescription)")
}

if failures.isEmpty {
    print("PASS: polyline, 2D point, text label and Length survive export and import; a positionless text label from an old file is skipped and reported")
}
finish()
'''

if not shutil.which('xcrun'):
    print('SKIP: xcrun is not available')
    sys.exit(2)

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    for name in sources:
        (tmp / name).write_bytes(read(name))
    (tmp / 'Doubles.swift').write_text(doubles)
    (tmp / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', *[str(tmp / n) for n in sources],
                            str(tmp / 'Doubles.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'harness')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stdout + build.stderr)
        print('FAIL: the harness does not compile')
        sys.exit(1)
    run = subprocess.run([str(tmp / 'harness'), str(tmp)], capture_output=True, text=True)
    print(run.stdout.strip())
    if run.returncode != 0:
        if run.stderr.strip():
            print(run.stderr.strip()[-2000:])
        sys.exit(1)
