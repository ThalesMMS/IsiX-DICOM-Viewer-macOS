#!/usr/bin/env python3
"""French catalog coverage, formats and current interface connection preservation."""
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'Horos/Resources/fr.lproj'

def load(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

english = load(ROOT / 'Horos/Resources/en.lproj/Localizable.strings')
french = load(TARGET / 'Localizable.strings')
collector = module('collector', 'tools/collect-localized-strings.py')
residual = module('residual', 'tools/host-localization-residual.py')
assert english.keys() <= french.keys(), 'Missing English catalog keys'
assert collector.keys().keys() <= french.keys(), 'Missing live source localization keys'
# These labels contain literal percentages, never printf arguments. The legacy
# format regex otherwise mistakes '% of' and '% to' for conversions.
literal_percent_labels = {
    'At 100% of resolution', 'At 150% of resolution', 'At 200% of resolution',
    'Fusion : from 0% to 100% (in 20 images)',
}
for key, value in french.items():
    original = english.get(key, key)
    if key not in literal_percent_labels:
        assert Counter(residual.FORMAT.findall(original)) == Counter(residual.FORMAT.findall(value)), key
    else:
        assert re.findall(r'\d+', original) == re.findall(r'\d+', value), key
    assert Counter(re.findall(r'%\{[^}]+\}@', original)) == Counter(re.findall(r'%\{[^}]+\}@', value)), key
    assert Counter(re.findall(r'</?[A-Za-z][^>]*>', original)) == Counter(re.findall(r'</?[A-Za-z][^>]*>', value)), key
    assert all(original.count(c) == value.count(c) for c in '\n\r\t'), f'Changed layout escape: {key!r}'
    assert value or not original, f'Empty translation: {key!r}'
    assert not re.search(r'QXZ', value), f'Temporary translation token: {key!r}'
# The two ends of a range are labelled in one language: a word of two letters passes for a token in the list of
# the texts that stay English, and a label read "to" beside a translated "from".
range_ends = [key for key in ('From:', 'To:', 'From', 'To', 'from:', 'to:', 'to') if key in french]
assert len({french[key] == key for key in range_ends}) <= 1, \
    f'A range has its ends in two languages: {[french[key] for key in range_ends]}'
# French cognates and unchanged technical/design-time values outside the legacy
# shared residual list. An English sentence added later must be translated.
unchanged_french_or_technical = set([' version ',
 'JPEG Baseline',  # a DICOM transfer syntax's own name
 'Action',
 'Annotation',  # the name of an annotation just added in the Annotation Layout pane
 'Reconstruction',
 'Surface',
 'Position',
 'Rotation',
 '%d image',
 '%d images',
 '%d pages',
 '%d pixels',
 '%d/%d Images',
 '%{value1}@ im/s',
 '10 IN x 12 IN',
 '10 IN x 14 IN',
 '10 im/s',
 '10 im/s\n',
 '11 IN x 14 IN',
 '11 IN x 17 IN',
 '14 IN x 14 IN',
 '14 IN x 17 IN',
 '3D SR',
 '3D VR',
 '40 images',
 '40 pages',
 '60 im/s',
 '8 IN x 10 IN',
 '8.5 IN x 11 IN',
 '<< do not localize >>',
 '<<A disc named %@ and containing %d DICOM files was mounted. THIS STRING IS JUST A '
 'PLACEHOLDER, no need to localize it.>>',
 '<<do not localize window title>>',
 'AETitle',
 'AETitleValue',
 'Administration',
 'Albums',
 'Angle',
 'Angle ',
 'Annotations',
 'BILINEAR',
 'Compression',
 'Convolution',
 'DICOM 1',
 'Date',
 'Delaunay',
 'Destination',
 'Destination:',
 'Dilatation',
 'Direction:',
 'Distance: ',
 'Distances: ',
 'Format',
 'Format:',
 'Fusion',
 'HTTPS',
 'IMPORTANT',
 'Identification',
 'Image',
 'Image %d',
 'Image %d\r%.2f',  # an image of the preview's matrix with its location
 'Images',
 'Interpolation',
 'LibreOffice (.odt)',
 'MED',
 'Magazine',
 'Mail',
 'Mail.app',
 'Menu',
 'Microsoft Word (.doc)',
 'Mode',
 'Multiplication',
 'Division',
 'Navigation',
 'Note: %@',
 'Notification',
 'Options',
 'Options:',
 'Orientation',
 'Orientations',
 'OsiriX CT - 129',
 'Page',
 'Page %d',
 'Pages (.pages)',
 'Papyrus',
 'Patient',
 'Patient UID',
 'Plug-in:',
 'Port',
 'Portrait',
 'Pos:',
 'Projection:',
 'RGB ->BW',
 'RLE',
 'ROI 1',
 'Rectangle',
 'Rectangle ',
 'Rotation:',
 'SCAN',
 'SQL',
 'Sagittal',
 'Score',
 'Segments',
 'Source',
 'Sources',
 'TLS',
 'Type',
 'Type:',
 'UTF8 (Unicode): ISO_IR 192',
 'Version',
 'Volume',
 'Volume (cm3)',
 'Volume: XXX cm3\nA\nB\nC\nD',
 'WL/WW',
 'WL/WW:',
 'asdasd',
 'https://www.dicom.dcm/OsiriXDB.plist',
 'https://www.dicom.dcm/dicomNodes.plist',
 'https://www.preferences-server.com/preferences.plist',
 'image',
 'images',
 'minute',
 'minutes',
 'mm:\t\tx:0 y:0 z:0', 'px:\t\tx:0 y:0 z:0',
 # Words French writes as English does, where the translation had another sense.
 'Description', 'Global', 'Index', 'Log', 'Perspective', 'Point', 'Point ', 'Spline', 'Standard',
 # The film layouts of a DICOM print, STANDARD\columns,rows.
 'Standard 1,1', 'Standard 1,2', 'Standard 2,1', 'Standard 2,2', 'Standard 2,3', 'Standard 2,4',
 'Standard 3,3', 'Standard 3,4', 'Standard 3,5', 'Standard 4,4', 'Standard 4,5', 'Standard 4,6',
 'Standard 5,6', 'Standard 5,7',
 # The names of an algorithm, of a phonetic key, of a disc label and of an application.
 'Power Crust', 'Soundex', 'DICOMCD', 'TextEdit (.rtf)',
 # Abbreviations the rest of the catalog keeps.
 'BW -> RGB', 'WL: WW:',
 # The predefined values of a surface carry the names of window level presets, which are stored.
 'CT - Bone', 'CT - Metal', 'CT - Skin',
 'mmm',
 'pixels',
 'texture',
 'volume',
 'wado',
 'github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS'])
for key, value in french.items():
    original = english.get(key, key)
    if value == original:
        assert residual.is_residual(key, original) or key in unchanged_french_or_technical, key

visible = {'title', 'label', 'toolTip', 'placeholderString', 'alternateTitle',
           'stringValue', 'content', 'paletteLabel', 'headerToolTip'}
text_keys = {'title', 'label', 'toolTip', 'NSDisplayName', 'NSDisplayPattern',
             'NSNoSelectionPlaceholder', 'content'}
sources = sorted((ROOT / 'Horos/Resources/en.lproj').glob('*.xib'))
sources += sorted((ROOT / 'Preference Panes').glob('*/Base.lproj/*.xib'))
assert len({p.name for p in sources}) == len(sources), 'Duplicate resource names'

def text_visible(node, parent_tag):
    return node.tag == 'string' and (node.get('key') in text_keys or parent_tag == 'objectValues')

def compare(source, target, parent_tag=''):
    assert source.tag == target.tag, source.get('id')
    assert source.attrib.keys() == target.attrib.keys(), source.get('id')
    for attr, value in source.attrib.items():
        expected = french[value] if attr in visible and value else value
        assert target.get(attr) == expected, (source.get('id'), attr, value)
    expected_text = french.get(source.text, source.text) if text_visible(source, parent_tag) else source.text
    assert (target.text or '').strip() == (expected_text or '').strip(), source.get('id')
    assert len(source) == len(target), source.get('id')
    for original, translated in zip(source, target):
        compare(original, translated, source.tag)

for path in sources:
    assert (TARGET / path.name).exists(), f'Missing interface: {path.name}'
    compare(ET.parse(path).getroot(), ET.parse(TARGET / path.name).getroot())
menu = ET.parse(TARGET / 'MainMenu.xib')
assert menu.find('.//menuItem[@identifier="org.horos.menu.viewer"]').get('title') == 'Visualiseur 2D'
# Tiling is how the views are laid out, « disposition » as in the Viewers pane: not a tilt, and not left in English.
assert french['Tiling:'] == 'Disposition :' and french['Windows Tiling'] == 'Disposition des fenêtres'
assert not any(re.search('Tiling', value) for value in french.values()), 'Tiling left in English'
assert french['Cancel'] == 'Annuler'
assert french['Database'] == 'Base de données'
assert french['Study'] == 'Examen'
assert french['Series'] == 'Série'
if len(sys.argv) > 1:
    resources = Path(sys.argv[1]) / 'Contents/Resources'
    assert load(resources / 'fr.lproj/Localizable.strings') == french
    for path in sources:
        if path.parent.parent == ROOT / 'Horos/Resources':
            assert (resources / 'fr.lproj' / (path.stem + '.nib')).exists(), path.name
print(f'PASS: {len(french)} French keys and formats; '
      f'{len(sources)} current English interfaces with unchanged connections, identifiers and shortcuts')
