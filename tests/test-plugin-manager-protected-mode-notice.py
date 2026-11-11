#!/usr/bin/env python3
"""The Plugins Manager says in full why every plugin reads Blocked.

After a crash inside a plugin the app opens once without plugins (protected
mode), and the manager lists each one as Blocked. The reason was a label of the
nib: one line, 319 points wide, clipped. "Plugins are not loaded in protected
mode" fits it in English only; the Portuguese sentence ended at "modo pro", and
the German, French and Russian ones were cut as well. Nothing said that the
plugins come back the next time the app opens.

The controller now sets the label from the catalog, with what to do, and lays
it out on the width of the list with word wrapping. Checked here:
- the controller does so, and no longer just unhides the nib's label;
- the sentence is in the eleven catalogs, translated;
- each translation, measured by AppKit in the label's font, fits the width of
  the list in the height left between the list and the buttons.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
KEY = ('Protected Mode: plugins are not loaded in this session. '
       'Quit IsiX DICOM Viewer and open it again to load them.')
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')

controller = (root / 'Horos/Sources/PluginManagerController.swift').read_text()
at = controller.find('private func showProtectedModeNotice()')
notice = controller[at:controller.find('\n    }\n', at)] if at >= 0 else ''
if not notice or 'showProtectedModeNotice()\n' not in controller[:at]:
    failures.append('the manager no longer sets the protected mode notice when it opens')
else:
    if 'NSLocalizedString("%s"' % KEY not in notice:
        failures.append('the notice is not the catalog sentence that says how to get the plugins back')
    for needed, why in (('label.cell?.wraps = true', 'the notice does not wrap'),
                        ('label.cell?.isScrollable = false', 'the notice is still a scrollable single line'),
                        ('label.maximumNumberOfLines = 0', 'the notice is limited to a number of lines'),
                        ('container.bounds.width', 'the notice does not take the width of the tab')):
        if needed not in notice:
            failures.append(why)


def number(name):
    found = re.search(r'static let %s: CGFloat = (\d+)' % name, controller)
    return int(found.group(1)) if found else None


inset, height = number('protectedModeNoticeInset'), number('protectedModeNoticeHeight')
if inset is None or height is None:
    failures.append('the notice has no declared margin and height')

# The tab's view, of which the notice takes the width, in the nib.
nib = (root / 'Horos/Resources/en.lproj/PluginManager.xib').read_text()
tab = re.search(r'<tabViewItem label="Installed Plugins".*?<rect key="frame" x="\d+" y="\d+" width="(\d+)"', nib, re.S)
if not tab:
    failures.append('the Installed Plugins tab is gone from the nib')

values = {'en': KEY}
for language in LANGUAGES:
    catalog = root / 'Horos/Resources' / (language + '.lproj') / 'Localizable.strings'
    read = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(catalog)], capture_output=True)
    value = json.loads(read.stdout).get(KEY) if read.returncode == 0 else None
    if not value:
        failures.append('%s: the notice is not in the catalog' % language)
    elif value == KEY:
        failures.append('%s: the notice is left in English' % language)
    else:
        values[language] = value

MEASURE = '''
import AppKit
let width = CGFloat(Double(CommandLine.arguments[1])!)
let values = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: String]
for (language, value) in values.sorted(by: { $0.key < $1.key }) {
    let label = NSTextField(wrappingLabelWithString: value)
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    let size = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000))
    print("\\(language)\\t\\(Int(size.height.rounded(.up)))")
}
'''
if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-notice-') as folder:
        folder = Path(folder)
        (folder / 'main.swift').write_text(MEASURE)
        (folder / 'values.json').write_text(json.dumps(values))
        built = subprocess.run(['xcrun', 'swiftc', str(folder / 'main.swift'), '-o', str(folder / 'measure')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the measuring helper did not compile:\n' + built.stderr[-1500:])
        else:
            ran = subprocess.run([str(folder / 'measure'), str(int(tab.group(1)) - 2 * inset), str(folder / 'values.json')],
                                 capture_output=True, text=True, timeout=120)
            heights = dict(line.split('\t') for line in ran.stdout.splitlines() if '\t' in line)
            for language in values:
                needed = int(heights.get(language, 10 ** 6))
                if needed > height:
                    failures.append('%s: the notice needs %d points of height and has %d' % (language, needed, height))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the protected mode notice is whole in the twelve languages, and says the plugins load on the next launch')
