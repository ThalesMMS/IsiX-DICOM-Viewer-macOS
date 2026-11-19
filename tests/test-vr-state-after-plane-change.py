#!/usr/bin/env python3
"""A VR window opened on a series keeps its 3D state after its 2D viewer changes plane; so does the endoscopy window.

The VR (or MIP) window writes its state when it goes (the camera and its
clipping range, the shading, the window level, the colour and opacity tables,
the 16-bit CLUT curves) and reads it when it opens, in
VRMIP-<mode>-<the first file's unique name>; the endoscopy window does the
same with its own state (the camera and its clipping range, the window level,
the colour and opacity tables; its opening applies the Endoscopy shading
preset over the saved shading) in VRENDOSCOPY-<the first file's unique name>.
Both did it only while their 2D viewer was not post-processed. A change of
plane with the window open gives the 2D viewer resliced slices and makes it
post-processed, but leaves the window the slices it opened on
(PreviousSeriesHold): the window, still showing the series, lost on close
everything that had been adjusted.

The window now asks what it recorded when it opened (horosSlicesFromFiles: its
2D viewer was not post-processed then), not what its 2D viewer is now. The
endoscopy window, given its volume by its own initializer (horosReinit), makes
the same records there (with the slices' geometry, when the VR window records
it, which the scissors restore asks), and its own -save3DState and
-load3DState ask the same rule and nothing else of the 2D viewer: they leave
only through the guards on the rule and on the file list, and give the view
the state read. A window opened on an already resliced 2D viewer still
neither writes nor reads a state: its volume is not the series, while a
resliced slice's file, and so the state's name, is the series' first. A
window given no 2D viewer (a plugin's) writes and reads its state as before.

The rule is compiled as each window has it (its record at opening and
-horosStateIsSeries) on a stand-in viewer and driven through the cases: opened
on the axial series then changed to coronal, opened on a resliced viewer, and
opened without a viewer. The rest is read from the sources: the change of
plane that keeps the former series for the other windows, the resliced slices'
files, the state loaded after the window is made, and each window's writing
and reading of its state gated on the rule alone. `<git revision>` as an
optional argument reads the files from that revision: the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the compiler
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else ''
    file = root / path
    return file.read_text() if file.exists() else ''


def read_controller():
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', revision,
                                         'Horos/Sources/']).decode().split()
    else:
        names = [str(p.relative_to(root)) for p in (root / 'Horos/Sources').glob('VRController*.swift')]
    return ''.join(read(name) for name in sorted(names) if re.fullmatch(r'Horos/Sources/VRController(\+\w+)?\.swift', name))


def method(text, signature):
    match = re.search(re.escape(signature) + r'.*?\n    }\n', text, re.S)
    return re.sub(r'//[^\n]*', '', match.group(0)) if match else ''


def conditions(text):
    """The conditions of a guard, split at its top-level commas, whitespace collapsed."""
    parts, depth, current = [], 0, ''
    for character in text:
        depth += character in '([{'
        depth -= character in ')]}'
        if character == ',' and depth == 0:
            parts.append(current)
            current = ''
        else:
            current += character
    return [' '.join(part.split()) for part in parts + [current]]


def leaves_only_through(body, allowed):
    """Whether `body` returns only from `guard ... else { return }` on the `allowed` conditions:
    no other exit, a condition on the 2D viewer for instance, keeps it from writing."""
    guards = re.findall(r'\bguard\s+(.*?)\s+else\s*\{\s*return\s*\}', body, re.S)
    return len(re.findall(r'\breturn\b', body)) == len(guards) and \
        all(condition in allowed for guard in guards for condition in conditions(guard))


def gives_view_state_read(body, reading):
    """Whether `body` gives the view the state `reading` read, as read, with no way out before."""
    given = re.search(r'\.set3DStateDictionary\(\s*dict\s+as\?\s*\[AnyHashable:\s*Any\]\s*\)', body)
    return bool(given) and reading.start() < given.start() and not re.search(r'\breturn\b', body[:given.start()])


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []

# The scenario: a change of plane in place makes the 2D viewer post-processed
# and lets the windows on its volume keep the former slices.
reslice = method(read('Horos/Sources/ViewerController+Reslice.swift'), '    func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool {')
if 'keepingPreviousSeriesForOtherWindows { changeImageData(' not in reslice or 'setPostprocessed(true)' not in reslice:
    failures.append('premise: a change of plane in place makes the 2D viewer post-processed and lets the other windows keep the former series')
hold = method(read('Horos/Sources/ViewerSeriesLoad.swift'), '    private func holdSeriesForOtherWindows() -> [AnyObject] {')
if 'viewer.horos_pixList(at: movie)' not in hold or 'PreviousSeriesHold.hold(series, releasedBy: viewer, for: window)' not in hold:
    failures.append('premise: the windows on the volume hold the former slices')
# A resliced slice's file is the series' first: a window opened on a resliced
# viewer would write under the name of the series' state.
if 'if let firstFile { files.append(firstFile) }' not in read('Horos/Sources/ViewerSeriesReslice.swift'):
    failures.append('premise: a resliced slice\'s file is the series\' first file')

controller = read_controller()
state_file = method(controller, '    final func stateFile(in path: String) -> String? {')
if '(fileListStorage?.firstObject as AnyObject?)?.value(forKey: "uniqueFilename")' not in state_file:
    failures.append('premise: the state is named by the window\'s own first file, which a change of plane does not change')
if not re.search(r'isolated deinit \{.*?save3DState\(\)', controller, re.S):
    failures.append('premise: the window writes its state when it goes')

# The state is read once the window recorded what it opened on.
launcher = read('Horos/Sources/ThreeDViewerLauncher.swift')
window = method(launcher, '    func volumeRenderingWindow(mode: String?) -> VRController? {')
prepare = method(launcher, '    private func prepareNewRenderer(_ renderer: VRController?) {')
panel = method(launcher, '    func openVolumeRenderingPanel(_ sender: Any?) {')
if not (-1 < window.find('makeVRController(') < window.find('prepareNewRenderer(renderer)')) or \
        'renderer?.load3DState()' not in prepare or \
        not (-1 < panel.find('makeVRController(') < panel.find('renderer?.load3DState()')):
    failures.append('premise: a VR or MIP window reads its state after it is made')

adopt = method(controller, '    private final func adoptVolume(')
record = re.search(r'horosSlicesFromFiles = [^\n]*', adopt)
if not record or adopt.find('viewer2DStorage = vC') < 0 or adopt.find('horosSlicesFromFiles') > adopt.find('finishInit('):
    failures.append('the window must record at opening whether its 2D viewer was post-processed')
if len(re.findall(r'\bviewer2DStorage = ', controller)) != 1:
    failures.append('the VR window gives itself its 2D viewer once, when it opens: a window without one never had one')
if len(re.findall(r'^\s*(?:self\.)?horosSlicesFromFiles = ', controller, re.M)) != 1:
    failures.append('the record of the opening is made once, when the window opens: nothing changes it afterwards')
# The endoscopy window, the one subclass, is given its volume and its 2D
# viewer by its own initializer (horosReinit), and writes and reads its own
# state in its own -save3DState and -load3DState: it records its opening there,
# where it is given its 2D viewer, and asks the same rule.
endoscopy = read('Horos/Sources/EndoscopyVRController.swift')
endoscopy_viewer = read('Horos/Sources/EndoscopyViewer.swift')
close = method(endoscopy_viewer, '    private dynamic func CloseViewerNotification(')
if 'if PreviousSeriesHold.window(self, keepsSeriesReleasedBy: note) { return }' not in close:
    failures.append('premise: the endoscopy window keeps the slices its 2D viewer releases on a change of plane')
opening = method(endoscopy_viewer, '    public convenience init!(pixList pix:')
if not (-1 < opening.find('vrController?.horosReinit(') < opening.find('vrController?.load3DState()')):
    failures.append('premise: the endoscopy window reads its state once it is given its volume')
reinit = method(endoscopy, '    public func horosReinit(')
endoscopy_record = re.search(r'horosSlicesFromFiles = [^\n]*', reinit)
if not endoscopy_record or not (-1 < reinit.find('viewer2DStorage = vC') < endoscopy_record.start() < reinit.find('return true')):
    failures.append('the endoscopy window must record, where it is given its 2D viewer, whether that viewer was post-processed')
if len(re.findall(r'\bviewer2DStorage = ', endoscopy)) != 1 or \
        len(re.findall(r'^\s*(?:self\.)?horosSlicesFromFiles = ', endoscopy, re.M)) != 1:
    failures.append('the endoscopy window gives itself its 2D viewer, and records its opening, once: when it is given its volume')
endoscopy_save = method(endoscopy, '    public override func save3DState() {')
endoscopy_load = method(endoscopy, '    public override func load3DState() {')
if 'let files = horosFileList()' not in endoscopy_save or 'endoscopyStatePath(files, in:' not in endoscopy_save or \
        'endoscopyStatePath(horosFileList(), in:' not in endoscopy_load:
    failures.append('premise: the endoscopy state is named by the window\'s own first file, which a change of plane does not change')
# The VR window records at opening the geometry its slices were read with,
# which its scissors restore compares: the endoscopy window, whose scissors
# restore asks the same, records it where it is given its slices.
if 'horosRecordSliceGeometry()' in adopt and \
        not (-1 < reinit.find('pixLists[0] = pix') < reinit.find('horosRecordSliceGeometry()') < reinit.find('return true')):
    failures.append('the endoscopy window must record, as the VR window does, the geometry its slices were read with '
                    'when it is given them: without it the scissors restore (Tab) is always refused')
endoscopy_gate = re.search(r'\n\s*guard horosStateIsSeries\(\)\s*(?:,|else)', endoscopy_save)
# Written at the method's own level, not inside another condition.
endoscopy_write = re.search(r'\n {8}if let str(?: = str)? \{\s*dict\?\.write\(toFile:\s*str,\s*atomically:\s*true\)\s*\}', endoscopy_save)
if not endoscopy_gate or not endoscopy_write or endoscopy_gate.start() > endoscopy_save.find('endoscopyStatePath(') or \
        not leaves_only_through(endoscopy_save, {'horosStateIsSeries()', 'let files = horosFileList()', 'files.count > 0'}):
    failures.append('the endoscopy window\'s -save3DState: writes the state when the window holds the series, '
                    'whatever its 2D viewer shows now')
endoscopy_reading = re.search(r'let dict: NSDictionary\? = horosStateIsSeries\(\)\s*\?\s*'
                              r'str\.flatMap\s*\{\s*NSDictionary\(contentsOfFile:\s*\$0\)\s*\}\s*:\s*nil', endoscopy_load)
if not endoscopy_reading or not gives_view_state_read(endoscopy_load, endoscopy_reading):
    failures.append('the endoscopy window\'s -load3DState: reads the state only when the window holds the series, '
                    'whatever its 2D viewer shows now')

rule = method(controller, '    final func horosStateIsSeries() -> Bool {')
if not rule:
    failures.append('the window must say whether its state is the series\' (-horosStateIsSeries)')

save = method(controller, '    public func save3DState() {')
if not re.search(r'public func save3DState\(\) \{\s*guard horosStateIsSeries\(\) else \{\s*return\s*\}', save) or \
        not re.search(r'\n {8}dict\.write\(toFile:\s*str,\s*atomically:\s*true\)', save) or \
        not leaves_only_through(save, {'horosStateIsSeries()', 'let str = stateFile(in: path)',
                                       'let dict = vrView?.get3DStateDictionary()'}):
    failures.append('-save3DState: writes the state when the window holds the series, whatever its 2D viewer shows now')
apply = method(controller, '    private func applySavedState() {')
reading = re.search(r'let dict: NSDictionary\? = horosStateIsSeries\(\)\s*\?\s*'
                    r'str\.flatMap\s*\{\s*NSDictionary\(contentsOfFile:\s*\$0\)\s*\}\s*:\s*nil', apply)
if not reading or not gives_view_state_read(apply, reading):
    failures.append('reading the state: only when the window holds the series, whatever its 2D viewer shows now')
for name, body in [('-save3DState', save), ('reading the state', apply),
                   ('the endoscopy window\'s -save3DState', endoscopy_save),
                   ('the endoscopy window\'s -load3DState', endoscopy_load)]:
    if 'postprocessed()' in body:
        failures.append(f'{name} must not ask the 2D viewer whether it is post-processed now: a change of plane makes it so')
    if re.search(r'\bviewer2D(?:Storage)?\b', body):
        failures.append(f'{name} must not ask the 2D viewer anything: the record of the opening (-horosStateIsSeries) '
                        'says whether the state is the series\'')

# The rule as each window has it, on a stand-in viewer, through the cases.
if record and rule:
    windows = [('Window', 'VR window', record)]
    if endoscopy_record:
        windows.append(('EndoscopyWindow', 'endoscopy window', endoscopy_record))
    stand_in = '''
final class Viewer {
    var processed: Bool
    init(_ processed: Bool) { self.processed = processed }
    func postprocessed() -> Bool { processed }
}
''' + ''.join(f'''
final class {name} {{
    var viewer2DStorage: Viewer?
    var horosSlicesFromFiles = false
    init(_ vC: Viewer?) {{
        viewer2DStorage = vC
        {made.group(0)}
    }}
{rule}}}
''' for name, _, made in windows)
    driver = r'''
func check(_ window: String, _ make: (Viewer?) -> () -> Bool) {
    // Opened on the axial series: the state is the series'.
    let axial = Viewer(false)
    let opened = make(axial)
    precondition(opened(), "\(window): opened on the series")
    // The 2D viewer changes to coronal: the window keeps the series, and its state.
    axial.processed = true
    precondition(opened(), "\(window): after a change of plane")
    // Opened on a 2D viewer already resliced: never, even once the viewer shows a series again.
    let coronal = Viewer(true)
    let resliced = make(coronal)
    precondition(!resliced(), "\(window): opened on a resliced viewer")
    coronal.processed = false
    precondition(!resliced(), "\(window): opened on a resliced viewer that shows a series later")
    // Without a 2D viewer (a plugin's window): as before.
    precondition(make(nil)(), "\(window): without a 2D viewer")
}
''' + ''.join(f'check("{label}") {{ {name}($0).horosStateIsSeries }}\n' for name, label, _ in windows) + 'print("rule ok")\n'
    with tempfile.TemporaryDirectory(prefix='horos-vr-state-') as directory:
        p = Path(directory)
        (p / 'Window.swift').write_text(stand_in)
        (p / 'main.swift').write_text(driver)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(p / 'Window.swift'), str(p / 'main.swift'),
                                '-o', str(p / 'rule')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the window\'s rule does not compile on its own: ' + built.stderr.strip()[:400])
        else:
            ran = subprocess.run([str(p / 'rule')], capture_output=True, text=True)
            if ran.returncode != 0:
                failures.append('the window\'s rule: ' + (ran.stderr.strip().splitlines() or ['failed'])[-1][:300])

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a VR, MIP or endoscopy window opened on a series writes and reads its 3D state after its 2D viewer '
      'changes plane (the record of its opening, not the viewer\'s state now); one opened on a resliced viewer neither '
      'writes nor reads it, and one without a viewer does as before')
