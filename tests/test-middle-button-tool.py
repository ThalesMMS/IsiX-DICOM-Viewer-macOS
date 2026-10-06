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
if not re.search(r'@property\([^)]*setter=setMiddleTool:[^)]*\) ToolMode currentToolMiddle;', header):
    failures.append('DCMView declares no currentToolMiddle property with setMiddleTool:')

defaults = read('Horos/Sources/DefaultsOsiriX.m')
if not re.search(r'setObject:@"1" forKey:@"DEFAULTMIDDLETOOL"\]', defaults):
    failures.append('DEFAULTMIDDLETOOL does not default to the move tool (1)')

view = without_comments(read('Horos/Sources/DCMView.m'))
getter = body(view, '- (ToolMode) currentToolMiddle')
setter = body(view, '- (void) setMiddleTool:(ToolMode) i')
if 'integerForKey: @"DEFAULTMIDDLETOOL"' not in getter or 'forKey: @"DEFAULTMIDDLETOOL"' not in setter:
    failures.append('currentToolMiddle is not read from and written to DEFAULTMIDDLETOOL')

get_tool = body(view, '- (ToolMode) getTool: (NSEvent*) event')
middle = re.search(r'NSEventTypeOtherMouseDown \|\| \[event type\] == NSEventTypeOtherMouseDragged\)\s*\{?\s*'
                   r'tool = \[event buttonNumber\] == 2 \? self\.currentToolMiddle : tTranslate;', get_tool)
if not middle:
    failures.append('getTool: does not give the middle button its tool and the other buttons the move tool')
else:
    modifiers = get_tool.find('NSEventModifierFlagCommand')
    if modifiers < middle.end():
        failures.append('getTool: no longer applies the modifier keys after choosing the button\'s tool')

other_up = body(view, '-(void)otherMouseUp:(NSEvent*)event')
if '[self mouseUp:event];' not in other_up:
    failures.append('otherMouseUp: does not end the click in mouseUp:')
if 'eventToPlugins' in other_up:
    failures.append('otherMouseUp: hands the event to the plugins besides mouseUp:')
if '[self eventToPlugins:event]' not in body(view, '- (void)mouseUp:(NSEvent *)event'):
    failures.append('mouseUp: no longer hands the event to the plugins')
if '[self mouseDown: event];' not in body(view, '- (void) otherMouseDown:(NSEvent *)event'):
    failures.append('otherMouseDown: no longer starts the click in mouseDown:')

notifications = read('Horos/Sources/Notifications.m')
if 'OsirixDefaultMiddleToolModifiedNotification = @"defaultMiddleToolModified"' not in notifications \
        or 'OsirixDefaultMiddleToolModifiedNotification;' not in read('Horos/Sources/Notifications.h'):
    failures.append('OsirixDefaultMiddleToolModifiedNotification is not declared')
if '@selector(defaultMiddleToolModified:) name:OsirixDefaultMiddleToolModifiedNotification' \
        not in read('Horos/Sources/ViewerController.m'):
    failures.append('ViewerController does not observe OsirixDefaultMiddleToolModifiedNotification')

toolbar = without_comments(read('Horos/Sources/ViewerController+Toolbar.swift'))
if not re.search(r'static let middleButtonTag = 2\b', toolbar):
    failures.append('the toolbar has no middle button radio tag 2')
set_default = body(toolbar, 'func setDefaultTool(_ sender: Any!)')
if not re.search(r'case ViewerController\.middleButtonTag:\s*NotificationCenter\.default\.post\(name: \.OsirixDefaultMiddleToolModified',
                 set_default):
    failures.append('setDefaultTool: does not send the tool to the middle button when its radio is chosen')
modified = body(toolbar, 'func defaultMiddleToolModified(_ note: Notification!)')
if 'self.horos_imageView?.currentToolMiddle = tool' not in modified:
    failures.append('defaultMiddleToolModified: does not store the middle button\'s tool')
button = body(toolbar, 'func setButtonTool(_ sender: Any!)')
if 'currentToolMiddle' not in button or 'button != ViewerController.rightButtonTag' not in button:
    failures.append('setButtonTool: does not show the middle button\'s tool with the ROI tools available')

editing = without_comments(read('Horos/Sources/ViewerController+ROI+Editing.swift'))
if 'if self.middleButtonSelectedInToolbar' not in body(editing, 'func setROITool(_ sender: Any!)'):
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

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: the middle mouse button uses its chosen tool through a whole click')
