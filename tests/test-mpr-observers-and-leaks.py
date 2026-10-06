#!/usr/bin/env python3
"""The MPR observes the opacity menu once and releases what it made.

The Swift translation of MPRController and MPRDCMView kept, as it was:
- -setClippingRangeMode: added another OsirixUpdateOpacityMenu observer at each
  change of mode, never removing the previous one, so that after N changes
  -UpdateOpacityMenu: ran N + 1 times per notification;
- the initializer that failed returned nil without releasing the controller;
- each view's OSIROIManager was never released;
- each 2D point that -detect2DPointInThisSlice mirrors from the viewer was
  retained once more and never released.
Checked in the sources:
- the initializer is the only place that observes OsirixUpdateOpacityMenu;
- a failed initializer undoes what would keep the controller alive (the
  observers, the nib's object controller holding it as content, the hidden
  VRController's two references) and lets the failable initializer release it;
  deinit removes the key-value observers only if -awakeFromNib added them;
- the view keeps its ROI manager in a strong property;
- the mirrored points are not retained again, and the points taken out of
  curRoiList live until -detect2DPointInThisSlice returns, so that their
  -dealloc, which posts OsirixRemoveROINotification, cannot run the method
  again while it goes through the list.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(name):
    if revision is None:
        return sources.source_text(name)
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/{name}.swift'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def code(text):
    """Without comments, so that what they recall is not taken for code."""
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


controller = code(read('MPRController'))
view = code(read('MPRDCMView'))
failures = []

# The opacity menu observer.
observers = re.findall(r'addObserver\(self,\s*selector:\s*#selector\(UpdateOpacityMenu', controller)
initialize = block(controller, 'private func initialize(pix:')
clipping = block(controller, 'private func setClippingRangeModeValue(')
if not initialize or not clipping:
    failures.append('the initializer body or -setClippingRangeMode: is missing')
if len(observers) != 1 or 'selector(UpdateOpacityMenu' not in initialize:
    failures.append(f'OsirixUpdateOpacityMenu is observed {len(observers)} times, not once in the initializer')
if 'addObserver' in clipping:
    failures.append('-setClippingRangeMode: adds an observer at each change of mode')

# The failed initializer.
initializer = block(controller, 'public convenience init?(dcmPixList')
catch = initializer[initializer.find('} catch {'):]
if 'passRetained(self)' in controller:
    failures.append('MPRController retains itself: the failed initializer leaks the controller')
if 'self.abandonInitialization()' not in catch or 'return nil' not in catch:
    failures.append('the failed initializer does not undo what it did before returning nil')
abandon = block(controller, 'private func abandonInitialization()')
for needed, what in [
        ('ob?.content = nil', 'let the object controller of the nib go of the controller'),
        ('NotificationCenter.default.removeObserver(self)', 'remove the notification observers'),
        ('cancelPreviousPerformRequests(withTarget: self)', 'cancel the delayed performs, which retain the controller'),
        ('controller.close()', 'close the hidden VRController'),
        ('Unmanaged.passUnretained(controller).release()', 'give back the hidden VRController reference'),
        ('hiddenVRController = nil', 'forget the hidden VRController')]:
    if needed not in abandon:
        failures.append(f'the failed initializer does not {what}')
awake = block(controller, 'public override dynamic func awakeFromNib()')
deinit = block(controller, 'deinit {')
if 'observesPresetsAndDefaults = true' not in awake:
    failures.append('-awakeFromNib does not record that it added the key-value observers')
guarded = block(deinit, 'if observesPresetsAndDefaults {')
if 'removeObserver(self, forKeyPath: "values.MPR2DViewsPosition")' not in guarded \
        or 'removeObserver(self, forKeyPath: "selectedObjects"' not in guarded:
    failures.append('deinit removes key-value observers that a failed nib load never added')

# The ROI manager.
if re.search(r'unowned\(unsafe\)\s+var\s+_ROIManager', view):
    failures.append('MPRDCMView does not retain its ROI manager, which it never releases')
if 'passRetained' in block(view, 'private dynamic func ROIManager()'):
    failures.append('MPRDCMView leaks its ROI manager')

# The mirrored 2D points.
detect = block(view, 'public dynamic func detect2DPointInThisSlice()')
if not detect:
    failures.append('-detect2DPointInThisSlice is missing')
if 'passRetained' in detect:
    failures.append('-detect2DPointInThisSlice leaks each 2D point it mirrors')
removal = detect[:detect.find('viewer2D.roiList(')]
if 'removedPoints.append(r)' not in removal or 'withExtendedLifetime(removedPoints)' not in detect:
    failures.append('the 2D points taken out of curRoiList can be released while -detect2DPointInThisSlice goes through it')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)

print('PASS: the MPR observes the opacity menu once, and releases its failed controller, ROI managers and 2D points')
