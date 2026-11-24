#!/usr/bin/env python3
"""The database preview follows the thumbnail pressed under a study line.

With a study line selected, pressing a thumbnail shows its series through the
animation slider. What the slider shows was decided by the number of frames of
the series' only image, and a row of the database says 0 frames for a file
that states no Number of Frames, as most images of one frame do: the only
image of a series was then neither "one image" (frames == 1) nor "several
frames" (frames > 1), nothing was shown, and the preview stayed on the last
series of several images or pages - a PDF, in a study of radiographs.

The decision is PreviewAnimation.sliderFrame (IsiXDatabase), where an image has
at least one frame; its module test holds the cases. Read here: the preview
asks that rule and no longer counts the frames itself, and the opening of a
viewer, which holds the preview while it opens, lets it go when an exception
ends the opening - held, the preview showed nothing more until the next launch;
and the row of an image answers at least one frame, so that the next code to
compare the frames with 1 does not meet the 0 again.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print('FAIL:', message)


def member(text, start, end='\n    }\n'):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


pane = (ROOT / 'Horos/Sources/BrowserPreviewPane.swift').read_text(encoding='utf-8')
slider = member(pane, '    func showSliderFrame(sender: Any?) {')
check('PreviewAnimation.sliderFrame(images: list.count' in slider, 'the preview no longer asks the rule what the slider shows')
check('frames == 1' not in slider and 'list.count > 1 ||' not in slider,
      'the preview decides by the frames of the only image again, which a row may give as 0')

rules = (ROOT / 'Modules/IsiXDatabase/Sources/BrowserWindowRules.swift').read_text(encoding='utf-8')
rule = member(rules, '    public static func sliderFrame(')
check('max(Int(objcInt(firstImageFrames())), 1)' in rule, 'an image may have less than one frame again')
tests = (ROOT / 'Modules/IsiXDatabase/Tests/BrowserWindowRulesTests.swift').read_text(encoding='utf-8')
check('NSNumber(value: 0)' in member(tests, '    @Test func frameTheSliderShows() {'),
      'the module test no longer holds the only image of a series whose row says 0 frames')

# The row itself: 0 stored for a file read by the DICOM reader alone, no value
# for one another reader saw first. Both answer one frame.
image = (ROOT / 'Horos/Sources/DicomImage.swift').read_text(encoding='utf-8')
frames = member(image, '    @objc public dynamic var numberOfFrames: NSNumber! {', '\n        set {')
check('if (f?.int32Value ?? 0) < 1 { f = NSNumber(value: Int32(1)) }' in frames,
      'the row of an image answers less than one frame again')

opener = (ROOT / 'Horos/Sources/ViewerOpener.swift').read_text(encoding='utf-8')
selection = member(opener, '    func openSelection(sender: Any?) -> AnyObject? {')
held = selection.index('self.browser.horos_dontUpdatePreviewPane = true')
handler = selection.index('}) {', held)
check('self.browser.horos_dontUpdatePreviewPane = false' in selection[handler:],
      'an exception while a viewer opens leaves the preview held')

if failures:
    sys.exit(1)
print('ok: the preview asks one rule what the slider shows, where the only image of a series is shown whatever '
      'its row says of its frames, and an opening that ends in an exception lets the preview go')
