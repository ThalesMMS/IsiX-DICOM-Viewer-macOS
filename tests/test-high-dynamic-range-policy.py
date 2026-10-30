#!/usr/bin/env python3
"""The high dynamic range question of the VR has "Do not ask again".

Every 3D entry of a CT whose voxel values span more than 8192 asked whether to
clip them to -1024…7168 or resample them. The question
(HorosHighDynamicRangePolicy) now has a suppression check: the answer given with
it becomes the policy - always clip, always resample - kept in
HighDynamicRangePolicy, which a popup of the 3D preferences shows and sets back
to Ask. Resample leaves the values as they are: the volume view maps the whole
range onto its 16-bit scale.

The policy's answer logic is compiled from the source and run; the rest is
checked in the sources and the catalogs.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
policy = (root / 'Horos/Sources/HighDynamicRangePolicy.swift').read_text()
controller = (root / 'Horos/Sources/VRController.swift').read_text()
view = (root / 'Horos/Sources/VRView.swift').read_text()
pane = (root / 'Preference Panes/OSI3DPreferencePane/OSI3DPreferencePane.swift').read_text()
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

# --- the answer logic, run ---------------------------------------------------
enum = policy[policy.index('    @objc(HorosHighDynamicRangeChoice) public enum Policy: Int {'):policy.index('    @objc public static var policy: Policy {')]
answer = policy[policy.index('    public static func policy(afterClipping'):policy.index('    /// Asks, unless the policy already answers')]
driver = 'import Foundation\nenum P {\n' + enum.replace('@objc(HorosHighDynamicRangeChoice) public enum', 'enum') + '\n' + answer.replace('public static', 'static') + '''}
for clip in [true, false] { for remember in [true, false] {
  print("\\(clip) \\(remember) \\(P.policy(afterClipping: clip, remember: remember, current: .ask).rawValue)")
} }
'''
with tempfile.TemporaryDirectory(prefix='horos-dynamic-range-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), '-o', str(work / 'policy')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the answer logic does not compile:\n' + built.stderr[-1500:])
    else:
        out = subprocess.run([str(work / 'policy')], capture_output=True, text=True, timeout=60).stdout.split('\n')
        if out[:4] != ['true true 1', 'true false 0', 'false true 2', 'false false 0']:
            failures.append('a remembered Clip is not "always clip" or a remembered Resample not "always resample": %r' % out[:4])

# --- the wiring --------------------------------------------------------------
should = policy[policy.index('public static func shouldClip'):]
for needed in ('case .alwaysClip: return true', 'case .alwaysResample: return false', 'showsSuppressionButton = true',
               '"Do not ask again"', 'UserDefaults.standard.set(next.rawValue, forKey: defaultsKey)', '"Clip"', '"Resample"'):
    if needed not in should:
        failures.append('the question misses %s' % needed)
start = controller.index('maximumValueStorage - minimumValueStorage > 8192')
minmax = controller[start:controller.index('    @objc(windowDidResize:)', start)]
if 'HighDynamicRangePolicy.shouldClip()' not in minmax or 'HorosAlertPanel' in minmax:
    failures.append('the VR still asks about high dynamic values without the policy')
if 'vImageClip_PlanarF(&srcf, &srcf, 7168, -1024, vImage_Flags(kvImageNoFlags))' not in minmax:
    failures.append('Clip no longer clips to -1024…7168')
if 'MPROpenGeometry.shouldPresentHighDynamicPrompt(duringHiddenInit: styleName == "noNib")' not in controller[start:start + 400]:
    failures.append('a hidden MPR initialisation would ask again')
# What Resample relies on: the view maps a range wider than its scale onto it.
# The method is in VRView+Volume.swift, an extension of the Swift view.
volume = root / 'Horos/Sources/VRView+Volume.swift'
if '- (void) computeValueFactor' in view:
    value_factor = view[view.index('- (void) computeValueFactor'):view.index('- (void) computeValueFactor') + 1200]
    wide = 'valueFactor = MAXDYNAMICVALUE / ([controller maximumValue] - [controller minimumValue]);'
else:
    swift = volume.read_text()
    value_factor = swift[swift.index('func computeValueFactor()'):swift.index('func computeValueFactor()') + 1200]
    wide = 'horos_valueFactor = Float(maxDynamicValue / Double(maximum - minimum))'
if wide not in value_factor:
    failures.append('the volume view no longer maps a wide range onto its scale, so Resample would do nothing')
if 'HighDynamicRangePolicy' not in defaults:
    failures.append('the policy is not registered')
if project.count('HighDynamicRangePolicy.swift in Sources') != 2:
    failures.append('HighDynamicRangePolicy.swift is not built into the application')
row = pane[pane.index('private func addHighDynamicRangeRow()'):pane.index('private func addPolicyRow(')]
if 'HighDynamicRangePolicy.defaultsKey' not in row or '.alwaysClip' not in row or '.alwaysResample' not in row:
    failures.append('the 3D preferences do not show the policy')
if 'addHighDynamicRangeRow()' not in pane[pane.index('public override func mainViewDidLoad()'):pane.index('private func addGantryTiltRow()')]:
    failures.append('the row is not added')

keys = ['High Dynamic Values', 'Clip', 'Resample', 'Do not ask again', 'High dynamic CT values:',
        'Ask before opening a 3D viewer', 'Always clip', 'Always resample',
        'Voxel values have a very high dynamic range (>8192). Two options are available to use the 3D engine: '
        'clip values above 7168 and below -1024 or resample the values.']
for language in ('en', 'it-IT', 'es', 'ja-JP', 'pt-BR', 'fr', 'de', 'ko', 'hi', 'ar', 'ru', 'zh-Hans'):
    path = root / f'Horos/Resources/{language}.lproj/Localizable.strings'
    present = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    missing = [k[:30] for k in keys if k not in present]
    if missing:
        failures.append('%s lacks %s' % (language, missing))

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: the high dynamic range question of the VR can be answered once for all')
