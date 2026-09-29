#!/usr/bin/env python3
"""Fused PET/CT orthogonal-MPR export has distinct pixels and geometry per slice.

The series path used to capture GL_FRONT after NSDisableScreenUpdates, so every
frame of a fusion export was the first image. Isolated CT/PET walk the buffer
in memory and therefore already change. A production change that went back to
that screen capture, mixed two slices into one digest, or copied the first
Image Position onto the rest would fail here.

The arithmetic is the fixture in tools/generate-fusion-window-fixture.py: a
registered 32×32 CT/PT pair whose value at (x, y, z) is x+2y+3z and
500+3x+y+5z. Windowing is the fixture WL/WW. Alignment is checked by sampling a
PET volume that is shifted four millimetres along X: the overlay at a CT pixel
is the PET sample whose patient coordinate matches, not the PET sample with
the same index.

The series exports of both orthogonal viewers walk the slices through
OrthogonalFusionSliceExport.sliceIndices, whose step is at least 1, and their
image count divides by that step: with an interval of 0 the former loop never
ended (#859). With none of the window's views as the key view there is no
series and -setCurrentPosition: leaves the fields; closing the PET viewer
closes the PET-CT window; the first reslice of the fused row keeps the fusion
factor its views hold.

#888: the key view is taken only when the first responder is one of the
orthogonal views (a window or a control raised); a series whose "From" is after
its "To" takes both ends, as the 2D viewer does (10...1 took 8 images); the
"%d images" count is the number of slices the loop walks (1...10 by 3 said 3
and exported 4); the x view walks the rows of the original slices and the y
view their columns, in the bounds of the sheet, the current position and the
PET-CT JPEG series; cancelling the three-modality PET-CT series stops the three;
each slice of the orthogonal MPR series enables screen updates once.

#907: flippedData reverses the order of the slices, so -setCurrentPosition: of
the x and y views no longer mirrors the row or column of the cross; the PET-CT
JPEG series opens its first image (name.1.jpg) with OPENVIEWER, not the name of
the panel, which it never writes; the "From", "To" and interval fields keep the
minimum of their sliders too (0 and negative values passed, and "From" 0
walked slice -1).

#910: the current position of the original view is the row of the x view that
the series export moves the cross to (the former flippedData branch gave
max - (curImage + 1), "From" 0 on the last image, which walked slice -1); the
"%d images" count reads the sliders the export reads, not the text fields, where
an empty field counted as 0 while the export kept 1.

#911: moving "From" or "To" shows the row, slice or column the export walks for
that 1-based value (value - 1, at the centre of the pixel as the export moves
the cross), not the next one; the orthogonal MPR moves the cross of the view it
reslices from, as the PET-CT does, so the current position reads it back; typing
in a field of the sheet recounts "%d images".

#921: the bounds of the sheet and the count come from one -exportSeriesLength,
and without a key view of the window the count is 0
(tests/test-orthogonal-export-sheet.py checks the rest of #921).
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []

# OrthogonalMPRPETCTViewer is Swift since #826.
source = sources.source_text('OrthogonalMPRPETCTViewer')
export_at = source.find('func exportDICOMFileInt(_ screenCapture: Bool, view curView: DCMView!)')
end_at = source.find('func endExportDICOMFileSettings(', export_at)
export_body = source[export_at:end_at] if export_at >= 0 else ''
if not export_body:
    failures.append('PET/CT orthogonal export of a named view is gone')
else:
    for wanted, why in (
        ('OrthogonalFusionSliceExport.slice(', 'fusion series still goes through the OpenGL front buffer'),
        ('slice(fromPrimary:', 'nothing builds a fused frame from the two layers in memory'),
        ('curView?.blending != nil', 'the fusion path does not look at the PET overlay'),
        ('pixelRGB', 'the fused RGB is never given to the DICOM writer'),
        ('setPosition(', 'Image Position (Patient) is not taken from the fused slice'),
        ('setSlicePosition(', 'Slice Location is not taken from the fused slice'),
        ('setOrientation(', 'Image Orientation (Patient) is not taken from the fused slice'),
    ):
        if wanted not in export_body:
            failures.append('%s (%s missing)' % (why, wanted))
    start = export_body.find('curView?.blending != nil')
    helper = export_body.find('OrthogonalFusionSliceExport.slice(', start)
    raw = export_body.find('getRawPixelsWidth(', start)
    if helper < 0:
        failures.append('the blending branch never calls the fusion helper')
    elif 0 <= raw < helper:
        failures.append('the blending branch still captures pixels before the fusion helper runs')

series_at = source.find('func endExportDICOMFileSettings(')
if series_at < 0:
    failures.append('the PET/CT series export action is gone')
else:
    series = source[series_at:source.find('func exportDICOMFile(', series_at)]
    if 'exportDICOMFileInt(false' not in series:
        failures.append('series export still forces screen capture of every frame')

# The defects #826 kept in translation (#859).
if 'if let primary = primary' not in export_body:
    failures.append('the fused frame is built without a primary layer (a view with no pixels)')


def method(text, signature, end_marker='\n    }\n'):
    """The body of the method that `signature` starts, up to its closing brace."""
    start = text.find(signature)
    if start < 0:
        return ''
    return text[start:text.find(end_marker, start) + len(end_marker)]


mpr_source = sources.source_text('OrthogonalMPRViewer')
controller_source = sources.source_text('OrthogonalMPRPETCTController')
for name, text in (('OrthogonalMPRViewer', mpr_source), ('OrthogonalMPRPETCTViewer', source)):
    start = text.find('func endExportDICOMFileSettings(')
    series = text[start:text.find('func exportDICOMFile(', start)] if start >= 0 else ''
    if 'OrthogonalFusionSliceExport.seriesIndices(from: Int(dcmFrom?.intValue ?? 0),' not in series:
        failures.append('%s: the series export does not walk the slices of the sheet through seriesIndices' % name)
    if 'i += interval' in series or 'cDiv(to - from, interval)' in series:
        failures.append('%s: the series export still steps or counts by the raw interval (0 never ends)' % name)
    if 'to = Int(dcmFrom?.intValue ?? 0) - 1' in series or 'if to < from {' in series:
        failures.append('%s: a series with "From" after "To" still leaves out both ends (#888)' % name)
    if 'if view != nil {' not in series:
        failures.append('%s: the series export walks a series with none of its views as the key view' % name)
    count = method(text, 'private func exportImageCount(', '\n}\n')
    if 'OrthogonalFusionSliceExport.seriesImageCount(' not in count:
        failures.append('%s: the image count is not the number of slices the series walks (#888)' % name)
    if 'cDiv(count' in text or 'exportStep(' in text:
        failures.append('%s: the image count still divides and rounds down (#888)' % name)
    counts = [line.strip() for line in text.splitlines() if 'dcmCountTextField?.stringValue' in line]
    # Without a key view of the window there is no series, and no count (#921).
    counted = 'let count = self.exportSeriesLength() > 0 ? exportImageCount(dcmFrom, dcmTo, dcmInterval) : 0'
    shown = [line.strip() for line in text.splitlines() if 'exportImageCount(dcm' in line]
    recount = method(text, 'private func updateExportImageCount()')
    if len(counts) != 1 or shown != [counted] or counted not in recount \
            or 'dcmCountTextField?.stringValue' not in recount:
        failures.append('%s: the sheet does not count the images of the sliders the export reads (#910): %s' % (name, shown))
    # #911 item 3: the sheet opening, a slider or field action and typing in a
    # field all recount, after the field is bounded and handed to its slider.
    for signature in ('public dynamic func exportDICOMFile(', 'public dynamic func changeFromAndToBounds(',
                      'public dynamic func dcmExportTextFieldDidChange('):
        if 'self.updateExportImageCount()' not in method(text, signature):
            failures.append('%s %s: "%%d images" is not recounted (#911)' % (name, signature.split('func ')[1]))
    typed = method(text, 'public dynamic func dcmExportTextFieldDidChange(')
    if typed.find('self.updateExportImageCount()') < typed.rfind('boundExportField(') \
            or '        } else {\n            return\n        }\n' not in typed:
        failures.append('%s: typing recounts before the field reaches its slider, or for a field of another sheet (#911)' % name)

    # #911 item 1: the preview shows the 0-based row the export walks first.
    bounds = method(text, 'public dynamic func changeFromAndToBounds(')
    views_at = bounds.find('dcmInterval {')
    views = bounds[views_at:]
    if 'let row = Float(OrthogonalFusionSliceExport.previewIndex(forField: Int(intValueOf(sender)))) + 0.5' not in bounds:
        failures.append('%s: the preview does not take the row the export walks for the value of the sheet (#911)' % name)
    if views_at < 0 or 'Int(intValueOf(sender))' in views or 'Float(intValueOf(sender))' in views or views.count(', row') + views.count('(row,') != 3:
        failures.append('%s: a view of the preview still takes the 1-based value as its row (#911)' % name)
    if 'private func exportImageCount(_ from: NSSlider?, _ to: NSSlider?, _ interval: NSSlider?)' not in count \
            or 'from: Int(from?.intValue ?? 0), to: Int(to?.intValue ?? 0), interval: Int(interval?.intValue ?? 0)' not in count:
        failures.append('%s: the image count does not read the values the export reads (#910)' % name)
    position = method(text, 'func setCurrentPosition(')
    fields = position.find('if tagOf(sender) == 0 {')
    if fields < 0 or '        } else {\n' not in position[:fields] or '            return\n' not in position[:fields]:
        failures.append('%s: -setCurrentPosition: fills the fields with none of its views as the key view' % name)

    # #888 item 1: the key view is checked, not cast.
    key_view = method(text, 'public dynamic func keyView() -> DCMView!')
    key_ortho = method(text, 'private var keyOrthogonalView: OrthogonalMPRView?')
    if 'unsafeBitCast' in key_view + key_ortho:
        failures.append('%s: the key view is cast without checking its class (#888)' % name)
    if 'firstResponder as? DCMView' not in key_view or 'self.keyView() as? OrthogonalMPRView' not in key_ortho:
        failures.append('%s: the key view is not checked as a DCMView and an OrthogonalMPRView (#888)' % name)

    # #888 item 5: the x view is a row of the original slices (crossPositionY,
    # pheight), the y view a column (crossPositionX, pwidth).
    # The bounds of the sheet are those of -exportSeriesLength, which the count
    # also reads (#921).
    if 'let max = self.exportSeriesLength()' not in method(text, 'public dynamic func exportDICOMFile('):
        failures.append('%s: the sheet does not take its bounds from -exportSeriesLength (#921)' % name)
    for signature in ('private func exportSeriesLength(', 'public dynamic func setCurrentPosition('):
        body = method(text, signature)
        for axis, size, position in (('xReslicedView', 'pheight', 'crossPositionY'), ('yReslicedView', 'pwidth', 'crossPositionX')):
            at = body.find('%s()) {' % axis)
            branch = body[at:body.find('} else', at)] if at >= 0 else ''
            wrong = 'pwidth' if size == 'pheight' else 'pheight'
            if 'curDCM?.%s' % size not in branch or 'curDCM?.%s' % wrong in branch:
                failures.append('%s %s: the %s bound is not the %s of the original slices (#888)'
                                % (name, signature.split('func ')[1], axis, size))
            if ('crossPosition' in branch and position not in branch) or (position == 'crossPositionY' and 'crossPositionX' in branch) \
                    or (position == 'crossPositionX' and 'crossPositionY' in branch):
                failures.append('%s %s: the %s position is not %s (#888)' % (name, signature.split('func ')[1], axis, position))

    # #907 item 1: flippedData reverses the slices, not a row or a column.
    position = method(text, 'public dynamic func setCurrentPosition(')
    original_at = position.find('originalView()) {')
    x_at = position.find('xReslicedView()) {')
    y_at = position.find('yReslicedView()) {')
    end_at = position.find('        } else {\n', y_at)
    if min(original_at, x_at, y_at, end_at) < 0:
        failures.append('%s: -setCurrentPosition: lost one of its views (#907)' % name)
    else:
        # #910: the original view gives the row of the x view the export walks.
        original = position[original_at:x_at]
        if 'flippedData' in original or 'curImage' in original or 'max - curIndex' in original \
                or 'xReslicedView()?.crossPositionY() ?? 0) + 1))' not in original:
            failures.append('%s: -setCurrentPosition: of the original view is not the row of the x view the export walks (#910)' % name)
        if 'curIndex = Swift.min(Swift.max(curIndex, 1), max)' not in position[end_at:]:
            failures.append('%s: -setCurrentPosition: writes a position outside the bounds of the sliders (#910)' % name)
        series_at = text.find('func endExportDICOMFileSettings(')
        walked = text[text.find('originalView()) {', text.find('var deltaX = 0, deltaY = 0', series_at)):]
        walked = walked[:walked.find('} else if')]
        if 'deltaX = 0' not in walked or 'deltaY = 1' not in walked or 'view = keyController?.xReslicedView()' not in walked \
                or 'y = 0' not in walked:
            failures.append('%s: the series of the original view no longer walks the rows of the x view (#910)' % name)
        if 'flippedData ?? false' in position[x_at:end_at] or 'max - curIndex' in position[x_at:end_at]:
            failures.append('%s: -setCurrentPosition: mirrors the row or column of the cross of a flipped series (#907)' % name)

    # #907 item 3: every field of the sheet is bounded by both ends of its slider.
    changed = method(text, 'public dynamic func dcmExportTextFieldDidChange(')
    for field, slider in (('dcmIntervalTextField', 'dcmInterval'), ('dcmFromTextField', 'dcmFrom'), ('dcmToTextField', 'dcmTo')):
        if 'boundExportField(%s, %s)' % (field, slider) not in changed:
            failures.append('%s: the %s field is not bounded by its slider (#907)' % (name, field))
    bound = method(text, 'private func boundExportField(')
    if 'OrthogonalFusionSliceExport.exportFieldValue(' not in bound or 'minValue: slider?.minValue' not in bound \
            or 'maxValue: slider?.maxValue' not in bound or 'slider?.takeIntValueFrom(field)' not in bound:
        failures.append('%s: the fields of the sheet are not kept in the minimum and maximum of their sliders (#907)' % name)

# #911 item 2: the orthogonal MPR moves the cross of the view it reslices from.
mpr_bounds = method(mpr_source, 'public dynamic func changeFromAndToBounds(')
if 'controller?.reslice(' in mpr_bounds or mpr_bounds.count('self.resliceFrom(controller?.') != 3:
    failures.append('OrthogonalMPRViewer: the preview reslices without moving the cross of its view (#911)')
moved = method(mpr_source, 'private func resliceFrom(')
if not (0 <= moved.find('view?.setCrossPositionX(x)') < moved.find('controller?.reslice(')) \
        or not (0 <= moved.find('view?.setCrossPositionY(y)') < moved.find('controller?.reslice(')) \
        or 'controller?.reslice(cLong(Double(x)), cLong(Double(y)), view)' not in moved:
    failures.append('OrthogonalMPRViewer: -resliceFrom does not move the cross of the view before reslicing from it (#911)')
for signature, call in (('xReslicedView()) {', 'self.resliceFrom(controller?.originalView(), controller?.originalView()?.crossPositionX() ?? 0, row)'),
                        ('yReslicedView()) {', 'self.resliceFrom(controller?.originalView(), row, controller?.originalView()?.crossPositionY() ?? 0)'),
                        ('originalView()) {', 'self.resliceFrom(controller?.xReslicedView(), controller?.xReslicedView()?.crossPositionX() ?? 0, row)')):
    at = mpr_bounds.find(signature, mpr_bounds.find('dcmInterval {'))
    if call not in mpr_bounds[at:mpr_bounds.find('}', at + len(signature))]:
        failures.append('OrthogonalMPRViewer: the preview of the %s key view does not move its cross to the row (#911)' % signature[:-4])
petct_bounds = method(source, 'public dynamic func changeFromAndToBounds(')
for call in ('self.resliceFromX(keyController?.xReslicedView()?.crossPositionX() ?? 0, row, keyController)',
             'self.resliceFromOriginal(keyController?.originalView()?.crossPositionX() ?? 0, row, keyController)',
             'self.resliceFromOriginal(row, keyController?.originalView()?.crossPositionY() ?? 0, keyController)'):
    if call not in petct_bounds:
        failures.append('OrthogonalMPRPETCTViewer: the preview does not move the cross to the row the export walks (#911): %s' % call)

jpeg = method(mpr_source, 'private dynamic func exportJPEG(')
if not jpeg or 'let all' in jpeg or 'if all' in jpeg:
    failures.append('OrthogonalMPRViewer: -exportJPEG: keeps its dead "all" branch')

# #888 item 4: the PET-CT JPEG series of the y view walks the columns (pwidth).
petct_jpeg = method(source, 'private dynamic func exportJPEG(')
at = petct_jpeg.find('yReslicedView()) {')
branch = petct_jpeg[at:petct_jpeg.find('}', at + len('yReslicedView()) {'))] if at >= 0 else ''
if 'max = view?.curDCM?.pwidth' not in branch or 'pheight' in branch:
    failures.append('OrthogonalMPRPETCTViewer: the JPEG series of the y view walks the height of the slices (#888)')
if 'let all' in petct_jpeg or 'if all' in petct_jpeg:
    failures.append('OrthogonalMPRPETCTViewer: -exportJPEG: keeps its dead single-image branch (#888)')

# #907 item 2: OPENVIEWER opens the first image the PET-CT JPEG series wrote.
opened = petct_jpeg[petct_jpeg.find('if UserDefaults.standard.bool(forKey: "OPENVIEWER") {'):]
if 'if let url = panel.url {' in opened or 'if let url = firstImage {' not in opened \
        or 'NSWorkspace.shared.open(url)' not in opened:
    failures.append('OrthogonalMPRPETCTViewer: the JPEG series opens the name of the panel, which it never writes (#907)')
written = petct_jpeg[petct_jpeg.find('String(format: "%d.jpg"'):petct_jpeg.find('i += 1', petct_jpeg.find('String(format: "%d.jpg"'))]
if 'write(to: url, atomically: true) ?? false, firstImage == nil' not in written or 'firstImage = url' not in written:
    failures.append('OrthogonalMPRPETCTViewer: the image OPENVIEWER opens is not the first one written (#907)')

# #888 item 6: cancelling the three-modality series stops all three.
petct_series = source[source.find('func endExportDICOMFileSettings('):source.find('func exportDICOMFile(', source.find('func endExportDICOMFileSettings('))]
three = petct_series[petct_series.find('export3modalities") == false {'):]
if three.count('for index in indices {') != 2 or 'for (seriesNumber, seriesView) in [(nCT, viewCT), (nPETCT, viewPETCT), (nPET, viewPET)]' not in three:
    failures.append('OrthogonalMPRPETCTViewer: the three-modality series are not one loop (#888)')
elif 'aborted = true' not in three or '                                    if aborted {\n                                        break' not in three:
    failures.append('OrthogonalMPRPETCTViewer: cancelling the CT series does not stop the PET-CT and PET series (#888)')

# #888 item 7: one NSEnableScreenUpdates per slice of the orthogonal MPR series.
mpr_series = mpr_source[mpr_source.find('func endExportDICOMFileSettings('):mpr_source.find('func exportDICOMFile(', mpr_source.find('func endExportDICOMFileSettings('))]
loop = mpr_series[mpr_series.find('for index in indices {'):mpr_series.find('if aborted {')]
if loop.count('NSDisableScreenUpdates()') != 1 or loop.count('NSEnableScreenUpdates()') != 1:
    failures.append('OrthogonalMPRViewer: a slice of the series does not enable screen updates once per disable (#888)')
elif loop.find('NSEnableScreenUpdates()') < loop.find('} catch {'):
    failures.append('OrthogonalMPRViewer: a slice that raises leaves screen updates disabled (#888)')

close = method(source, 'private dynamic func CloseViewerNotification(')
if 'v === blendingViewerController' not in close or 'PETController?.viewer()' in close:
    failures.append('closing the PET viewer does not close the PET-CT window (compared with the CT viewer)')

reslice = method(controller_source, 'public override dynamic func reslice(')
if 'var blendingFactor: Float = originalView?.blendingFactor' not in reslice:
    failures.append('the first reslice of the fused row sets a fusion factor no view held')

writer = (root / 'Horos/Sources/DICOMExport.mm').read_bytes().decode('latin1')
pos_block = writer[writer.find('delete dataset->remove( DCM_ImagePositionPatient'):writer.find('delete dataset->remove( DCM_SliceLocation')]
if 'positionSet' not in writer or 'position[ 0] != 0' in pos_block:
    failures.append('Image Position (Patient) is omitted when the fused origin is at 0,0,0')

for failure in failures:
    print('FAIL: %s' % failure)

main = r'''import Foundation
import CryptoKit

func floats(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}
func numbers(_ values: [Double]) -> [NSNumber] { values.map { NSNumber(value: $0) } }
func grayLUT() -> Data {
    var bytes = [UInt8](repeating: 0, count: 768)
    for i in 0..<256 {
        bytes[i * 3] = UInt8(i)
        bytes[i * 3 + 1] = UInt8(i)
        bytes[i * 3 + 2] = UInt8(i)
    }
    return Data(bytes)
}
func layer(width: Int, height: Int, origin: [Double], orientation: [Double],
            spacing: [Double], location: Double, thickness: Double,
            windowCenter: Double, windowWidth: Double, samples: [Float]) -> OrthogonalFusionLayer {
    let layer = OrthogonalFusionLayer()
    layer.samples = floats(samples)
    layer.width = width
    layer.height = height
    layer.origin = numbers(origin)
    layer.orientation = numbers(orientation)
    layer.spacing = numbers(spacing)
    layer.sliceLocation = location
    layer.sliceThickness = thickness
    layer.windowCenter = windowCenter
    layer.windowWidth = windowWidth
    return layer
}
func ctValue(x: Int, y: Int, z: Int) -> Float { Float(x + 2 * y + 3 * z) }
func ptValue(x: Int, y: Int, z: Int) -> Float { Float(500 + 3 * x + y + 5 * z) }
func plane(width: Int, height: Int, z: Int, pet: Bool) -> [Float] {
    (0..<height).flatMap { y in (0..<width).map { x in pet ? ptValue(x: x, y: y, z: z) : ctValue(x: x, y: y, z: z) } }
}

let axial = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
let spacing = [1.0, 1.0]
let lut = grayLUT()

precondition(OrthogonalFusionSliceExport.windowedByte(value: 40, windowCenter: 100, windowWidth: 0) == 0)
precondition(OrthogonalFusionSliceExport.windowedByte(value: 0, windowCenter: 100, windowWidth: 200) == 0)
let mid = OrthogonalFusionSliceExport.windowedByte(value: 100, windowCenter: 100, windowWidth: 200)
precondition(mid == 128 || mid == 127)
precondition(OrthogonalFusionSliceExport.windowedByte(value: 200, windowCenter: 100, windowWidth: 200) == 255)
precondition(OrthogonalFusionSliceExport.windowedByte(value: -50, windowCenter: 100, windowWidth: 200) == 0)
precondition(OrthogonalFusionSliceExport.windowedByte(value: 400, windowCenter: 100, windowWidth: 200) == 255)

func ints(_ values: [NSNumber]) -> [Int] { values.map { $0.intValue } }
precondition(ints(OrthogonalFusionSliceExport.sliceIndices(from: 0, to: 4, interval: 1)) == [0, 1, 2, 3])
precondition(ints(OrthogonalFusionSliceExport.sliceIndices(from: 3, to: 0, interval: 1)) == [0, 1, 2])
precondition(ints(OrthogonalFusionSliceExport.sliceIndices(from: 0, to: 6, interval: 2)) == [0, 2, 4])
precondition(ints(OrthogonalFusionSliceExport.sliceIndices(from: 0, to: 3, interval: 0)) == [0, 1, 2])
precondition(ints(OrthogonalFusionSliceExport.sliceIndices(from: 0, to: 0, interval: 1)).isEmpty)
precondition(ints(OrthogonalFusionSliceExport.sliceIndices(from: 0, to: 3, interval: -2)) == [0, 1, 2])

// #888: the 1-based "From" and "To" of the sheet, both ends included in either order.
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 1, to: 10, interval: 1)) == Array(0..<10))
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 10, to: 1, interval: 1)) == Array(0..<10),
             "10...1 takes \(OrthogonalFusionSliceExport.seriesIndices(from: 10, to: 1, interval: 1).count) images")
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 2, to: 1, interval: 1)) == [0, 1])
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 3, to: 3, interval: 1)) == [2])
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 1, to: 10, interval: 3)) == [0, 3, 6, 9])
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 10, to: 1, interval: 3)) == [0, 3, 6, 9])
precondition(ints(OrthogonalFusionSliceExport.seriesIndices(from: 1, to: 5, interval: 0)) == [0, 1, 2, 3, 4])
precondition(OrthogonalFusionSliceExport.seriesImageCount(from: 1, to: 10, interval: 3) == 4,
             "1...10 by 3 counts \(OrthogonalFusionSliceExport.seriesImageCount(from: 1, to: 10, interval: 3))")
for first in 1...12 {
    for last in 1...12 {
        for interval in -1...5 {
            let walked = OrthogonalFusionSliceExport.seriesIndices(from: first, to: last, interval: interval)
            precondition(OrthogonalFusionSliceExport.seriesImageCount(from: first, to: last, interval: interval) == walked.count,
                         "\(first)...\(last) by \(interval): the count is not the images exported")
            precondition(walked.first?.intValue == min(first, last) - 1, "\(first)...\(last) leaves out its first end")
            if interval <= 1 {
                precondition(walked.count == abs(first - last) + 1, "\(first)...\(last) leaves out an end")
            }
        }
    }
}

// #907: a field of the sheet keeps both bounds of its slider (1...90 for "From").
precondition(OrthogonalFusionSliceExport.exportFieldValue(0, minValue: 1, maxValue: 90) == 1,
             "From 0 stays \(OrthogonalFusionSliceExport.exportFieldValue(0, minValue: 1, maxValue: 90))")
precondition(OrthogonalFusionSliceExport.exportFieldValue(-7, minValue: 1, maxValue: 90) == 1)
precondition(OrthogonalFusionSliceExport.exportFieldValue(Int32.min, minValue: 1, maxValue: 90) == 1)
precondition(OrthogonalFusionSliceExport.exportFieldValue(1, minValue: 1, maxValue: 90) == 1)
precondition(OrthogonalFusionSliceExport.exportFieldValue(42, minValue: 1, maxValue: 90) == 42)
precondition(OrthogonalFusionSliceExport.exportFieldValue(90, minValue: 1, maxValue: 90) == 90)
precondition(OrthogonalFusionSliceExport.exportFieldValue(91, minValue: 1, maxValue: 90) == 90)
precondition(OrthogonalFusionSliceExport.exportFieldValue(Int32.max, minValue: 1, maxValue: 50) == 50)
for value in Int32(-3)...Int32(95) {
    let kept = OrthogonalFusionSliceExport.exportFieldValue(value, minValue: 1, maxValue: 90)
    precondition(kept >= 1 && kept <= 90, "\(value) kept as \(kept)")
    precondition(OrthogonalFusionSliceExport.seriesIndices(from: Int(kept), to: 90, interval: 1).allSatisfy { $0.intValue >= 0 },
                 "From \(value) walks a slice before the first")
}

// #911: the preview of a 1-based "From" or "To" is the first index the export walks.
precondition(OrthogonalFusionSliceExport.previewIndex(forField: 1) == 0,
             "From 1 previews \(OrthogonalFusionSliceExport.previewIndex(forField: 1))")
precondition(OrthogonalFusionSliceExport.previewIndex(forField: 0) == 0)
precondition(OrthogonalFusionSliceExport.previewIndex(forField: -5) == 0)
precondition(OrthogonalFusionSliceExport.previewIndex(forField: Int.min) == 0)
for value in 1...12 {
    precondition(OrthogonalFusionSliceExport.previewIndex(forField: value)
                 == OrthogonalFusionSliceExport.seriesIndices(from: value, to: 12, interval: 1).first?.intValue,
                 "From \(value) previews another row than the export walks first")
    precondition(OrthogonalFusionSliceExport.previewIndex(forField: value)
                 == OrthogonalFusionSliceExport.seriesIndices(from: 1, to: value, interval: 1).last?.intValue,
                 "To \(value) previews another row than the export walks last")
}

var digests: [String] = []
var origins: [[Double]] = []
var locations: [Double] = []
for (instance, z) in ints(OrthogonalFusionSliceExport.sliceIndices(from: 0, to: 4, interval: 1)).enumerated() {
    let primary = layer(width: 32, height: 32, origin: [10, 20, Double(z)], orientation: axial,
                         spacing: spacing, location: Double(z), thickness: 1,
                         windowCenter: 100, windowWidth: 200, samples: plane(width: 32, height: 32, z: z, pet: false))
    let secondary = layer(width: 32, height: 32, origin: [10, 20, Double(z)], orientation: axial,
                           spacing: spacing, location: Double(z), thickness: 1,
                           windowCenter: 600, windowWidth: 400, samples: plane(width: 32, height: 32, z: z, pet: true))
    guard let frame = OrthogonalFusionSliceExport.slice(fromPrimary: primary, secondary: secondary,
                                                          lut: lut, blendingFactor: 0, instanceNumber: instance + 1)
    else { preconditionFailure("slice \(z)") }
    precondition(frame.width == 32 && frame.height == 32)
    precondition(frame.pixelRGB.count == 32 * 32 * 3)
    precondition(frame.instanceNumber == instance + 1)
    precondition(abs(frame.sliceThickness - 1) < 1e-9)
    precondition(frame.orientation.map { $0.doubleValue } == axial)
    precondition(frame.spacing.map { $0.doubleValue } == spacing)
    digests.append(frame.digest)
    origins.append(frame.origin.map { $0.doubleValue })
    locations.append(frame.sliceLocation)
    let hashed = SHA256.hash(data: frame.pixelRGB).map { String(format: "%02x", $0) }.joined()
    precondition(frame.digest == hashed, "digest is not SHA-256 of the RGB")
}

precondition(Set(digests).count == 4, "fused frames share pixels: \(digests)")
precondition(Set(origins.map { $0[2] }).count == 4, "fused frames share Image Position Z")
precondition(locations == [0, 1, 2, 3], "Slice Location \(locations)")
precondition(origins.map { $0[0] } == [10, 10, 10, 10])
precondition(origins.map { $0[1] } == [20, 20, 20, 20])
precondition(origins.map { $0[2] } == [0, 1, 2, 3])

let again = OrthogonalFusionSliceExport.slice(
    fromPrimary: layer(width: 32, height: 32, origin: [10, 20, 1], orientation: axial,
                       spacing: spacing, location: 1, thickness: 1,
                       windowCenter: 100, windowWidth: 200, samples: plane(width: 32, height: 32, z: 1, pet: false)),
    secondary: layer(width: 32, height: 32, origin: [10, 20, 1], orientation: axial,
                     spacing: spacing, location: 1, thickness: 1,
                     windowCenter: 600, windowWidth: 400, samples: plane(width: 32, height: 32, z: 1, pet: true)),
    lut: lut, blendingFactor: 0, instanceNumber: 2)!
precondition(again.digest == digests[1])

let first = OrthogonalFusionSliceExport.slice(
    fromPrimary: layer(width: 32, height: 32, origin: [10, 20, 0], orientation: axial,
                       spacing: spacing, location: 0, thickness: 1,
                       windowCenter: 100, windowWidth: 200, samples: plane(width: 32, height: 32, z: 0, pet: false)),
    secondary: layer(width: 32, height: 32, origin: [10, 20, 0], orientation: axial,
                     spacing: spacing, location: 0, thickness: 1,
                     windowCenter: 600, windowWidth: 400, samples: plane(width: 32, height: 32, z: 0, pet: true)),
    lut: lut, blendingFactor: 0, instanceNumber: 1)!
let ct00 = OrthogonalFusionSliceExport.windowedByte(value: Double(ctValue(x: 0, y: 0, z: 0)),
                                                     windowCenter: 100, windowWidth: 200)
let pt00 = OrthogonalFusionSliceExport.windowedByte(value: Double(ptValue(x: 0, y: 0, z: 0)),
                                                     windowCenter: 600, windowWidth: 400)
let mixed = Int((Double(ct00) + Double(pt00)) / 2)
let firstRGB = [UInt8](first.pixelRGB)
precondition(abs(Int(firstRGB[0]) - mixed) <= 1, "linear fusion R \(firstRGB[0]) against \(mixed)")
precondition(firstRGB[0] == firstRGB[1] && firstRGB[1] == firstRGB[2], "identity LUT keeps gray")

let shifted = OrthogonalFusionSliceExport.slice(
    fromPrimary: layer(width: 32, height: 32, origin: [10, 20, 0], orientation: axial,
                       spacing: spacing, location: 0, thickness: 1,
                       windowCenter: 100, windowWidth: 200, samples: plane(width: 32, height: 32, z: 0, pet: false)),
    secondary: layer(width: 32, height: 32, origin: [14, 20, 0], orientation: axial,
                     spacing: spacing, location: 0, thickness: 1,
                     windowCenter: 600, windowWidth: 400, samples: plane(width: 32, height: 32, z: 0, pet: true)),
    lut: lut, blendingFactor: 0, instanceNumber: 1)!
let shiftedRGB = [UInt8](shifted.pixelRGB)
let emptyMix = Int(Double(ct00) / 2)
precondition(abs(Int(shiftedRGB[0]) - emptyMix) <= 1, "unaligned left edge mixes empty PET, got \(shiftedRGB[0])")
let alignedMix = Int((Double(OrthogonalFusionSliceExport.windowedByte(value: Double(ctValue(x: 4, y: 0, z: 0)),
                                                                     windowCenter: 100, windowWidth: 200))
                       + Double(pt00)) / 2)
precondition(abs(Int(shiftedRGB[4 * 3]) - alignedMix) <= 1,
             "shifted PET at column 4: \(shiftedRGB[4 * 3]) against \(alignedMix)")
precondition(shifted.digest != first.digest, "a spatial shift must change the fused pixels")

var smallPET = [Float](repeating: 0, count: 16 * 16)
for y in 0..<16 {
    for x in 0..<16 { smallPET[y * 16 + x] = ptValue(x: x * 2, y: y * 2, z: 0) }
}
let resampled = OrthogonalFusionSliceExport.slice(
    fromPrimary: layer(width: 32, height: 32, origin: [10, 20, 0], orientation: axial,
                       spacing: spacing, location: 0, thickness: 1,
                       windowCenter: 100, windowWidth: 200, samples: plane(width: 32, height: 32, z: 0, pet: false)),
    secondary: layer(width: 16, height: 16, origin: [10, 20, 0], orientation: axial,
                     spacing: [2, 2], location: 0, thickness: 1,
                     windowCenter: 600, windowWidth: 400, samples: smallPET),
    lut: lut, blendingFactor: 0, instanceNumber: 1)!
precondition(resampled.width == 32 && resampled.pixelRGB.count == 32 * 32 * 3)
precondition(resampled.digest != first.digest)

print("PASS: fused PET/CT frames have distinct SHA-256 pixels and Image Position per slice, with PET sampled in patient space")
'''

with tempfile.TemporaryDirectory(prefix='horos-fusion-export-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    swift = root / 'Horos/Sources/OrthogonalFusionSliceExport.swift'
    if not swift.is_file():
        print('FAIL: the fusion export helper is missing')
        raise SystemExit(1)
    compile = subprocess.run(
        ['xcrun', 'swiftc', '-swift-version', '5',
         str(swift), str(p / 'main.swift'), '-framework', 'Foundation',
         '-framework', 'CryptoKit', '-o', str(p / 'test')],
        cwd=p, capture_output=True, text=True)
    if compile.returncode != 0:
        sys.stderr.write(compile.stdout + compile.stderr)
        print('FAIL: fusion export helper did not compile')
        raise SystemExit(1)
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    sys.stdout.write(run.stdout)
    sys.stderr.write(run.stderr)
    if run.returncode != 0:
        raise SystemExit(run.returncode)

if failures:
    raise SystemExit(1)
