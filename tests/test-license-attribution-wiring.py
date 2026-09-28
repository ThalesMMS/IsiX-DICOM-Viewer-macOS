#!/usr/bin/env python3
"""License catalog is in the app target and the About path loads bundled notices."""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
# SplashScreen is Swift since #714; the assertions read its Swift spelling.
splash = sources.source_text('SplashScreen')
about = (root / 'Binaries/Splash/about.html').read_text(encoding='utf-8')
licenses = (root / 'Binaries/Splash/licenses.html').read_text(encoding='utf-8')
readme = (root / 'README.md').read_text(encoding='utf-8')
notice = (root / 'NOTICE').read_text(encoding='utf-8')
docs = (root / 'docs/license-attribution.md').read_text(encoding='utf-8')
xcconfig = (root / 'Horos/Horos.xcconfig').read_text(encoding='utf-8')
catalog = (root / 'docs/host-localization-catalog-contract.md').read_text(encoding='utf-8')


def fail(message):
    print('FAIL:', message, file=sys.stderr)
    sys.exit(1)


needed_pbx = [
    'LicenseAttribution.swift in Sources',
    'NOTICE in Resources',
    'LICENSE in Resources',
    'COPYING.LESSER in Resources',
    'Splash in Resources',
]
missing = [item for item in needed_pbx if item not in pbx]
if missing:
    fail('pbxproj is missing ' + ', '.join(missing))

# The Objective-C imported Horos-Swift.h to reach the Swift catalog; the Swift
# reaches it by being compiled in the same target.
if 'SplashScreen.swift in Sources' not in pbx:
    fail('SplashScreen.swift is not compiled in the app target, with LicenseAttribution.swift')
if not re.search(r'LicenseAttribution\.missingNotices\(in: Bundle\.main\)', splash):
    fail('SplashScreen.swift does not consult HorosLicenseAttribution for bundled notices')
if 'loadSplashPage("Splash/about.html", in: aboutWebView)' not in splash:
    fail('SplashScreen.swift no longer loads Splash/about.html')
if 'licenses.html' not in about:
    fail('about.html does not link to licenses.html')
if 'OpenSSL-LICENSE.txt' not in licenses:
    fail('licenses.html does not link to the bundled OpenSSL license')
if 'DICOM-Swift-LICENSE.txt' not in licenses:
    fail('licenses.html does not link to the bundled DICOM-Swift license')
if 'DICOM-Swift' not in notice or 'Apache-2.0' not in notice:
    fail('NOTICE does not cite DICOM-Swift and its license')
if (root / 'Binaries/Splash/OpenSSL-LICENSE.txt').read_bytes() != (root / 'OpenSSL/upstream/LICENSE.txt').read_bytes():
    fail('the bundled OpenSSL license differs from the pinned upstream text')

for name in ('Horos Project', 'OsiriX', 'Yves Starreveld',
             'Horos Cloud', 'DCMTK', 'ITK', 'VTK', 'OpenJPEG', 'CharLS', 'DICOM-Swift'):
    if name not in licenses:
        fail('licenses.html is missing ' + name)
for text, label in ((licenses, 'licenses.html'), (about, 'about.html')):
    if 'Grok' in text:
        fail(label + ' still credits Grok, which nothing links since #617')

if 'DICOMweb' not in notice:
    fail('NOTICE dropped the DICOMweb preservation note')
if 'Yves Starreveld' not in readme:
    fail('README.md no longer credits the donor author')
if 'L368' not in docs:
    fail('docs/license-attribution.md is missing catalog ID L368')
if 'test-license-attribution.py' not in docs:
    fail('docs/license-attribution.md does not point at the tests for #367/#385')
if 'Yves Starreveld' not in xcconfig:
    fail('HUMAN_READABLE_COPYRIGHT no longer credits the donor author')
if 'L368' not in catalog:
    fail('host localization catalog contract does not point at L368')

# The author of this fork's changes is named in every distributed notice and in
# the app's copyright line, and none of them names the private repository (#793).
license_text = (root / 'LICENSE').read_text(encoding='utf-8')
copyright = re.search(r'^HUMAN_READABLE_COPYRIGHT\s*=\s*(.+)$', xcconfig, re.M)
copyright = copyright.group(1) if copyright else ''
readme_license = readme[readme.find('## License and credits'):]
readme_license = readme_license[:readme_license.find('\n## ', 5)]
for text, label in ((license_text, 'LICENSE'), (notice, 'NOTICE'), (about, 'about.html'),
                    (licenses, 'licenses.html'), (copyright, 'HUMAN_READABLE_COPYRIGHT')):
    if 'Thales Matheus M Santos' not in text:
        fail(label + ' does not name the author of this fork')
for text, label in ((license_text, 'LICENSE'), (notice, 'NOTICE'), (about, 'about.html'),
                    (licenses, 'licenses.html'), (copyright, 'HUMAN_READABLE_COPYRIGHT'),
                    (readme_license, 'README.md license section')):
    if 'horos-workbench' in text or 'workbench' in text.lower():
        fail(label + ' still speaks of the workbench')
for text, label in ((license_text, 'LICENSE'), (notice, 'NOTICE')):
    if 'Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork' not in text or \
            'They were not made or endorsed by the Horos Project.' not in text:
        fail(label + ' lacks the fork copyright line or declaration')
if 'published by the Horos Project' in about + licenses:
    fail('the About pages still say the Horos Project publishes this fork')

# The origin removal of HorosCloud must not appear as an instruction to delete it.
if 'remove HorosCloud' in notice.lower() or 'delete HorosCloud' in notice.lower():
    fail('NOTICE tells the reader to remove HorosCloud')

print('PASS: About path, pbx resources, README/NOTICE/docs catalog L368, the fork author in every notice')
