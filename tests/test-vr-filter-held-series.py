#!/usr/bin/env python3
"""After a change of plane, "Apply a filter" in a VR window filters the window's volume, not the 2D series.

A 2D viewer that changes plane while a VR window is open gives itself the
resliced slices and lets the window keep the former ones. The window's
"Apply a filter" (and a 3D preset with filters) still asked the 2D viewer to
apply the filter on its source: the resliced 2D series was filtered, the
window's volume was not, and Revert Series left the 2D series filtered, since
the copy before the first filter was the window's.

Both now go through -horosApplyFilter(named:). While the 2D viewer shows the
window's slices, its series is the window's volume and the 2D viewer filters
it, as before. Otherwise the window reads the stored filter and filters every
time of its own volume through IsiXImaging's SeriesConvolution.filterVolume,
the 2D viewer's "apply on source" on a whole volume (its bytes are checked
against the viewer's in the package's tests), then the windows on the volume
draw it again; the 2D viewer's series is left alone. Revert Series then takes
the filter back (the slices read from their files, or the copy). Closing the
window does not offer to give the 2D series back a volume it no longer shows:
the volume the window kept, which the 3D windows opened before the change of
plane still show, gets its copy before the first filter back without a
question when no cut followed the filter, and keeps both otherwise.

When there is not enough memory for that copy, the alert that asks whether to
filter anyway said the filter would stay in the 2D series, which after a
change of plane it does not reach. It now names where the filter goes: the 2D
series while the 2D viewer shows the window's slices, otherwise the window's
volume and the other 3D windows that show it (a text in the twelve catalogs,
translated; the former one stays for the first case).

Read from the sources. `<git revision>` as an optional argument reads the files
from that revision: the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
LANGUAGES = ['ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans']
STAYS_IN_SERIES = ('There is not enough memory to keep a copy of the volume. The filter will stay in the 2D series '
                   'after this window closes.')
STAYS_IN_VOLUME = ('There is not enough memory to keep a copy of the volume. The filter will stay in this window\'s '
                   'volume and, after this window closes, in the other 3D windows that show it. The 2D series does '
                   'not change.')


def read_bytes(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout if result.returncode == 0 else b''
    file = root / path
    return file.read_bytes() if file.exists() else b''


def read(path):
    return read_bytes(path).decode('utf-8')


def catalog(language):
    data = read_bytes(f'Horos/Resources/{language}.lproj/Localizable.strings')
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', text, re.M))


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


failures = []

# The premise: the 2D viewer's "apply on source" filters the slices it shows.
tables = read('Horos/Sources/ViewerColourTables.swift')
pixels = method(tables, '    func applyFilterToPixels(in viewer: ViewerController) {')
if '(0..<viewer.horos_movieCount).map { viewer.horos_pixArray($0) }' not in pixels or \
        'viewer.horos_volumeData(at: x)' not in pixels:
    failures.append('premise: the 2D viewer filters the slices and the volume it shows')

controller = read_controller()
apply = method(controller, '    public final func applyConvolution(_ sender: Any!) {')
if 'horosApplyFilter(named: title)' not in apply or 'applyConvolutionOnSource' in apply:
    failures.append('applyConvolution: through -horosApplyFilter(named:)')
preset = re.search(r'let filters = preset\.object\(forKey: "convolutionFilters"\) as\? NSArray.*?\n        \}\n', controller, re.S)
if not preset or 'horosApplyFilter(named: filter)' not in preset.group(0) or 'applyConvolutionOnSource' in preset.group(0):
    failures.append('a preset with filters: through -horosApplyFilter(named:)')
if controller.count('applyConvolutionOnSource(self)') != 1:
    failures.append('only -horosApplyFilter(named:) asks the 2D viewer to filter its source')

chosen = method(controller, '    final func horosApplyFilter(named name: String) {')
branches = re.search(r'if horosViewerShowsSeries\(\) \{(?P<viewer>.*?)\} else if !horosFilterVolume\(named: name\) \{\s*return\s*\}'
                     r'(?P<after>.*)', chosen, re.S)
if not branches:
    failures.append('-horosApplyFilter: the 2D viewer while it shows the window\'s slices, the window\'s volume otherwise')
else:
    if 'viewer2DStorage?.applyConvString(name)' not in branches['viewer'] or \
            'viewer2DStorage?.applyConvolutionOnSource(self)' not in branches['viewer']:
        failures.append('-horosApplyFilter: the 2D viewer applies the filter on its source, the window\'s volume')
    if 'appliedConvolutionFilters?.add(name)' not in branches['after'] or \
            'if horosFilterRestore == nil { horosChangedWithoutFilterCopy = true }' not in branches['after']:
        failures.append('-horosApplyFilter: the filter applied is the window\'s, and one without a copy stays after Revert')

own = method(controller, '    private final func horosFilterVolume(named name: String) -> Bool {')
for part in ['PresetTable(ImagePresetPreferences.convolutionPresets, in: processGraph.preferences).entries?[name]',
             'ConvolutionKernelBook.Kernel(stored: stored?.object)',
             'This convolution filter cannot be loaded.',
             'for i in 0..<Int(maxMovieIndex) {',
             'convolution.filterVolume(UnsafeMutableRawPointer(mutating: volume.bytes), byteCount: volume.length,',
             'depth: slices.count', 'colour: first.isRGB', 'horosAnnounceVolumes()']:
    if part not in own:
        failures.append(f'-horosFilterVolume: {part}')
if 'viewer2DStorage' in own:
    failures.append('-horosFilterVolume: the 2D viewer\'s series is left alone')

module = read('Modules/IsiXImaging/Sources/BufferOperations/SeriesConvolution.swift')
volume = re.search(r'public func filterVolume\(.*?\n    \}\n', module, re.S)
if not volume or 'finishGreyVolume(base.address' not in volume.group(0) or 'filtered(argb:' not in volume.group(0):
    failures.append('SeriesConvolution.filterVolume: each slice, then across the slices of a grey volume')

# The rule of the close: the copy given back without a question when no cut
# followed the first filter, a question otherwise, nothing for a 2D viewer that
# closes or without a copy.
rule = method(read('Horos/Sources/VRFilterRestore.swift'),
              '    public static func closeAction(hasCopy: Bool, cutAfterFilter: Bool, viewerClosing: Bool) -> VRFilterCloseAction {')
if not re.search(r'if !hasCopy \|\| viewerClosing \{\s*return \.none\s*\}\s*return cutAfterFilter \? \.ask : \.restore', rule):
    failures.append('premise: closing gives the copy back, asks when a cut followed the filter, does nothing for a closing 2D viewer')
settle = method(controller, '    final func horosSettleFiltersOnClose() {')
if 'viewerClosing: horosViewerClosing)' not in settle or \
        not re.search(r'if action == \.restore \{\s*horosRestoreVolumeBeforeFilter\(\)\s*\} else if action == \.ask && horosViewerShowsSeries\(\) \{', settle):
    failures.append('closing the window: the volume it kept gets its copy back without a question when no cut followed '
                    'the filter; no question about a 2D series that shows other slices')

# Without memory for the copy, the alert names where -horosApplyFilter puts the
# filter, with the same test.
keep = method(controller, '    final func horosKeepVolumeBeforeFilter() -> Bool {')
if not re.search(r'let message = horosViewerShowsSeries\(\)\s*'
                 r'\?\s*NSLocalizedString\("' + re.escape(STAYS_IN_SERIES) + r'", comment: ""\)\s*'
                 r':\s*NSLocalizedString\("' + re.escape(STAYS_IN_VOLUME) + r'", comment: ""\)', keep) or \
        not re.search(r'HorosAlertPanel\.run\(title: NSLocalizedString\("Not enough memory", comment: ""\),\s*message: message,', keep):
    failures.append('not enough memory for the copy: the alert says the filter stays in the 2D series while the 2D viewer '
                    'shows the window\'s slices, in the window\'s volume otherwise')
for language in LANGUAGES:
    strings = catalog(language)
    if STAYS_IN_SERIES not in strings:
        failures.append(f'{language}: the text of a filter that stays in the 2D series is still used')
    value = strings.get(STAYS_IN_VOLUME)
    if not value:
        failures.append(f'{language}: no text for a filter that stays in the window\'s volume')
    elif language != 'en' and value == STAYS_IN_VOLUME:
        failures.append(f'{language}: the text for a filter that stays in the window\'s volume is not translated')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: after a change of plane the VR window\'s filters (menu and presets) go into its own volume, as the 2D '
      'viewer would apply them, and the 2D series is left alone; while the 2D viewer shows the volume it filters it; '
      'without memory for a copy the alert names where the filter stays')
