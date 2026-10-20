#!/usr/bin/env python3
"""The gantry tilt question has "Do not ask again", and the 3D views say when a tilt was corrected.

Every 3D entry of a tilted series asked whether to correct it. The question
(HorosGantryTiltPolicy) now has a suppression check: the answer given with it
becomes the policy - always correct, never correct - kept in
GantryTiltCorrectionPolicy, which a popup of the 3D preferences shows and sets
back to Ask. A corrected series is recorded for its 2D viewer, and its 3D
views draw "Tilt corrected (x°)" in the lower left corner: the VR family
(VR, MIP, endoscopy) as a text actor of the overlay, the views drawn as 2D
images (MPR, curved MPR, orthogonal MPR) above their lower left lines. A viewer
whose series found the tilt again (reverted) has no mark.

The policy's answer logic is compiled from the source and run; the rest is
checked in the sources and the catalogs.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
policy = (root / 'Horos/Sources/GantryTiltPolicy.swift').read_text()
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
vr = (root / 'Horos/Sources/VRView.mm').read_bytes().decode('latin1')
text = (root / 'Horos/Sources/DCMView+WindowLevel+Coordinates.swift').read_text()
pane = (root / 'Preference Panes/OSI3DPreferencePane/OSI3DPreferencePane.swift').read_text()
defaults = (root / 'Horos/Sources/DefaultsOsiriX.m').read_bytes().decode('latin1')

# --- the answer logic, run ---------------------------------------------------
enum = policy[policy.index('    @objc public enum Policy: Int {'):policy.index('    @objc public static var policy: Policy {')]
answer = policy[policy.index('    public static func policy(afterCorrecting'):policy.index('    /// Asks, unless the policy already answers')]
driver = 'import Foundation\nenum P {\n' + enum.replace('@objc public enum', 'enum') + '\n' + answer.replace('public static', 'static') + '''}
for current in [P.Policy.ask] {
  for correct in [true, false] { for remember in [true, false] {
    print("\\(correct) \\(remember) \\(P.policy(afterCorrecting: correct, remember: remember, current: current).rawValue)")
  } }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-tilt-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', str(work / 'main.swift'), '-o', str(work / 'tilt')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the answer logic does not compile:\n' + built.stderr[-1500:])
    else:
        out = subprocess.run([str(work / 'tilt')], capture_output=True, text=True, timeout=60).stdout.split('\n')
        if out[:4] != ['true true 1', 'true false 0', 'false true 2', 'false false 0']:
            failures.append('a remembered Yes is not "always" or a remembered No not "never": %r' % out[:4])

# --- the wiring --------------------------------------------------------------
should = policy[policy.index('public static func shouldCorrect'):policy.index('// MARK: Corrected viewers')]
for needed in ('case .alwaysCorrect: return true', 'case .neverCorrect: return false', 'showsSuppressionButton = true',
               '"Do not ask again"', 'UserDefaults.standard.set(next.rawValue, forKey: defaultsKey)'):
    if needed not in should:
        failures.append('the question misses %s' % needed)
warning = viewer[viewer.index('-(void) displayWarningIfGantryTitled'):viewer.index('- (void) computeIntervalAsync')]
if 'HorosGantryTiltPolicy shouldCorrectTiltOfDegrees:' not in warning or 'HorosRunInformationalAlertPanel( NSLocalizedString(@"Warning!", nil), @"%@", NSLocalizedString(@"Yes", nil)' in warning:
    failures.append('the 3D entry still asks without the policy')
correction = viewer[viewer.index('+ (void) correctGangtryTilt:'):viewer.index('- (void) refreshMenus')]
if 'HorosGantryTiltPolicy setCorrectedDegrees:' not in correction:
    failures.append('a corrected series is not recorded')
if '!viewer.titledGantry' not in policy:
    failures.append('a reverted series still says it is corrected')
if '"GantryTiltCorrectionPolicy"' not in defaults:
    failures.append('the policy is not registered')
if 'textTilt = vtkTextActor::New();' not in vr or 'HorosGantryTiltPolicy correctedDegreesOfViewer:' not in vr or 'textTilt->Delete();' not in vr:
    failures.append('the VR views do not draw the mark, or leak it')
if 'GantryTiltPolicy.label(degrees:' not in text or 'lowerLeftTop' not in text or '!self.is2DViewer()' not in text:
    failures.append('the MPR views do not draw the mark above their lower left lines')
row = pane[pane.index('private func addGantryTiltRow()'):]
if 'popup.bind(.selectedTag' not in row or 'GantryTiltPolicy.defaultsKey' not in row or row.count('popup.addItem') != 1 \
        or '.alwaysCorrect' not in row or '.neverCorrect' not in row:
    failures.append('the 3D preferences do not show the policy')
if 'addGantryTiltRow()' not in pane[pane.index('public override func mainViewDidLoad()'):]:
    failures.append('the row is not added')

keys = ['Tilt corrected (%0.1f°)', 'Gantry tilt:', 'Ask before opening a 3D viewer', 'Always correct', 'Never correct', 'Do not ask again']
for language in ('en', 'it-IT', 'es', 'ja-JP', 'pt-BR', 'fr', 'de', 'ko', 'hi', 'ar', 'ru', 'zh-Hans'):
    path = root / f'Horos/Resources/{language}.lproj/Localizable.strings'
    present = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    missing = [k for k in keys if k not in present]
    if missing:
        failures.append('%s lacks %s' % (language, missing))

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: the gantry tilt question can be answered once for all, and corrected series say so in their 3D views')
