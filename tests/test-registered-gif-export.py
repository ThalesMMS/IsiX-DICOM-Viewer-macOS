#!/usr/bin/env python3
"""The registered comparison animates, and the clipboard gets it.

Object level: a plan refuses an unregistered companion, a blend outside 0…1, a
frame duration outside its bounds and captures that belong to another
comparison or to a comparison that moved while it was being captured; the
frames keep the order and the blends asked for; the animation reads back with
the frame count, the durations and the loop the plan declared; and each decoded
frame equals the static capture it came from, pixel for pixel, at the capture's
own pixels, with every screen answering a backing scale of 1 and then of 2.

Nothing is written to disk: the GIF reaches the pasteboard as data.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
driver = r'''
import Foundation
import AppKit

// Every screen answers the backing scale the run was given, before AppKit
// first asks: the frames must not depend on it.
let backingScale = CGFloat(Double(CommandLine.arguments[1])!)
let answerScale: @convention(block) (AnyObject) -> CGFloat = { _ in backingScale }
method_setImplementation(class_getInstanceMethod(NSScreen.self, #selector(getter: NSScreen.backingScaleFactor))!,
                         imp_implementationWithBlock(answerScale))

func expect(_ ok: Bool, _ reason: String) { if !ok { FileHandle.standardError.write(Data(("FAIL: " + reason + "\n").utf8)); exit(1) } }

let base = "1.2.826.0.1.3680043.2.1125.1.BASE"
let frameOfReference = "1.2.826.0.1.3680043.2.1125.1.FOR"
let companion = "1.2.826.0.1.3680043.2.1125.1.FOLLOWUP"

func alignedSession() -> RegistrationSession {
    let session = RegistrationSession(baseSeriesInstanceUID: base, baseFrameOfReferenceUID: frameOfReference)
    session.addCompanion(seriesInstanceUID: companion, frameOfReferenceUID: frameOfReference, blend: 0.5)
    return session
}

// A comparison of series that are not registered is not a comparison.
let empty = RegistrationSession(baseSeriesInstanceUID: base, baseFrameOfReferenceUID: frameOfReference)
expect(!RegisteredGIF.plan(session: empty, companion: companion, blendStops: [0, 1], delaySeconds: 0.5).isUsable,
       "a session with no companion must refuse")
let unregistered = RegistrationSession(baseSeriesInstanceUID: base, baseFrameOfReferenceUID: frameOfReference)
unregistered.addCompanion(seriesInstanceUID: companion, frameOfReferenceUID: "OTHER-FRAME", blend: 0.5)
let unregisteredPlan = RegisteredGIF.plan(session: unregistered, companion: companion, blendStops: [0, 1], delaySeconds: 0.5)
expect(!unregisteredPlan.isUsable && unregisteredPlan.refusal.contains("not registered"),
       "an unregistered companion must refuse by name: \(unregisteredPlan.refusal)")

// Bounds.
let session = alignedSession()
expect(!RegisteredGIF.plan(session: session, companion: companion, blendStops: [], delaySeconds: 0.5).isUsable, "no frames")
expect(!RegisteredGIF.plan(session: session, companion: companion, blendStops: [0, 1.5], delaySeconds: 0.5).isUsable, "blend above 1")
expect(!RegisteredGIF.plan(session: session, companion: companion, blendStops: [-0.1, 1], delaySeconds: 0.5).isUsable, "blend below 0")
expect(!RegisteredGIF.plan(session: session, companion: companion, blendStops: [0, .nan], delaySeconds: 0.5).isUsable, "blend not a number")
expect(!RegisteredGIF.plan(session: session, companion: companion, blendStops: [0, 1], delaySeconds: 0.001).isUsable, "frame too short")
expect(!RegisteredGIF.plan(session: session, companion: companion, blendStops: [0, 1], delaySeconds: 60).isUsable, "frame too long")
expect(!RegisteredGIF.plan(session: session, companion: companion,
                           blendStops: Array(repeating: 0.5, count: RegisteredGIF.maximumFrames + 1),
                           delaySeconds: 0.5).isUsable, "more frames than allowed")

// The plan says what it will animate.
let stops = RegisteredGIF.rampStops(steps: 4)
expect(stops == [0, 1.0 / 3.0, 2.0 / 3.0, 1, 2.0 / 3.0, 1.0 / 3.0], "a ramp goes up and comes back: \(stops)")
expect(RegisteredGIF.blinkStops() == [0, 1], "a blink is the two ends")
let plan = RegisteredGIF.plan(session: session, companion: companion, blendStops: [0, 0.5, 1], delaySeconds: 0.25)
expect(plan.isUsable, "an aligned companion must plan: \(plan.refusal)")
expect(plan.blendValues == [0, 0.5, 1], "the blends keep their order: \(plan.blendValues)")
expect(plan.frameCount == 3 && abs(plan.totalDurationSeconds - 0.75) < 1e-9, "duration is the sum of the frames")
expect(plan.loops == 0, "a blink comparison loops forever")
expect(plan.labels[0] == "base" && plan.labels[2] == companion, "the ends are named: \(plan.labels)")
expect(plan.sessionKey == RegisteredGIF.sessionKey(session), "the plan carries its session")
expect(plan.registrationKey.contains("aligned") && plan.registrationKey.contains(companion),
       "the plan carries the registration it was made under: \(plan.registrationKey)")

// Captures from another comparison, or from one that moved, are refused.
let other = RegistrationSession(baseSeriesInstanceUID: "OTHER-BASE", baseFrameOfReferenceUID: frameOfReference)
expect(RegisteredGIF.refusalForApplying(plan, to: other).contains("another comparison"), "a plan is not portable between sessions")
expect(RegisteredGIF.refusalForApplying(plan, to: session).isEmpty, "its own session accepts it")
// Moving the blend is what the capture does; it is not a change of comparison.
session.setBlend(companion, blend: 0.9)
expect(RegisteredGIF.refusalForApplying(plan, to: session).isEmpty,
       "moving the blend is the capture itself, not a change of comparison")
// Re-registering or rejecting under it is.
session.reject(companion)
expect(RegisteredGIF.refusalForApplying(plan, to: session).contains("registration changed"),
       "a comparison re-registered mid-capture must refuse the captures")

// The captures have to be one size, all present, and not empty.
// A capture is a bitmap of so many pixels. lockFocus would draw at the
// screen's backing scale - 64x48 pixels on a Retina Mac - so the frames are
// drawn into bitmaps of exactly width x height pixels.
func frame(width: Int, height: Int, level: CGFloat, mark: NSRect) -> NSImage {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(deviceWhite: level, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(deviceWhite: level < 0.5 ? 1 : 0, alpha: 1).setFill()
    mark.fill()
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(bitmap)
    return image
}
let marks = [NSRect(x: 1, y: 1, width: 6, height: 6), NSRect(x: 9, y: 1, width: 6, height: 6), NSRect(x: 17, y: 1, width: 6, height: 6)]
let levels: [CGFloat] = [0.2, 0.6, 0.9]
let captures = (0..<3).map { frame(width: 32, height: 24, level: levels[$0], mark: marks[$0]) }

let fresh = alignedSession()
let usable = RegisteredGIF.plan(session: fresh, companion: companion, blendStops: [0, 0.5, 1], delaySeconds: 0.25)
expect(RegisteredGIF.refusalForImages(Array(captures.prefix(2)), plan: usable).contains("2 of 3"), "a missing capture is named")
expect(RegisteredGIF.refusalForImages(captures + [frame(width: 16, height: 24, level: 0.5, mark: marks[0])],
                                      plan: RegisteredGIF.plan(session: fresh, companion: companion,
                                                               blendStops: [0, 0.5, 1, 1], delaySeconds: 0.25))
        .contains("do not share one size"), "frames of two sizes are not one animation")
expect(RegisteredGIF.refusalForImages(captures, plan: usable).isEmpty, "three captures of one size are fine")

// The animation.
let result = RegisteredGIF.data(for: usable, images: captures)
expect(result.isUsable, "the animation was not written: \(result.refusal)")
let data = result.data!
expect(result.width == 32 && result.height == 24, "the animation keeps the capture size: \(result.width)×\(result.height)")
expect(RegisteredGIF.frameCount(in: data) == 3, "three frames in, three frames out")
let delays = RegisteredGIF.frameDelays(in: data)
expect(delays.count == 3 && delays.allSatisfy { abs($0 - 0.25) < 1e-6 }, "the durations survive: \(delays)")
expect(RegisteredGIF.loopCount(in: data) == 0, "the loop count survives")

// Each frame equals the static state it came from.
for index in 0..<3 {
    guard let decoded = RegisteredGIF.frameBitmap(in: data, at: index) else { expect(false, "frame \(index) missing"); exit(1) }
    let original = NSBitmapImageRep(cgImage: RegisteredGIF.cgImage(captures[index])!)
    expect(decoded.pixelsWide == original.pixelsWide && decoded.pixelsHigh == original.pixelsHigh,
           "frame \(index) changed size")
    var differences = 0
    for y in 0..<decoded.pixelsHigh {
        for x in 0..<decoded.pixelsWide {
            let a = decoded.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let b = original.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            if abs(a.redComponent - b.redComponent) > 1.0 / 255.0
                || abs(a.greenComponent - b.greenComponent) > 1.0 / 255.0
                || abs(a.blueComponent - b.blueComponent) > 1.0 / 255.0 { differences += 1 }
        }
    }
    expect(differences == 0, "frame \(index) is not the static capture: \(differences) pixels differ")
}
// And the frames are not all the same picture: the animation actually moves.
let first = RegisteredGIF.frameBitmap(in: data, at: 0)!.colorAt(x: 16, y: 12)!.usingColorSpace(.sRGB)!
let last = RegisteredGIF.frameBitmap(in: data, at: 2)!.colorAt(x: 16, y: 12)!.usingColorSpace(.sRGB)!
expect(abs(first.redComponent - last.redComponent) > 0.2, "the two ends of the blink look the same")

// The clipboard takes the data, and nothing else is left behind.
let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.horos.test.gif.\(UUID().uuidString)"))
expect(RegisteredGIF.copy(data, to: pasteboard), "the animation did not reach the clipboard")
let back = RegisteredGIF.data(on: pasteboard)
expect(back == data, "the clipboard does not hold the animation that was copied")
expect(RegisteredGIF.frameCount(in: back!) == 3, "the animation on the clipboard lost its frames")
expect(!RegisteredGIF.copy(Data(), to: pasteboard), "an empty animation must not be copied")
expect(!RegisteredGIF.copy(Data("not a gif".utf8), to: pasteboard), "something that is not an animation must not be copied")
pasteboard.releaseGlobally()

// A frame has the capture's own pixels on a screen of any scale: the viewer's
// capture on a Retina display is a bitmap of twice its size in points.
let retinaCapture = NSImage(size: NSSize(width: 16, height: 12))
retinaCapture.addRepresentation(frame(width: 32, height: 24, level: 0.6, mark: marks[1]).representations[0])
let retinaFrame = RegisteredGIF.cgImage(retinaCapture)
expect(retinaFrame?.width == 32 && retinaFrame?.height == 24,
       "a capture of 32x24 pixels in 16x12 points gave \(retinaFrame?.width ?? 0)x\(retinaFrame?.height ?? 0) at scale \(backingScale)")
let retinaGIF = RegisteredGIF.data(for: RegisteredGIF.plan(session: alignedSession(), companion: companion, blendStops: [0, 1],
                                                           delaySeconds: 0.25), images: [retinaCapture, retinaCapture])
expect(retinaGIF.width == 32 && retinaGIF.height == 24,
       "the animation of a capture of 32x24 pixels is \(retinaGIF.width)x\(retinaGIF.height) at scale \(backingScale)")
// An image without pixels of its own, a PDF page of 24x18 points, is drawn at one pixel a point.
let pdfData = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: 24, height: 18)
let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &mediaBox, nil)!
pdfContext.beginPDFPage(nil)
pdfContext.setFillColor(gray: 0.5, alpha: 1)
pdfContext.fill(CGRect(x: 2, y: 2, width: 10, height: 6))
pdfContext.endPDFPage()
pdfContext.closePDF()
let page = RegisteredGIF.cgImage(NSImage(data: pdfData as Data)!)
expect(page?.width == 24 && page?.height == 18,
       "a PDF page of 24x18 points gave \(page?.width ?? 0)x\(page?.height ?? 0) at scale \(backingScale)")

// It stands in for nothing.
expect(!RegisteredGIF.replacesFusedDICOMExport() && !RegisteredGIF.replacesMovieExport()
       && !RegisteredGIF.replacesFlythrough() && !RegisteredGIF.replacesDragFilePromises(),
       "this export replaces none of the existing ones")
expect(!RegisteredGIF.writesTemporaryFiles(), "the clipboard route writes no file")

print("PASS at backing scale \(backingScale): the comparison refuses unregistered, out-of-range and foreign captures; "
      + "the animation keeps the order, the blends, the durations and the loop; every frame equals its static capture, "
      + "at the capture's own pixels; and the clipboard holds the animation itself, with no file written")
'''

sources = ('RegisteredGIFExport.swift', 'LongitudinalRegistration.swift',
           'ROIInterchange.swift', 'ROIIntersliceGeometry.swift')
with tempfile.TemporaryDirectory(prefix='horos-registered-gif-') as folder:
    tmp = Path(folder)
    (tmp / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', *[str(root / 'Horos/Sources' / name) for name in sources],
                    str(tmp / 'main.swift'), '-o', str(tmp / 'test')], check=True)
    # On a display of scale 1 and on a Retina display.
    for scale in ('1', '2'):
        subprocess.run([str(tmp / 'test'), scale], check=True, timeout=120)

# The route to the clipboard must stay a data route.
source = (root / 'Horos/Sources/RegisteredGIFExport.swift').read_text()
failures = []
for forbidden in ('NSTemporaryDirectory', 'write(to:', 'createFile', 'FileManager'):
    if forbidden in source:
        failures.append('the animation must not reach the clipboard through a file: ' + forbidden)
if 'CGImageDestinationCreateWithData' not in source:
    failures.append('the animation must be built in memory')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if sum('RegisteredGIFExport.swift' in line for line in project.splitlines()) != 4:
    failures.append('RegisteredGIFExport.swift is not fully registered in the Xcode project')
if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)
print('the animation is built in memory and copied as data; no temporary file is part of the route')
