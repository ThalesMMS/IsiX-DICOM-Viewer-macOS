#!/usr/bin/env python3
"""The CPR observes the opacity menu once and releases a failed controller.

The Swift translation of CPRController kept two defects of the Objective-C,
which were already fixed in the MPR:
- -setClippingRangeMode: added another OsirixUpdateOpacityMenu observer at each
  change of mode, never removing the previous one, so that after N changes
  -UpdateOpacityMenu: ran N + 1 times per notification;
- the initializer that failed returned nil without releasing the controller,
  which kept the nib, the notification observers and the hidden VRController.
Checked in the sources:
- the initializer is the only place that observes OsirixUpdateOpacityMenu;
- a failed initializer undoes what would keep the controller alive (the delayed
  performs, the observers, the nib's object controller holding it as content,
  the hidden VRController's two references) and lets the failable initializer
  release it; deinit removes the "plane" observers only if the initializer
  added them;
- the RGB refusal balances its retain with an autorelease, as the former
  [self autorelease] did, and returns before the nib loads.

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


controller = code(read('CPRController'))
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
catch = block(initializer, '} catch {')
if not initializer or not catch:
    failures.append('the initializer or its catch is missing')
if re.search(r'passRetained\(self\)\s*$', controller, re.M):
    failures.append('CPRController retains itself without a balance: the failed initializer leaks the controller')
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

deinit = block(controller, 'deinit {')
if 'observesPlanes = true' not in initialize \
        or initialize.find('observesPlanes = true') < initialize.find('mprView3?.addObserver(self, forKeyPath: "plane"'):
    failures.append('the initializer does not record, after adding them, that it added the "plane" observers')
guarded = block(deinit, 'if observesPlanes {')
unguarded = deinit.replace(guarded, '')
if 'removeObserver(self, forKeyPath: "plane")' not in guarded \
        or 'removeObserver(self, forKeyPath: "plane")' in unguarded:
    failures.append('deinit removes "plane" observers that a failed initializer never added')

# The RGB refusal: before the nib loads, balanced by the autorelease.
refusal = block(initializer, 'if supported == false {')
if 'passRetained(self).autorelease()' not in refusal or 'return nil' not in refusal:
    failures.append('the RGB refusal no longer balances the release of the failable initializer')
rgb = block(initialize, 'if _originalPix?.isRGB')
if 'return false' not in rgb or initialize.find('if _originalPix?.isRGB') > initialize.find('self.window'):
    failures.append('the RGB refusal loads the nib before it returns')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)

print('PASS: the CPR observes the opacity menu once, and releases its failed controller')
