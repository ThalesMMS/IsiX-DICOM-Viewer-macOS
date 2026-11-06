#!/usr/bin/env python3
"""The browser preview consumes the window policy.

Source level, with `<git revision>` as an optional argument for the negative
control:

* the pair of window numbers `previewSliderAction:` used to read and throw away
  now goes through `HorosPreviewWindowPolicy`, on every branch and on the first
  display of a selection;
* a person moving the window in the preview is told apart from the policy
  putting a default back, so scrolling cannot undo an adjustment;
* a width of zero reaches the automatic branch instead of coming out as a
  window two units wide, and a colour frame's lookup table no longer divides by
  its own width;
* the frames the view is drawing are not reverted underneath it;
* a thumbnail batch published after the selection changed is discarded by
  generation, not only by the address of the array;
* one burst of scroll events costs one preview decode;
* the viewer's own clinical windowing is not touched.

The browser side of the policy: the selectors (`previewSliderAction:`,
`applyPreviewWindowForImage:pix:`, the window delegate, `matrixInit:`,
`matrixNewIcon::`, `scrollWheel:`) are the Swift extension
`BrowserController+Preview.swift`, which hands their work to the database
preview, `BrowserPreviewPane.swift`, where it is read; the decisions around the
policy are IsiXImaging's `PreviewWindowing.swift`. The delegate assignment is
read where the window is wired (`BrowserController+Window.swift`), and the
generation handed to the thumbnail load is read where the pane asks for it.
"""
from pathlib import Path
import subprocess
import sys
from sources import class_text

root = Path(__file__).resolve().parents[1]


def read(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


def swift_method(source, signature):
    """A Swift method: its signature up to the brace that closes its body."""
    start = source.find(signature)
    if start < 0:
        return ''
    index = source.index('{', start)
    depth = 0
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    return ''


failures = []
browser = class_text('BrowserController')
try:
    swift = read('Horos/Sources/BrowserController+Preview.swift')
except subprocess.CalledProcessError:
    swift = ''
try:
    selection = read('Horos/Sources/BrowserController+OutlineSelection.swift')
except subprocess.CalledProcessError:
    selection = ''
try:
    window = read('Horos/Sources/BrowserController+Window.swift')
except subprocess.CalledProcessError:
    window = ''
# The generation is kept with the preview's state and moved by an accessor of
# the class (BrowserController+StateAccess.swift).
try:
    ivars = read('Horos/Sources/BrowserController+StateAccess.swift')
except (subprocess.CalledProcessError, FileNotFoundError):
    ivars = ''
# PreviewView and DCMView are Swift (PreviewView.swift, DCMView.swift and
# DCMView+Viewer.swift).
preview = read('Horos/Sources/PreviewView.swift')
previewHeader = read('Horos/Sources/PreviewView.h')
try:
    pix = read('Horos/Sources/DCMPix.m')
except (OSError, subprocess.CalledProcessError):
    pix = ''  # DCMPix is Swift
view = read('Horos/Sources/DCMView.swift') + read('Horos/Sources/DCMView+Viewer.swift')

try:
    pane = read('Horos/Sources/BrowserPreviewPane.swift')
except subprocess.CalledProcessError:
    pane = ''
try:
    windowing = read('Modules/IsiXImaging/Sources/PreviewWindowing.swift')
except subprocess.CalledProcessError:
    windowing = ''
try:
    policy = read('Horos/Sources/PreviewWindowing.swift')
except subprocess.CalledProcessError:
    policy = ''

# --- the policy exists and is reachable from Objective-C --------------------
for symbol in ['@objc(HorosPreviewWindowPolicy)', '@objc(HorosPreviewAutomaticWindow)',
               '@objc(HorosPreviewRedrawCoalescer)', '@objc(HorosPreviewWindow)']:
    if symbol not in policy:
        failures.append('%s is missing from the preview window policy' % symbol)

# --- every entry point asks the policy --------------------------------------
if 'previewPane.showSliderFrame(sender: sender)' not in swift_method(swift, 'func previewSliderAction(_ sender: Any!)'):
    failures.append('previewSliderAction: does not hand the slider to the preview')
slider = swift_method(pane, 'func showSliderFrame(sender: Any?)')
show = swift_method(pane, 'private func show(_ pix: DCMPix, of image: DicomImage?, at tag: Int)')
if not slider or not show:
    failures.append('the preview slider was not found')
if slider.count('applyWindow(for: image, pix: pix)') != 1 or slider.count('show(pix, of: ') != 2 \
        or 'applyWindow(for: image, pix: pix)' not in show:
    failures.append('the three branches of the slider do not all apply the policy')
if 'getWLWW(' in slider:
    failures.append('the slider still reads a window it never uses')
if 'previewPane.showIcon(index, of: curFile)' not in swift_method(swift, 'func matrixNewIcon(_ index: Int, _ curFile: NSManagedObject!)'):
    failures.append('matrixNewIcon:: does not hand the icon to the preview')
display = swift_method(pane, 'private func describeIcon(')
if 'applyWindow(for: nil, pix: nil)' not in display:
    failures.append('the first display of a selection does not apply the policy')

if 'previewPane.applyWindow(for: imageObj, pix: dcmPix)' not in swift_method(swift, 'func applyPreviewWindow(for imageObj: DicomImage!, pix dcmPix: DCMPix!)'):
    failures.append('applyPreviewWindowForImage:pix: does not hand the window to the preview')
apply = swift_method(pane, 'func applyWindow(for image: DicomImage?, pix: DCMPix?)')
if not apply:
    failures.append('the preview window was not found')
for fragment, reason in [
        ('beginFrame(seriesKey:', 'the policy is not told which frame is coming'),
        ('series?.seriesDICOMUID', 'the series is not identified by its DICOM UID'),
        ('parsedFileCacheKey', 'the file revision is not part of the identity'),
        ('needsAutomaticWindow(modality:', 'the pixels are sampled even when the ladder cannot use it'),
        ('manualWindow', 'a manual adjustment is not reapplied when the defaults stand'),
        ('isColorPreviewFrame', 'a colour frame is not told apart'),
        ('frameRangePreviewWindow', "a frame with nothing to sample falls straight to the stored bit range")]:
    if fragment not in apply:
        failures.append(reason)
# A series' defaults come from its middle image, as the thumbnail and the 2D
# viewer take theirs: scanners that compute a window per slice give the edge
# slice the preview opens on the window of its noise.
reference = swift_method(pane, 'private func referencePix(for image: DicomImage?, shown pix: DCMPix) -> DCMPix')
middle = swift_method(windowing, 'public static func referenceFrame(')
if not reference or not middle:
    failures.append('the preview has no reference frame for its defaults')
else:
    for source, fragment, reason in [
            (reference, 'PreviewWindowing.referenceFrame(imageCount: images.count', 'the reference is not chosen among the images of the series'),
            (middle, 'let index = imageCount / 2', 'the reference is not the middle image of the series'),
            (middle, 'let middle = fileFrames / 2', 'a single multiframe file does not use its middle frame'),
            (reference, 'notAbleToLoadImage ? pix', 'an unreadable middle image does not fall back to the frame shown')]:
        if fragment not in source:
            failures.append(reason)
if 'let reference = referencePix(for: image, shown: shownPix)' not in apply:
    failures.append('the defaults are read from the frame shown, not from the middle of the series')
for call in ('dicomPreviewWindow', 'automaticPreviewWindow', 'frameRangePreviewWindow', 'storedRangePreviewWindow', 'isColorPreviewFrame'):
    if ('shownPix.%s(' % call) in apply:
        failures.append('%s is still read from the frame shown' % call)
if 'PreviewWindowing.needsFrameRange(hasAutomaticWindow: automatic != nil, isColor: isColor' not in apply \
        or '!hasAutomaticWindow && !isColor && !hasValidFileWindow' not in windowing:
    failures.append('the frame range is computed even when the ladder cannot reach it')
if 'shown.isShowing(level: window.level, width: window.width)' not in apply \
        or 'pixels.width == width && pixels.level == level && view.width == width && view.level == level' not in windowing:
    failures.append('the same window is applied again, reloading the textures for nothing')

# --- a manual adjustment is told apart from a default -----------------------
if 'PreviewViewWindowDelegate' not in previewHeader:
    failures.append('PreviewView does not report window changes')
setter = swift_method(preview, 'override dynamic func setWLWW(_ wl: Float, _ ww: Float)')
if 'self.applyingPreviewWindow == 0' not in setter or 'didRequestWindowLevel: wl' not in setter:
    failures.append('PreviewView cannot tell a manual adjustment from a default')
marking = swift_method(preview, 'private func whileApplyingPreviewWindow(')
if 'self.applyingPreviewWindow += 1' not in marking or 'self.applyingPreviewWindow -= 1' not in marking:
    failures.append('applying a default is reported back as a manual adjustment')
applied = swift_method(preview, 'public dynamic func apply(_ window: PreviewWindow?)')
if 'self.whileApplyingPreviewWindow {' not in applied:
    failures.append('applying a default is reported back as a manual adjustment')
# Restoring the stored presentation state re-asserts the window the view has;
# recording it as a choice pinned every first frame of a selection.
restore = swift_method(preview, 'override dynamic func updatePresentationState(fromSeriesOnlyImageLevel onlyImage: Bool, scale: Bool, offset: Bool)')
if 'self.whileApplyingPreviewWindow {' not in restore or 'super.updatePresentationState(fromSeriesOnlyImageLevel:' not in restore:
    failures.append('a presentation-state restore is recorded as a manual adjustment')
delegate = swift_method(swift, 'func previewView(_ view: PreviewView!, didRequestWindowLevel wl: Float, width ww: Float)')
requested = swift_method(pane, 'func needsAutomaticWindow(afterRequest level: Float, width: Float) -> Bool')
if 'previewPane.needsAutomaticWindow(afterRequest: wl, width: ww)' not in delegate or 'recordRequested(level:' not in requested:
    failures.append('the browser does not record the adjustment a person made')
if '[imageView setWindowDelegate: self]' not in browser and 'horos_imageView?.windowDelegate = self' not in window:
    failures.append('the preview view has no window delegate')

# --- a zero width means automatic, and colour keeps its own presentation -----
# DCMPix hands the request and the colour table to the IsiXImaging module;
# tests/test-dcmpix-buffer-operations.py checks the windows they give.
# Where they left DCMPix.m, the window and the preview windows are
# DCMPix+Display.swift's, which call the module and the policy in Swift.
in_swift = '- (void) changeWLWW:(float)newWL :(float)newWW' not in pix
display = read('Horos/Sources/DCMPix+Display.swift') if in_swift else ''
change = method(pix, '- (void) changeWLWW:(float)newWL :(float)newWW')
window = read('Modules/IsiXImaging/Sources/BufferOperations/ImageWindow.swift')
rendering = read('Modules/IsiXImaging/Sources/BufferOperations/WindowRendering.swift')
if in_swift:
    change = swift_method(display, 'public dynamic func changeWLWW(_ newWL: Float, _ newWW: Float)')
    requested = 'ImageWindow.requested(level: newWL, width: newWW' in change
else:
    requested = 'IsiXImageWindow requestLevel:' in change
if not requested or \
        'if width == 0 || width.isNaN || width.isInfinite || level.isNaN || level.isInfinite { return nil }' not in window:
    failures.append('a zero or non-finite width still produces a window two units wide')
if 'if difference == 0 { difference = 1 }' not in rendering:
    failures.append('a colour frame still divides by its own window width')

# --- one decode feeds the frame and its window ------------------------------
if in_swift:
    # The body of -CheckLoadIn is DCMPix+Loading.swift's once the class is Swift.
    load = swift_method(read('Horos/Sources/DCMPix+Loading.swift'), 'final func loadIfNeeded()')
    counted = 'DCMPixSettings.countDecodedFrame()' in load and \
        'static func countDecodedFrame() { decoded.add(1, ordering: .relaxed) }' in read('Horos/Sources/DCMPixSettings.swift')
else:
    load = method(pix, '- (void) CheckLoadIn')
    counted = 'atomic_fetch_add_explicit( &horosDecodedFrameCount' in load
if not counted:
    failures.append('decodes are not counted, so the sharing cannot be proved')
if in_swift:
    frame_range = swift_method(display, 'public dynamic func frameRangePreviewWindow()')
    automatic = swift_method(display, 'public dynamic func automaticPreviewWindow()')
    min_max, refused = 'computePixMinPixMax()', 'guard !horos_isRGB, horos_fImage != nil'
    sampled, refused_sample, decode = 'PreviewAutomaticWindow.window(values:', 'guard !horos_isRGB, let pixels = horos_fImage', 'checkLoad()'
else:
    frame_range = method(pix, '- (id) frameRangePreviewWindow')
    automatic = method(pix, '- (id) automaticPreviewWindow')
    min_max, refused = 'computePixMinPixMax', 'isRGB || fImage == nil'
    sampled, refused_sample, decode = 'HorosPreviewAutomaticWindow windowForValues:', 'isRGB || fImage == nil', '[self CheckLoad]'
if min_max not in frame_range:
    failures.append("the frame's own range is not read from its minimum and maximum")
if refused not in frame_range:
    failures.append('a colour frame or an empty frame gets a scalar frame range')

if sampled not in automatic:
    failures.append('the automatic window is not computed from the decoded frame')
if automatic.count(decode) != 1:
    failures.append('the automatic window does not share the single decode')
if refused_sample not in automatic:
    failures.append('a colour frame or an empty frame is sampled anyway')

# --- the frame being drawn is not freed underneath the view ------------------
if show.count('other !== pix && other !== drawn') != 1:
    failures.append('the frame the view is drawing is still reverted underneath it')
if show.count('let drawn = browser.horos_imageView?.curDCM') != 1:
    failures.append('the drawn frame is not read back from the view')

# --- a stale thumbnail batch is discarded -----------------------------------
# The generation is incremented by the class's accessor.
init = swift_method(pane, 'func matrixInit(_ count: Int)')
increment = swift_method(ivars, 'func horos_incrementPreviewPixGeneration()')
if 'browser.horos_incrementPreviewPixGeneration()' not in init or 'previewState.previewPixGeneration &+= 1' not in increment:
    failures.append('replacing the preview list does not move the generation')
publish = swift_method(pane, 'private func publish(_ batch: ThumbnailBatch)')
if 'browser.horos_previewPix === batch.list && browser.horos_previewPixGeneration == batch.generation' not in publish:
    failures.append('a batch published after the selection changed is not discarded by generation')
if 'generation: browser.horos_previewPixGeneration' not in pane:
    failures.append('the thumbnail load does not carry the generation it started with')

# --- one burst of scroll events costs one decode ----------------------------
wheel = swift_method(pane, 'func scroll(with event: NSEvent)')
if 'previewPane.scroll(with: theEvent)' not in swift_method(swift, 'override func scrollWheel(with theEvent: NSEvent)'):
    failures.append('the wheel is not handed to the preview')
if 'coalescer.request {' not in wheel:
    failures.append('every scroll notch still decodes a frame')
if 'coalescer.flush()' not in wheel:
    failures.append('the end of a gesture waits for the coalescing interval')

# --- the viewer's own windowing is untouched --------------------------------
for name, source in [('DCMView', view)]:
    if 'HorosPreviewWindowPolicy' in source or 'HorosPreviewAutomaticWindow' in source:
        failures.append('%s adopts the preview policy; the clinical window must not change' % name)
reapply = swift_method(view, 'public dynamic func reapplyWindowLevel()')
if 'curDCM?.changeWLWW(self.windowLevelState.level, self.windowLevelState.width)' not in reapply:
    failures.append('the viewer no longer reapplies its own window level')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: the preview asks the policy, keeps manual adjustments and shares its decode')
