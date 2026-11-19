#!/usr/bin/env python3
"""Revert Series in the VR window restores the presentation of a first opening.

Besides reading the voxels again (from the files through the 2D viewer, or
from the copy kept before the first filter), Revert Series brings the window
back to what it shows when it opens on a series with no 3D state saved for it:
the 2D viewer's colour table and window level, then the defaults of the
rendering mode, and the shading the window is made with. It used to leave the
window level, the colour table (8-bit and the 16-bit curves), the opacity and
the shading as the user had changed them.

1. The rule, VolumeRenderingOpening (IsiXImaging), compiled as it is with a
   driver: in volume rendering a greyscale series gets "VR Muscles-Bones",
   "Logarithmic Inverse Table" and the shading the preference sets; a MIP keeps
   the 2D viewer's colour table, "Linear Table" ("Logarithmic Table" for a PET
   series) and leaves the shading flag; an RGB series keeps the 2D viewer's
   table in both; the window level is the 2D viewer's; the shading values are
   0.15, 0.9, 0.3 and 15.
   The floating 3D panel has an opening of its own: the colour table it is
   made with ("No CLUT"), "Linear Table" and the 2D viewer's window level; a
   greyscale PET series gets the PET colour table of the preferences,
   "Logarithmic Table" and 3/6 (SUV) or a quarter and a half of the maximum.
2. The rule is the first opening's: the opening applies the 2D viewer's colour
   table and window level before the saved state (ThreeDViewerLauncher), a PET
   series opens on "Logarithmic Table", the saved state's missing colour and
   opacity tables are the rule's, the view is made with the rule's shading
   values and, without a state, turns the shading on as the preference says in
   volume rendering only. The panel opens without the 2D viewer's colour table,
   and a PET series there on the rule's PET table and window.
3. Revert Series ends every path (files, filter copy, a series that cannot be
   read again) by restoring that presentation, from the 2D viewer as it is
   after its own revert (the panel's for the panel). The restore goes through
   the 8-bit colour table (-applyCLUTString:, which empties the 16-bit CLUT
   editor, its undo history and a high-resolution send still pending with it,
   and closes it), the opacity table, the window level (last, so that the
   tables are laid over it), the "Other" window level title, the shading flag
   and values, and the shading preset of those values; it keeps the camera,
   the crop box and the clipping range, which are Reset to Initial View's.
4. The opacity tables are named as the presets are, in English in every
   language: a translated "Logarithmic Inverse Table" (pt-BR, de, fr...) is no
   preset, and -applyOpacityString: took it as the current table without
   changing the volume.

`<git revision>` as an optional argument reads the files from that revision:
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
RULE = 'Modules/IsiXImaging/Sources/ViewerReconstruction/VolumeRenderingOpening.swift'


def read(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else ''
    file = root / path
    return file.read_text() if file.exists() else ''


def read_all(pattern):
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', revision,
                                         'Horos/Sources/']).decode().split()
    else:
        names = [str(p.relative_to(root)) for p in (root / 'Horos/Sources').glob('*.swift')]
    return ''.join(read(name) for name in sorted(names) if re.fullmatch(pattern, name))


def method(text, signature):
    match = re.search(re.escape(signature) + r'.*?\n    }\n', text, re.S)
    return match.group(0) if match else ''


def code(text):
    """The text without its comments."""
    return re.sub(r'//[^\n]*', '', text)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []
rule = read(RULE)
controller = read_all(r'Horos/Sources/VRController(\+\w+)?\.swift')
view = read_all(r'Horos/Sources/VRView(\+\w+)?\.swift')
launcher = read('Horos/Sources/ThreeDViewerLauncher.swift')
if not controller or not view or not launcher:
    print('FAIL: the VR window or the launcher is missing')
    sys.exit(1)

# 1. The rule, compiled as it is.
DRIVER = r'''
let pref = VolumeRenderingOpening(volumeRendering: true, isRGB: false, isPET: false, viewerColourTable: "Hot Iron",
                                  viewerWindowLevel: 40, viewerWindowWidth: 400, defaultShading: true)
precondition(pref.colourTable == "VR Muscles-Bones" && pref.opacityTable == .logarithmicInverse, "VR greyscale: \(pref)")
precondition(pref.windowLevel == 40 && pref.windowWidth == 400, "VR: the 2D viewer's window level")
precondition(pref.shading == true, "VR: the shading of the preference")
let off = VolumeRenderingOpening(volumeRendering: true, isRGB: false, isPET: true, viewerColourTable: "PET",
                                 viewerWindowLevel: 3, viewerWindowWidth: 6, defaultShading: false)
precondition(off.colourTable == "VR Muscles-Bones" && off.opacityTable == .logarithmicInverse && off.shading == false,
             "VR PET: the mode's tables, the shading off: \(off)")
let mip = VolumeRenderingOpening(volumeRendering: false, isRGB: false, isPET: false, viewerColourTable: "Hot Iron",
                                 viewerWindowLevel: -500, viewerWindowWidth: 1500, defaultShading: true)
precondition(mip.colourTable == "Hot Iron" && mip.opacityTable == .linear && mip.shading == nil, "MIP: \(mip)")
precondition(mip.windowLevel == -500 && mip.windowWidth == 1500, "MIP: the 2D viewer's window level")
let pet = VolumeRenderingOpening(volumeRendering: false, isRGB: false, isPET: true, viewerColourTable: "PET",
                                 viewerWindowLevel: 3, viewerWindowWidth: 6, defaultShading: true)
precondition(pet.colourTable == "PET" && pet.opacityTable == .logarithmic, "MIP PET: \(pet)")
for volumeRendering in [true, false] {
    let rgb = VolumeRenderingOpening(volumeRendering: volumeRendering, isRGB: true, isPET: true, viewerColourTable: "No CLUT",
                                     viewerWindowLevel: 128, viewerWindowWidth: 256, defaultShading: true)
    precondition(rgb.colourTable == "No CLUT" && rgb.opacityTable == .linear, "RGB: \(rgb)")
}
let values = VolumeRenderingOpening.shadingValues
precondition(values == .init(ambient: 0.15, diffuse: 0.9, specular: 0.3, specularPower: 15), "shading values \(values)")
func panel(isPET: Bool, isRGB: Bool = false, suv: Bool = false, table: String? = "PET") -> VolumeRenderingOpening {
    .panel(volumeRendering: false, isRGB: isRGB, isPET: isPET, noColourTable: "No CLUT", petColourTable: table,
           suvConverted: suv, maximumValue: 8000, viewerWindowLevel: 40, viewerWindowWidth: 400, defaultShading: true)
}
let plain = panel(isPET: false)
precondition(plain.colourTable == "No CLUT" && plain.opacityTable == .linear && plain.shading == nil
             && plain.windowLevel == 40 && plain.windowWidth == 400, "panel: \(plain)")
precondition(panel(isPET: true, isRGB: true) == plain, "panel RGB PET")
let petPanel = panel(isPET: true)
precondition(petPanel.colourTable == "PET" && petPanel.opacityTable == .logarithmic
             && petPanel.windowLevel == 2000 && petPanel.windowWidth == 4000, "panel PET: \(petPanel)")
let suvPanel = panel(isPET: true, suv: true)
precondition(suvPanel.windowLevel == 3 && suvPanel.windowWidth == 6, "panel PET SUV: \(suvPanel)")
precondition(panel(isPET: true, table: nil).colourTable == "No CLUT", "panel PET without a PET table")
precondition(VolumeRenderingOpening.petColourTable(clutMode: "B/W Inverse", defaultTable: "PET") == "B/W Inverse"
             && VolumeRenderingOpening.petColourTable(clutMode: "Default", defaultTable: "PET") == "PET", "PET table")
print("PASS: the opening's tables, window level and shading for VR, MIP, PET and RGB, and the panel's")
'''
if not rule:
    failures.append(f'{RULE}: the presentation of a first opening is missing')
else:
    with tempfile.TemporaryDirectory(prefix='horos-vr-opening-') as directory:
        p = Path(directory)
        (p / 'VolumeRenderingOpening.swift').write_text(rule)
        (p / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(p / 'VolumeRenderingOpening.swift'),
                                str(p / 'main.swift'), '-o', str(p / 'test')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the rule does not compile on its own:\n' + built.stderr[-2000:])
        else:
            ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
            print(ran.stdout.strip())
            if ran.returncode != 0:
                failures.append('the rule: ' + (ran.stderr.strip()[-800:] or 'the driver failed'))

# 2. The rule is the first opening's.
prepare = code(method(launcher, '    private func prepareNewRenderer(_ renderer: VRController?) {'))
order = [prepare.find('renderer?.applyCLUTString(viewer.horos_backCurCLUTMenu ?? viewer.horos_curCLUTMenu)'),
         prepare.find('renderer?.setWLWW(shown.level, shown.width)'), prepare.find('renderer?.load3DState()')]
if -1 in order or order != sorted(order):
    failures.append('the opening: the 2D viewer\'s colour table, then its window level, then the saved state')
window = code(method(launcher, '    func volumeRenderingWindow(mode: String?) -> VRController? {'))
if 'renderer?.applyOpacityString("Logarithmic Table")' not in window or 'prepareNewRenderer(renderer)' not in window:
    failures.append('the opening: a PET series opens on "Logarithmic Table", then the common preparation')
saved = code(method(controller, '    private func applySavedState() {'))
if 'VolumeRenderingOpening.modeColourTable(' not in saved or 'VolumeRenderingOpening.modeOpacityTable(' not in saved:
    failures.append('the saved state: the colour and opacity tables it lacks must be the rule\'s')
if '"VR Muscles-Bones"' in saved or '"Logarithmic Inverse Table"' in saved:
    failures.append('the saved state: the mode\'s tables only through the rule')
volume = code(read('Horos/Sources/VRView+Volume.swift'))
if 'setShadingValues(0.15' in volume or \
        not re.search(r'= VolumeRenderingOpening\.shadingValues\s*\n\s*setShadingValues\(', volume):
    failures.append('the view: made with the rule\'s shading values')
state = method(code(view), '    func set3DStateDictionary(_ dict: [AnyHashable: Any]?) {')
if not re.search(r'\} else \{\s*if renderingMode == 0 && vtk\.hasProperty \{[^}]*'
                 r'VolumeRenderingPreferences\.defaultShading', state):
    failures.append('the view without a state: the shading of the preference, in volume rendering only')
panel = code(method(launcher, '    func openVolumeRenderingPanel(_ sender: Any?) {'))
pet_table = code(method(launcher, '    private func applyPETColourTable(to target: AnyObject?) {'))
made = code(method(controller, '    private final func finishInit(renderingMode: String?) -> Bool {'))
if not panel or 'horos_curCLUTMenu' in panel or 'horos_backCurCLUTMenu' in panel or 'prepareNewRenderer' in panel:
    failures.append('the panel\'s opening: without the 2D viewer\'s colour table')
if 'renderer?.setWLWW(3, 6)' not in panel or \
        'renderer?.setWLWW(firstAtTime.maxValueOfSeries / 4, firstAtTime.maxValueOfSeries / 2)' not in panel or \
        'applyPETColourTable(to: renderer)' not in panel or 'renderer?.applyOpacityString("Logarithmic Table")' not in panel:
    failures.append('the panel\'s opening: a PET series on the PET table, "Logarithmic Table" and 3/6 or max/4, max/2')
if 'preferences[ViewerPreferences.petCLUTMode], "B/W Inverse")' not in pet_table or \
        '? "B/W Inverse" : preferences[ViewerPreferences.petDefaultCLUT]' not in pet_table:
    failures.append('the panel\'s opening: the PET table is "B/W Inverse" in that mode, otherwise the default PET table')
if 'horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")' not in made or \
        'horos_curOpacityMenu = NSLocalizedString("Linear Table", comment: "")' not in made:
    failures.append('the window is made with "No CLUT" and "Linear Table"')

# 3. Revert Series restores it and keeps the camera.
revert = code(method(controller, '    public final func revertSeries(_ sender: Any!) {'))
if not revert:
    failures.append('Revert Series is missing')
else:
    # A revert refused because the files of the series changed restores nothing: it is the one way out before.
    refusal = 'if horosRevertRefusedForChangedFiles() { return }'
    if 'restoreOpeningPresentation()' not in revert or re.search(r'\breturn\b', revert.replace(refusal, '', 1)):
        failures.append('Revert Series: every path must end with -restoreOpeningPresentation, none may return before it')
    elif revert.find('restoreOpeningPresentation()') < max(revert.find('.OsirixRevertSeries'),
                                                         revert.find('horosRestoreVolumeBeforeFilter()')):
        failures.append('Revert Series: the presentation after the voxels, from the 2D viewer as its revert leaves it')
restore = code(method(controller, '    final func restoreOpeningPresentation() {'))
reading = code(method(controller, '    private func openingPresentation() -> VolumeRenderingOpening {'))
if not restore or not reading:
    failures.append('-restoreOpeningPresentation, or the opening it reads (-openingPresentation), is missing')
else:
    steps = ['let opening = openingPresentation()', 'applyCLUTString(opening.colourTable)',
             'applyOpacityString(opacityName(opening.opacityTable))',
             'setWLWW(opening.windowLevel, opening.windowWidth)', 'applyWLWW(for: NSLocalizedString("Other", comment: ""))',
             'vrView?.activateShading(shading)', 'VolumeRenderingOpening.shadingValues', 'vrView?.setShadingValues(',
             'horosShowShading()', 'findShadingPreset(self)']
    places = [restore.find(step) for step in steps]
    for step, place in zip(steps, places):
        if place < 0:
            failures.append(f'-restoreOpeningPresentation: {step} is missing')
    if -1 not in places and places != sorted(places):
        failures.append('-restoreOpeningPresentation: the tables, then the window level, then the shading and its preset')
    for source in ['viewer2DStorage?.imageView()', 'horos_backCurCLUTMenu ?? $0.horos_curCLUTMenu',
                   'viewerIsEqualToString(viewer2DStorage?.modality(), "PT")', 'VolumeRenderingPreferences.defaultShading',
                   'vrView?.mode() == 0', 'first?.isRGB', 'VolumeRenderingOpening(volumeRendering:']:
        if source not in reading:
            failures.append(f'-openingPresentation: reads {source} as the opening does')
    panel_branch = re.search(r'if styleName == "panel" \{(.*?)\n        \}', reading, re.S)
    if not panel_branch:
        failures.append('-openingPresentation: the floating 3D panel gets its own opening')
    else:
        for source in ['.panel(', 'VolumeRenderingOpening.petColourTable(clutMode: preferences[ViewerPreferences.petCLUTMode]',
                       'defaultTable: preferences[ViewerPreferences.petDefaultCLUT]',
                       'viewer2DStorage?.imageView()?.curDCM?.suvConverted', 'maxValueOfSeries',
                       'pixLists[Int(curMovieIndexStorage)]', 'noColourTable: noColourTable']:
            if source not in panel_branch.group(1):
                failures.append(f'-openingPresentation, the panel: reads {source} as the panel\'s opening does')
    kept = re.findall(r'resetImage|set3DStateDictionary|[Cc]amera|[Cc]lip|[Cc]rop|saView|axView|coView|goToCenter|'
                      r'setLOD|[Pp]rojection|[Vv]iewAngle|setBlending', restore + reading)
    if kept:
        failures.append(f'-restoreOpeningPresentation must keep the camera, the crop box and the clipping range: {sorted(set(kept))}')
clut = code(method(controller, '    public override func applyCLUTString(_ str: String!) {'))
cleanup = clut.find('clutOpacityView?.cleanup()')
if cleanup < 0 or cleanup > clut.find('vrView?.setCLUT(') or 'clutOpacityDrawerOutlet?.close()' not in clut:
    failures.append('an 8-bit colour table empties and closes the 16-bit CLUT editor before it reaches the view')
editor = code(method(read('Horos/Sources/CLUTOpacityView.swift'), '    @objc public func cleanup() {'))
if 'forgetUndoHistory()' not in editor or \
        'NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setCLUTtoVRViewHighRes), object: nil)' not in editor:
    failures.append('the 16-bit CLUT editor emptied by a colour table forgets its undo history and its pending '
                    'high-resolution send, which would put the emptied curves back on the volume')

# 4. The opacity tables by their presets' English names.
names = code(method(controller, '    private func opacityName(_ table: VolumeRenderingOpening.OpacityTable) -> String {'))
for case in ['case .linear: return NSLocalizedString("Linear Table", comment: "")',
             'case .logarithmic: return "Logarithmic Table"',
             'case .logarithmicInverse: return "Logarithmic Inverse Table"']:
    if case not in names:
        failures.append(f'the opacity tables by the presets\' names: {case}')
apply = code(method(controller, '    public override func applyOpacityString(_ str: String!) {'))
presets = read('Modules/IsiXPreferences/Sources/DefaultPreferences+ImagePresets.swift')
if 'if AnyLanguage.says(str, "Linear Table")' not in apply or 'opacityTablePresets[str]' not in apply or \
        '"Logarithmic Inverse Table": OpacityTablePreset(' not in presets:
    failures.append('premise: the opacity presets are found by their English names, only "Linear Table" translated')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: Revert Series restores the 2D viewer\'s colour table and window level with the mode\'s tables and shading, '
      'as a first opening without a saved state, and keeps the camera')
