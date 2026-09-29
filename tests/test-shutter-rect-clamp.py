#!/usr/bin/env python3
"""The Shutter button clips the ROI to the image without moving it (#670).

-[ViewerController shutterOnOff:] turns the selected rectangular ROI into the
image's shutter and clips the rectangle to the image. The top-edge clip
corrected the wrong axis: a ROI past the top edge had its height reduced and
its x set to 0, which moved the shutter to the left edge.

The four clipping lines are compiled here from the source, in a stand-in
image, and run on rectangles inside the image and past each edge and corner;
each result must be the rectangle intersected with the image.

-shutterOnOff: is Swift since #832 (ViewerController+Toolbar.swift): the four
lines are taken from that method and compiled with xcrun swiftc, as they were
with clang, with the same rectangles.

A ROI wholly past the right or bottom edge (or the left or top one) left a
shutter of negative width or height (#865): the clipped rectangle must be
empty there, never negative, and such a ROI must not become the shutter: the
method checks it against the current image before deleting the ROI.

Two more defects (#881), checked by compiling the whole Swift method against
stand-in viewer, images and ROIs: any selected ROI (an oval, a polygon) became
the shutter, though the alert asks for a rectangular one; and the rectangle was
clipped in place from image to image, so in a series with images of different
sizes a smaller image shrank the shutter of every image after it. Only a
rectangular ROI may become the shutter, and each image must get the ROI clipped
to itself.

`<git revision>` as an optional argument reads the source from that revision,
the negative control; a revision older than #832 has the method in
ViewerController.m and its lines are compiled with clang, as before.
"""
from pathlib import Path
import json
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]


def read(path):
    if len(sys.argv) > 1:
        shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return shown.stdout.decode('utf-8', 'replace') if shown.returncode == 0 else None
    return (root / path).read_bytes().decode('utf-8', 'replace') if (root / path).is_file() else None


WIDTH, HEIGHT = 200, 150
CASES = [(40, 30, 100, 80), (-20, 30, 100, 80), (40, -25, 100, 80), (150, 30, 100, 80), (40, 120, 100, 80),
         (-20, -25, 100, 80), (150, 120, 100, 80), (-10, -10, 300, 300),
         # Wholly past the right, bottom, left and top edges, and a corner (#865).
         (250, 30, 100, 80), (40, 170, 100, 80), (-150, 30, 100, 80), (40, -100, 100, 80), (230, 160, 20, 20)]

OBJC_HARNESS = r'''
#import <Foundation/Foundation.h>
@interface Image : NSObject
@property long pwidth, pheight;
@end
@implementation Image
@end
int main() { @autoreleasepool {
    Image *p = [Image new]; p.pwidth = WIDTH; p.pheight = HEIGHT;
    NSMutableArray *out = [NSMutableArray array];
    double cases[][4] = { CASES };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        NSRect shutterRect = NSMakeRect(cases[i][0], cases[i][1], cases[i][2], cases[i][3]);
        LINES
        [out addObject:@[@(shutterRect.origin.x), @(shutterRect.origin.y), @(shutterRect.size.width), @(shutterRect.size.height)]];
    }
    printf("%s\n", [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:out options:0 error:nil] encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
'''

swift = read('Horos/Sources/ViewerController+Toolbar.swift')
if swift is not None:
    a = swift.index('@objc(shutterOnOff:)')
    action = swift[a:swift.index('@objc(resetCLUT:)', a)]
    start = action.index('//shutterRect inside frame?')
    # Since #865 the lines are a function of the method, which returns the rectangle.
    end = action.find('return shutterRect', start)
    lines = action[start:end if end >= 0 else action.index('p.shutterRect = shutterRect', start)]
    program_name, harness = 'clamp.swift', r'''
import Foundation
final class Image: NSObject {
    var pwidth = 0, pheight = 0
}
let p = Image(); p.pwidth = WIDTH; p.pheight = HEIGHT
var out: [[Double]] = []
let cases: [[Double]] = [CASES]
for c in cases {
    var shutterRect = NSMakeRect(CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2]), CGFloat(c[3]))
    LINES
    out.append([Double(shutterRect.origin.x), Double(shutterRect.origin.y), Double(shutterRect.size.width), Double(shutterRect.size.height)])
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
'''.replace('LINES', lines).replace('WIDTH', str(WIDTH)).replace('HEIGHT', str(HEIGHT)) \
       .replace('CASES', ', '.join('[%d, %d, %d, %d]' % c for c in CASES))
    build = ['xcrun', 'swiftc']
else:
    source = read('Horos/Sources/ViewerController.m')
    action = source[source.index('- (IBAction) shutterOnOff:(id) sender'):]
    start = action.index('//shutterRect inside frame?')
    lines = action[start:action.index('p.shutterRect = shutterRect;', start)]
    program_name, harness = 'clamp.m', OBJC_HARNESS.replace('LINES', lines).replace('WIDTH', str(WIDTH)) \
        .replace('HEIGHT', str(HEIGHT)).replace('CASES', ', '.join('{%d, %d, %d, %d}' % c for c in CASES))
    build = ['xcrun', 'clang', '-fobjc-arc', '-x', 'objective-c', '-framework', 'Foundation']

with tempfile.TemporaryDirectory() as work:
    program = Path(work) / program_name
    program.write_text(harness)
    binary = Path(work) / 'clamp'
    built = subprocess.run(build + [str(program), '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not build:\n' + built.stderr[-3000:])
    results = json.loads(subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout)

failures = []
for (x, y, w, h), got in zip(CASES, results):
    x0, y0, x1, y1 = max(0, x), max(0, y), min(WIDTH, x + w), min(HEIGHT, y + h)
    expected = [x0, y0, max(0, x1 - x0), max(0, y1 - y0)]
    if [round(v, 6) for v in got] != expected:
        failures.append('ROI (%d, %d, %d, %d): shutter %s, the ROI clipped to the image is %s' % (x, y, w, h, got, expected))

# A ROI that clips to nothing on the current image is not deleted and does not
# become the shutter (#865): the check comes before -deleteROI:.
if swift is not None:
    guard = action.find('if inside.size.width <= 0 || inside.size.height <= 0 { selectedROI = nil }')
    delete = action.find('self.delete(selectedROI)')
    if guard < 0 or delete < 0 or guard > delete:
        failures.append('a ROI wholly outside the current image is deleted and becomes the shutter')


METHOD = r'''
import AppKit

func check(_ c: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !c() { fputs("FAIL: \(message) (line \(line))\n", stderr); exit(1) }
}
enum ToolMode { case tROI, tOval, tCPolygon }
let ROI_sleep = 0, ROI_drawing = 1, ROI_selected = 2, ROI_selectedModify = 3
final class ROI: NSObject {
    let type: ToolMode, roImode: Int, rect: NSRect
    init(_ type: ToolMode, _ mode: Int, _ rect: NSRect) { self.type = type; roImode = mode; self.rect = rect }
}
final class DCMPix: NSObject {
    let pwidth: Int, pheight: Int
    var shutterRect = NSRect.zero, shutterEnabled = false
    var shutterPolygonal: NSArray? = nil
    init(_ w: Int, _ h: Int) { pwidth = w; pheight = h }
}
final class ImageView { var curImage: Int16 = 0; var dcmPixList: NSMutableArray? = nil; func setIndex(_ i: Int16) {} }
final class Button { var state: NSControl.StateValue = .off }
var alerts = 0
enum HorosAlertPanel {
    @discardableResult static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
func objcObject(_ o: Any?, _ key: String) -> Any? { return nil }
final class ViewerController: NSObject {
    var horos_shutterOnOff: Button? = Button()
    var horos_imageView: ImageView? = ImageView()
    var horos_curMovieIndex: Int16 = 0
    var rois = NSMutableArray()
    var deleted: [ROI] = []
    init(_ images: [DCMPix], _ rois: [ROI]) {
        horos_imageView?.dcmPixList = NSMutableArray(array: images)
        self.rois = NSMutableArray(array: images.indices.map { $0 == 0 ? NSMutableArray(array: rois) : NSMutableArray() })
    }
    func horos_roiList(at i: Int) -> NSMutableArray? { return rois }
    func delete(_ roi: ROI!) { deleted.append(roi); (rois.object(at: 0) as! NSMutableArray).remove(roi!) }
    var images: [DCMPix] { return horos_imageView!.dcmPixList as! [DCMPix] }
}
extension ViewerController {
METHOD
}

// Images of different sizes: each gets the ROI clipped to itself (#881).
let rect = NSMakeRect(40, 30, 150, 100), square = ROI(.tROI, ROI_selected, rect)
let series = ViewerController([DCMPix(200, 150), DCMPix(100, 80), DCMPix(200, 150)], [square])
series.horos_shutterOnOff?.state = .on
series.shutterOnOff(nil)
check(series.deleted == [square], "the rectangular ROI is not turned into the shutter")
let expected = [NSMakeRect(40, 30, 150, 100), NSMakeRect(40, 30, 60, 50), NSMakeRect(40, 30, 150, 100)]
for (i, p) in series.images.enumerated() {
    check(p.shutterEnabled, "image \(i) has no shutter")
    check(p.shutterRect == expected[i], "image \(i) (\(p.pwidth) x \(p.pheight)): shutter \(p.shutterRect), the ROI clipped to it is \(expected[i])")
}

// A selected oval or polygon is no shutter: it stays, and the alert answers.
for type in [ToolMode.tOval, .tCPolygon] {
    alerts = 0
    let shape = ROI(type, ROI_selected, rect), viewer = ViewerController([DCMPix(200, 150)], [shape])
    viewer.horos_shutterOnOff?.state = .on
    viewer.shutterOnOff(nil)
    check(viewer.deleted.isEmpty, "a selected \(type) ROI is deleted and becomes the shutter")
    check(viewer.images.allSatisfy { !$0.shutterEnabled } && viewer.horos_shutterOnOff?.state == .off && alerts == 1,
          "a selected \(type) ROI does not end in the alert")
}

// A selected oval before a selected rectangle: the rectangle is the shutter.
let oval = ROI(.tOval, ROI_selected, NSMakeRect(0, 0, 10, 10)), second = ROI(.tROI, ROI_selectedModify, rect)
let mixed = ViewerController([DCMPix(200, 150)], [oval, second])
mixed.horos_shutterOnOff?.state = .on
mixed.shutterOnOff(nil)
check(mixed.deleted == [second] && mixed.images[0].shutterRect == rect, "the selected rectangle after an oval is not the shutter")
print("ok")
'''

if swift is not None:
    body = action[action.index('    func shutterOnOff('):]
    body = body[:body.rindex('\n    }\n') + 7]
    program = METHOD.replace('METHOD', body)
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / 'shutter.swift'
        path.write_text(program)
        binary = Path(work) / 'shutter'
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(path), '-o', str(binary)], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the shutterOnOff: harness does not build:\n' + built.stderr[-4000:])
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        if ran.returncode:
            failures.append(next((line for line in ran.stderr.splitlines() if 'FAIL' in line),
                                 'the shutterOnOff: harness exited with %d' % ran.returncode).replace('FAIL: ', ''))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: the Shutter button clips the ROI to the image without moving it (#670), never to a negative size (#865), '
      'takes only a rectangular ROI and clips it to each image (#881)')
