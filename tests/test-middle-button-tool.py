#!/usr/bin/env python3
"""The middle mouse button uses the tool chosen for it, as the right one does.

- DEFAULTMIDDLETOOL defaults to the move tool, the middle button's only tool
  before it could be chosen.
- -[DCMView getTool:] gives the middle button (number 2) that preference; the
  other buttons of an otherMouse event keep moving the image, and the modifier
  keys still override the tool afterwards.
- -[DCMView otherMouseUp:] ends the click in mouseUp:, as otherMouseDown: starts
  it in mouseDown:, so a ROI drawn with the middle button is finished. The
  plugins get the event from mouseUp:, once.
- Each localized Viewer.xib has a third mouse button radio, tag 2, translated
  from the catalog of its language, and the viewer sends the tool chosen with
  it to DEFAULTMIDDLETOOL.
- In the planes of the 3D MPR and of the curved MPR the right and middle
  buttons have the tools chosen in a 2D viewer, as there: getTool: reads the
  right one through currentToolRight, which a plane answers with
  DEFAULTRIGHTTOOL, read at each press as DEFAULTMIDDLETOOL is, each mapped
  to the move tool when the plane lacks it (IsiXImaging's
  VolumeViewButtons.planeTool). The right button takes the left one's way
  (mouseDown:, mouseDragged:, mouseUp:) instead of going straight to the
  hidden VRView, its double-click is two single presses (only the left one
  fills the window with the plane), its press applies its tool over the cross
  lines too, without grabbing them as the left and middle ones do, and the
  curved MPR's plane takes the focus first, which the window gives only for the
  left press and without which its mouseDown: drops the press. The planes have
  no contextual menu: the right release opens none. A press the plane does not
  draw tells the VRView the button's tool (-mouseDown:withButtonTool:), which its
  rule (VolumeViewButtons.tool) keeps under the modifier keys instead of
  zooming with the right button and panning with the middle one; the volume
  rendering window's own presses give no tool. The curved MPR's planes keep
  the tool of the right or middle press through its drag and release.

Checked in the sources. `<git revision>` as an optional argument reads them
from that revision, the negative control.
"""
import codecs
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
LANGUAGES = ('en', 'ar', 'de', 'fr', 'hi', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')


def raw(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout if result.returncode == 0 else b''
    file = root / path
    return file.read_bytes() if file.is_file() else b''


def read(path):
    return raw(path).decode('latin1').replace('\r\n', '\n')


def body(text, signature):
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


def without_comments(text):
    return '\n'.join(line for line in text.split('\n') if not line.lstrip().startswith('//'))


def catalog(language):
    data = raw(f'Horos/Resources/{language}.lproj/Localizable.strings')
    for bom, encoding in ((codecs.BOM_UTF16_LE, 'utf-16-le'), (codecs.BOM_UTF16_BE, 'utf-16-be'),
                          (codecs.BOM_UTF8, 'utf-8')):
        if data.startswith(bom):
            text = data[len(bom):].decode(encoding)
            break
    else:
        text = data.decode('utf-8')
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))


failures = []

header = read('Horos/Sources/DCMView.h')
translate = re.search(r'tTranslate\s*,\s*//\s*1\b', header)
if not translate or not re.search(r'tWL\s*=\s*0\s*,', header):
    failures.append('tTranslate is no longer tool 1 in DCMView.h')
# The class is Swift (DCMView.swift): the property is declared there, with the
# Objective-C setter's name.
if not re.search(r'@objc public dynamic var currentToolMiddle: ToolMode \{[^}]*\}\s*@objc\(setMiddleTool:\) set',
                 read('Horos/Sources/DCMView.swift')):
    failures.append('DCMView declares no currentToolMiddle property with setMiddleTool:')

sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
if defaults.get('DEFAULTMIDDLETOOL') != '1':
    failures.append('DEFAULTMIDDLETOOL does not default to the move tool (1)')

# The tools and the mouse buttons of DCMView are Swift (DCMView+Tools.swift,
# DCMView+Mouse.swift); the property's accessors (DCMView.swift) call them.
# Which tool a button uses is IsiXImaging's ViewInput rule.
view = without_comments(read('Horos/Sources/DCMView.swift'))
tools = without_comments(read('Horos/Sources/DCMView+Tools.swift'))
mouse = without_comments(read('Horos/Sources/DCMView+Mouse.swift'))
rules = without_comments(read('Modules/IsiXImaging/Sources/ViewInput/InputRules.swift'))
getter = body(tools, 'public dynamic func horosCurrentToolMiddle()')
setter = body(tools, 'public dynamic func horosSetMiddleTool(')
# Through the typed key of DEFAULTMIDDLETOOL (ViewerPreferences.defaultMiddleTool), or the literal before.
reads_middle = 'integer(forKey: "DEFAULTMIDDLETOOL")' in getter or 'preferences[ViewerPreferences.defaultMiddleTool]' in getter
writes_middle = 'forKey: "DEFAULTMIDDLETOOL")' in setter or 'for: ViewerPreferences.defaultMiddleTool)' in setter
if not reads_middle or not writes_middle \
        or not re.search(r'get \{ return self\.horosCurrentToolMiddle\(\) \}\s*@objc\(setMiddleTool:\) set \{ self\.horosSetMiddleTool\(newValue\) \}',
                         body(view, 'public dynamic var currentToolMiddle: ToolMode')):
    failures.append('currentToolMiddle is not read from and written to DEFAULTMIDDLETOOL')

get_tool = body(tools, 'public dynamic func getTool(')
rule = body(rules, 'public static func tool(button: Button')
# The rule names the ToolMode values (1 is tTranslate) and tests the raw bits.
middle = re.search(r'case \.other\(let number\): tool = number == 2 \? middle : 1 // translate', rule)
if 'case .otherMouseDown?, .otherMouseDragged?: button = .other(buttonNumber: event.buttonNumber)' not in get_tool \
        or 'self.currentToolMiddle' not in get_tool or not middle \
        or ('ViewInput.tool(button: button' not in get_tool
            and not ('ViewerToolBindings(' in get_tool and 'bindings.tool(button: button' in get_tool
                     and 'ViewInput.tool(button: button' in without_comments(read('Modules/IsiXImaging/Sources/ViewInput/ViewerToolBindings.swift')))):
    failures.append('getTool: does not give the middle button its tool and the other buttons the move tool')
else:
    modifiers = rule.find('if m & command != 0 { tool = 1 }')
    if modifiers < middle.end():
        failures.append('getTool: no longer applies the modifier keys after choosing the button\'s tool')

other_up = body(mouse, 'public override dynamic func otherMouseUp(with event: NSEvent)')
if 'self.mouseUp(with: event)' not in other_up:
    failures.append('otherMouseUp: does not end the click in mouseUp:')
if 'toPlugins' in other_up:
    failures.append('otherMouseUp: hands the event to the plugins besides mouseUp:')
if 'self.event(toPlugins: event)' not in body(mouse, 'public override dynamic func mouseUp(with event: NSEvent)'):
    failures.append('mouseUp: no longer hands the event to the plugins')
if 'self.mouseDown(with: event)' not in body(mouse, 'public override dynamic func otherMouseDown(with event: NSEvent)'):
    failures.append('otherMouseDown: no longer starts the click in mouseDown:')

notifications = read('Horos/Sources/Notifications.m')
if 'OsirixDefaultMiddleToolModifiedNotification = @"defaultMiddleToolModified"' not in notifications \
        or 'OsirixDefaultMiddleToolModifiedNotification;' not in read('Horos/Sources/Notifications.h'):
    failures.append('OsirixDefaultMiddleToolModifiedNotification is not declared')
# Registered in ViewerController.m, or, since the class is Swift, by the
# viewer's graph as it sets the window up (ViewerSessionGraph+ViewerLife.swift).
if '@selector(defaultMiddleToolModified:) name:OsirixDefaultMiddleToolModifiedNotification' \
        not in read('Horos/Sources/ViewerController.m') \
        and '#selector(ViewerController.defaultMiddleToolModified(_:)), name: .OsirixDefaultMiddleToolModified' \
        not in read('Horos/Sources/ViewerSessionGraph+ViewerLife.swift'):
    failures.append('ViewerController does not observe OsirixDefaultMiddleToolModifiedNotification')

# The viewer's actions hand the Tools item's work to ViewerToolbarItemFactory.
toolbar = without_comments(read('Horos/Sources/ViewerToolbarItemFactory.swift'))
facade = without_comments(read('Horos/Sources/ViewerController+Toolbar.swift'))
if not re.search(r'static let middleButtonTag = 2\b', toolbar):
    failures.append('the toolbar has no middle button radio tag 2')
set_default = body(toolbar, 'func setDefaultTool(_ sender: Any?, in viewer: ViewerController)')
if not re.search(r'case Self\.middleButtonTag: name = \.OsirixDefaultMiddleToolModified', set_default) \
        or 'NotificationCenter.default.post(name: name, object: sender' not in set_default \
        or 'toolbarItems.setDefaultTool(sender, in: self)' not in body(facade, 'func setDefaultTool(_ sender: Any!)'):
    failures.append('setDefaultTool: does not send the tool to the middle button when its radio is chosen')
modified = body(toolbar, 'func defaultMiddleToolModified(_ note: Notification?, in viewer: ViewerController)')
if 'viewer.horos_imageView?.currentToolMiddle = tool' not in modified \
        or 'toolbarItems.defaultMiddleToolModified(note, in: self)' not in body(facade, 'func defaultMiddleToolModified(_ note: Notification!)'):
    failures.append('defaultMiddleToolModified: does not store the middle button\'s tool')
button = body(toolbar, 'func setButtonTool(_ sender: Any?, in viewer: ViewerController)')
if 'currentToolMiddle' not in button or 'button != Self.rightButtonTag' not in button:
    failures.append('setButtonTool: does not show the middle button\'s tool with the ROI tools available')

editing = without_comments(read('Horos/Sources/ViewerController+ROI+Editing.swift'))
# -setROITool: is a façade over ViewerROIToolPalette.choose(from:in:).
if 'ViewerROIToolPalette.choose(from: sender, in: self)' not in body(editing, 'func setROITool(_ sender: Any!)') \
        or 'if viewer.middleButtonSelectedInToolbar' not in body(editing, 'static func choose(from sender: Any?, in viewer: ViewerController)'):
    failures.append('setROITool: gives a ROI tool to the left button while the middle radio is chosen')

english = None
for language in LANGUAGES:
    path = f'Horos/Resources/{language}.lproj/Viewer.xib'
    data = raw(path)
    if not data:
        failures.append(f'{path} is missing')
        continue
    xib = ET.fromstring(data)
    outlet = xib.find(".//outlet[@property='buttonToolMatrix']")
    matrix = xib.find(f".//matrix[@id='{outlet.get('destination')}']") if outlet is not None else None
    if matrix is None:
        failures.append(f'{language}: no buttonToolMatrix')
        continue
    cells = {int(cell.get('tag', '0')): cell.get('title') for cell in matrix.findall('./cells/column/buttonCell')}
    if sorted(cells) != [0, 1, 2]:
        failures.append(f'{language}: the mouse button radios are tags {sorted(cells)}, not 0, 1, 2')
        continue
    if language == 'en':
        english = cells
        if cells[2] != 'Middle Button':
            failures.append(f'en: the third radio reads {cells[2]!r}')
    elif english:
        translations = catalog(language)
        for tag, title in cells.items():
            expected = translations.get(english[tag], english[tag])
            if title != expected:
                failures.append(f'{language}: radio {tag} reads {title!r}, the catalog {expected!r}')

# The planes of the 3D MPR (MPRDCMView) and of the curved MPR (CPRMPRDCMView).
if 'right = self.currentToolRight.rawValue' not in get_tool or 'else if case .right = button' not in get_tool:
    failures.append('getTool: does not read the right button\'s tool through currentToolRight')

buttons = without_comments(read('Modules/IsiXImaging/Sources/ViewInput/VolumeViewButtons.swift'))
plane_rule = body(buttons, 'public static func planeTool(_ tool: Int16, curved: Bool) -> Int16')
if 'return 1 // translate' not in plane_rule or re.search(r'\b8\b', plane_rule.split('default:')[0]):
    failures.append('VolumeViewButtons.planeTool does not move a plane with the tools it lacks, the crosshair among them')
volume_rule = body(buttons, 'public static func tool(button: ViewInput.Button, current: Int16, given: Int16?,')
if 'tool = given' not in volume_rule or volume_rule.find('tool = given') > volume_rule.find('m & control'):
    failures.append('VolumeViewButtons.tool does not keep a given tool under the modifier keys')

prefs = without_comments(read('Horos/Sources/ReconstructionPlanePreferences.swift'))
press = body(prefs, 'func reconstructionPlanePress(_ event: NSEvent) -> NSEvent')
if 'event.type == .rightMouseDown, event.clickCount > 1' not in press or 'clickCount: 1' not in press:
    failures.append('a plane does not take a right double-click as single presses')
for name, path, curved in (('MPRDCMView', 'Horos/Sources/MPRDCMView.swift', 'false'),
                           ('CPRMPRDCMView', 'Horos/Sources/CPRMPRDCMView.swift', 'true')):
    source = without_comments(read(path))
    down = body(source, 'public override dynamic func rightMouseDown(with theEvent: NSEvent)')
    dragged = body(source, 'public override dynamic func rightMouseDragged(with theEvent: NSEvent)')
    up = body(source, 'public override dynamic func rightMouseUp(with theEvent: NSEvent)')
    if 'self.mouseDown(with: reconstructionPlanePress(theEvent))' not in down \
            or 'self.mouseDragged(with: theEvent)' not in dragged or 'self.mouseUp(with: theEvent)' not in up \
            or '_vrView' in down + dragged + up:
        failures.append(f'{name}: the right button does not take the left one\'s way')
    if 'popUpContextMenu' in up:
        failures.append(f'{name}: the release of a right click opens a menu the plane does not have')
    pressed = body(source, 'public override dynamic func mouseDown(with theEvent: NSEvent)')
    if not re.search(r'let mouseOnLines = theEvent\.type == \.rightMouseDown (?:\|\| marksPath )?\? 0 : self\.mouseOnLines\(', pressed):
        failures.append(f'{name}: a right press grabs the cross lines instead of applying the right tool')
    focus = 'if self.window?.firstResponder !== self { self.window?.makeFirstResponder(self) }'
    if name == 'CPRMPRDCMView' and (focus not in down or down.find(focus) > down.find('self.mouseDown(')):
        failures.append(f'{name}: a right press on a plane without the focus is dropped by mouseDown:')
    if not re.search(r'if let tool = self\.volumeButtonTool\(of: theEvent\) \{\s*_vrView\?\.mouseDown\(theEvent, '
                     r'withButtonTool: tool\)\s*\} else \{\s*_vrView\?\.mouseDown\(with: theEvent\)', pressed):
        failures.append(f'{name}: a press of the right or middle button does not tell the VRView its tool')
    extension = body(prefs, f'extension {name} {{')
    right = body(extension, 'public override var currentToolRight: ToolMode')
    middle = body(extension, 'public override var currentToolMiddle: ToolMode')
    if f'planeButtonTool(PreferencesSource.process.preferences[ViewerPreferences.defaultRightTool], curved: {curved})' not in right \
            or f'planeButtonTool(Int(super.currentToolMiddle.rawValue), curved: {curved})' not in middle:
        failures.append(f'{name}: the right and middle tools are not DEFAULTRIGHTTOOL and DEFAULTMIDDLETOOL as the plane has them')
    tools = body(extension, 'func volumeButtonTool(of event: NSEvent) -> ToolMode?')
    if 'case .rightMouseDown: return self.currentToolRight' not in tools \
            or 'case .otherMouseDown: return event.buttonNumber == 2 ? self.currentToolMiddle : .tTranslate' not in tools:
        failures.append(f'{name}: the VRView is not given the right or middle button\'s tool')

cpr = without_comments(read('Horos/Sources/CPRMPRDCMView.swift'))
if 'pressTool = tool' not in body(cpr, 'public override dynamic func mouseDown(with theEvent: NSEvent)') \
        or 'let tool = self.dragTool(theEvent)' not in body(cpr, 'public override dynamic func mouseDragged(with theEvent: NSEvent)') \
        or 'let tool = self.dragTool(theEvent)' not in body(cpr, 'public override dynamic func mouseUp(with theEvent: NSEvent)') \
        or 'theEvent.type == .leftMouseDragged || theEvent.type == .leftMouseUp ? self.getTool(theEvent) : pressTool' \
        not in body(cpr, 'private func dragTool(_ theEvent: NSEvent) -> ToolMode'):
    failures.append('CPRMPRDCMView: the drag or the release of the right or middle button does not keep its press\'s tool')

gestures = without_comments(read('Horos/Sources/VRView+Gestures.swift'))
vr_mouse = without_comments(read('Horos/Sources/VRView+Mouse.swift'))
if 'return getTool(event, buttonTool: nil)' not in body(gestures, 'func getTool(_ event: NSEvent?) -> ToolMode') \
        or 'given: buttonTool?.rawValue' not in body(gestures, 'func getTool(_ event: NSEvent?, buttonTool: ToolMode?) -> ToolMode') \
        or 'press(theEvent, buttonTool: nil)' not in body(vr_mouse, 'public override func mouseDown(with theEvent: NSEvent)') \
        or 'press(theEvent, buttonTool: tool)' not in body(vr_mouse, 'func mouseDown(_ theEvent: NSEvent, withButtonTool tool: ToolMode)') \
        or 'tool = getTool(theEvent, buttonTool: buttonTool)' not in body(vr_mouse, 'private func press(_ theEvent: NSEvent, buttonTool: ToolMode?)') \
        or '- (void) mouseDown:(NSEvent*) event withButtonTool:(ToolMode) tool;' not in read('Horos/Sources/MPRHostMessages.h'):
    failures.append('the VRView does not keep the tool a plane gives the press of its right or middle button')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: the middle mouse button uses its chosen tool through a whole click, and the MPR and CPR planes give the right and middle buttons theirs')
