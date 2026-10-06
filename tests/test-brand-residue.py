#!/usr/bin/env python3
"""What the application shows calls it IsiX DICOM Viewer, not Isis, Horos or OsiriX.

Horos, HorosCloud and OsiriX are other people's names, and Isis is a name the
application no longer shows: the icon file and the bundle identifiers keep it.
The code keeps its credits and its compatibility identifiers, but the interface
must not present the application, its logo or its services under those names.
This reads what is shown - the bundle's Info.plist, the catalogs and nibs of
every language, the About pages, the scripting dictionary and the web portal
templates - and accepts a third-party name only where it is listed below, with
the reason.

Class names, selectors, file names, URL schemes, plugin extensions, stored series
names and log messages are not interface text and are not read here.
"""
from pathlib import Path
import html
import json
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
failures = []
NAME = 'IsiX DICOM Viewer'
# A particle or a CJK character glued to the name is not part of it, and neither is
# the letter of an escape such as \r written in a catalog or a key.
BRAND = re.compile(r'(?:(?<![A-Za-z0-9_])|(?<=\\[rnt]))(?:Horos ?Cloud|Horos|OsiriX|Osirix|Isis)(?![A-Za-z0-9_])')

# English texts that keep a third-party name, by prefix.
ALLOWED = {
    # Plugins are installed in this folder, by the user and by plugin installers.
    '(~/Library/Application Support/Horos App/)': 'path on disk',
    'Use templates at ~/Library/Application Support/Horos/': 'path on disk',
    # Plugins are made for Horos or for OsiriX, and the lists say which.
    'Horos Plugins': 'plugin origin', 'OsiriX Plugins': 'plugin origin',
    'Plugin validated in Horos': 'plugin origin', 'Plugin not validated in Horos': 'plugin origin',
    'No Horos plugin server available.': 'plugin origin', 'No OsiriX plugin server available.': 'plugin origin',
    'Your Horos Plugin here!': 'plugin origin', 'Not validated OsiriX plugin': 'plugin origin',
    # Importing from another application that is installed.
    'Your OsiriX files will not be modified': 'the other application',
    # A Horos database found on the Mac is left alone, and choosing one says what opening it does.
    'A Horos database was found at %@.': 'the other application',
    'This folder holds a Horos database': 'the other application',
    '%@ is a database made by Horos.': 'the other application',
    # An installation still opening the Horos database is recommended a database of its own.
    'IsiX DICOM Viewer is using the Horos database': 'the other application',
    '%@ is the database of Horos': 'the other application',
    'Move to IsiX Data opens a database of IsiX DICOM Viewer beside it': 'the other application',
    'Keep Using Horos Data': 'folder name',
    NAME + ' detected you have OsiriX pre-installed': 'the other application',
    "It seems you don't have OsiriX installed.": 'the other application',
    'Only CLUT created in OsiriX 1.3.1': 'file format history',
    'Only CLUT created in Horos 1.3.1': 'file format history',
    # Names stored in data or in other applications' files.
    'OsiriX Screen Captures': 'stored series name', 'Horos Screen Captures': 'stored series name',
    'OsiriXDB.plist': 'file name', 'http://www.dicom.dcm/OsiriXDB.plist': 'file name', 'OsiriX CT - 129': 'stored preset name',
}
PREFIXES = tuple(ALLOWED)


def allowed(english):
    return english.startswith(PREFIXES) or english.lstrip().startswith(PREFIXES)


def report(condition, message):
    if not condition:
        failures.append(message)


# The reader has to find what it is looking for before its silence means anything.
report(BRAND.search('Restart Horos to apply') and BRAND.search('OsiriXを再起動') and BRAND.search('Horos Cloud™')
       and BRAND.search('Restart Isis DICOM Viewer') and BRAND.search('Isis DICOM Viewerを再起動')
       and BRAND.search('\\r\\rIsis DICOM Viewer') and BRAND.search('如果Isis DICOM Viewer')
       and not BRAND.search(NAME) and not BRAND.search('Weasis') and not BRAND.search('Saisissez')
       and not BRAND.search('thalesmms.isis.workstation')
       and not BRAND.search('HorosCellSlider') and not BRAND.search('horos://') and not allowed('Restart Horos'),
       'the reader no longer recognises a product name in a text')

# --- the bundle's identity -------------------------------------------------------
info = plistlib.loads((root / 'Horos/Info.plist').read_bytes())
report(info.get('CFBundleName') == '$(PRODUCT_NAME)' and info.get('CFBundleExecutable') == '$(EXECUTABLE_NAME)',
       'Info.plist names the bundle or its executable itself instead of taking the product name')
report(info.get('CFBundleIconFile') == 'Isis.icns', 'the bundle icon is %r' % info.get('CFBundleIconFile'))
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
report('PRODUCT_NAME = "%s";' % NAME in project, 'the application target is not named %s' % NAME)
report('PRODUCT_MODULE_NAME = Horos;' in project, 'the Swift module no longer keeps its name, which every generated-header import relies on')
config = (root / 'Horos/Horos.xcconfig').read_text()
for line in config.splitlines():
    if line.startswith(('PRODUCT_BUNDLE_IDENTIFIER_PREFIX', 'HUMAN_READABLE_VERSION')):
        report('horos' not in line.split('=', 1)[1].lower(), 'Horos.xcconfig: %s' % line.strip())

# File kinds and URL names that describe what the application opens, not itself.
PLIST_ALLOWED = {'OsiriX Region Of Interest', 'OsiriX Regions Of Interest', 'OsiriX LSM', 'OsiriX BioRAD PIC',
                 'Horos Plugin', 'OsiriX Plugin', 'OsiriX Remote Access', 'Horos.sdef',
                 # The icon file keeps its name.
                 'Isis.icns'}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


for name in ('Horos/Info.plist', 'FinderPreview/Preview-Info.plist', 'FinderPreview/Thumbnail-Info.plist'):
    for text in strings(plistlib.loads((root / name).read_bytes())):
        if BRAND.search(text) and text not in PLIST_ALLOWED:
            failures.append('%s: %r' % (name, text[:90]))

# --- catalogs ---------------------------------------------------------------------
catalogs = sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings'))
report(len(catalogs) >= 12, 'only %d catalogs were found' % len(catalogs))
for path in catalogs:
    catalog = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    language = path.parent.name
    for key, value in catalog.items():
        if (BRAND.search(value) or BRAND.search(key)) and not allowed(key):
            failures.append('%s catalog: %r = %r' % (language, key[:70], value[:70]))

# --- nibs: a text may keep a name only where its English counterpart may -----------
TEXT = re.compile(r'(\b(?:title|label|toolTip|placeholderString|alternateTitle|stringValue|paletteLabel|headerToolTip)=")([^"]*)(")'
                  r'|(<string key="[^"]*">)(.*?)(</string>)', re.S)


def texts(source):
    return [html.unescape(match.group(2) if match.group(1) else match.group(5)) for match in TEXT.finditer(source)]


english = {path.name: texts(path.read_text()) for path in
           list((root / 'Horos/Resources/en.lproj').glob('*.xib')) + list((root / 'Preference Panes').glob('*/Base.lproj/*.xib'))}
report(len(english) >= 60, 'only %d English nibs were found' % len(english))
for name, items in english.items():
    for text in items:
        if BRAND.search(text) and not allowed(text):
            failures.append('en %s: %r' % (name, text[:90]))
localized = [path for path in list((root / 'Horos/Resources').glob('*.lproj/*.xib')) + list((root / 'Preference Panes').glob('*/*.lproj/*.xib'))
             if path.parent.name not in ('en.lproj', 'Base.lproj')]
report(len(localized) >= 500, 'only %d localized nibs were found' % len(localized))
for path in localized:
    items = texts(path.read_text())
    base = english.get(path.name)
    if base is None:
        failures.append('%s has no English counterpart' % path.relative_to(root))
        continue
    if len(items) != len(base):
        # Not the same structure: every text has to stand on its own.
        base = items
    for text, original in zip(items, base):
        if BRAND.search(text) and not allowed(original):
            failures.append('%s %s: %r' % (path.parent.name, path.name, text[:90]))

# --- About pages --------------------------------------------------------------------
splash = root / 'Binaries/Splash'
for gone in ('partners.html', 'images/horos-logo.png', 'images/purview-logo.png'):
    report(not (splash / gone).exists(), 'Splash/%s is still distributed' % gone)
for name in ('about.html', 'releasenotes.html', 'licenses.html'):
    page = (splash / name).read_text(encoding='utf-8')
    for heading in re.findall(r'<(?:title|h1|h2)>(.*?)</(?:title|h1|h2)>', page, re.S):
        report(not BRAND.search(heading), 'Splash/%s heading: %r' % (name, heading[:80]))
    for image in re.findall(r'<img[^>]*src="([^"]*)"', page):
        report((splash / image).exists() and not BRAND.search(image) and 'horos' not in image.lower(),
               'Splash/%s shows %s' % (name, image))
about = (splash / 'about.html').read_text(encoding='utf-8')
report('About %s' % NAME in about, 'the About page is not about %s' % NAME)
report('not made, sponsored or endorsed by the Horos Project, Purview or Pixmeo' in about,
       'the About page does not say that the owners of the other names do not endorse this application')
report('horoscloud.io' not in about, 'the About page lists Horos Cloud as part of the application')

# --- artwork that reproduced the other logos -------------------------------------------
icons = root / 'Horos/Resources/Icons'
for gone in ('Horos.icns', 'Osirix.icns', 'OsirixDownload.icns', 'OsiriX.pdf'):
    report(not (icons / gone).exists(), 'Icons/%s is still in the tree' % gone)
    report(('/* %s ' % gone) not in project, '%s is still a resource of the project' % gone)
report((icons / 'Isis.icns').is_file() and '/* Isis.icns in Resources */' in project, 'Isis.icns is not a resource of the application')

# --- scripting dictionary and web portal ---------------------------------------------
sdef = (root / 'Horos/Resources/Horos.sdef').read_text()
for attribute in re.findall(r'<(?:dictionary|suite)\b[^>]*>', sdef):
    for value in re.findall(r'\b(?:title|name|description)="([^"]*)"', attribute):
        report(not BRAND.search(value), 'scripting dictionary: %r' % value)
for path in sorted((root / 'Horos/Resources/WebServicesHTML/English').glob('*.html')):
    visible = re.sub(r'<[^>]*>', ' ', path.read_text(encoding='utf-8', errors='replace'))
    for match in BRAND.finditer(visible):
        failures.append('web portal %s: %r' % (path.name, visible[max(0, match.start() - 30):match.end() + 30].strip()))

# --- the notices say whose the names are -------------------------------------------------
notice = (root / 'NOTICE').read_text(encoding='utf-8')
flat = ' '.join(notice.split())
report('name and its icon are Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) and are not covered by the LGPLv3 grant' in flat,
       'NOTICE does not reserve the name and the icon')
report('not made, sponsored or endorsed by the Horos Project, Purview or Pixmeo' in flat, 'NOTICE does not state the origin and the absence of endorsement')
for credit in ('OsiriX Team', 'The Horos Project (www.horosproject.org)', 'Yves Starreveld',
               '(C) Copyright 2018 Nimble Co LLC d/b/a Purview. All Rights Reserved.', 'HorosCloud is a Trademark of Purview.'):
    report(credit in notice, 'NOTICE lost a credit: %s' % credit)

for failure in failures[:60]:
    print('FAIL: %s' % failure)
if failures:
    print('%d failure(s)' % len(failures))
    sys.exit(1)
print('ok: Info.plist, %d catalogs, %d English and %d localized nibs, the About pages, the scripting dictionary and the '
      'portal templates name %s; third-party names remain only in the %d listed texts'
      % (len(catalogs), len(english), len(localized), NAME, len(ALLOWED)))
