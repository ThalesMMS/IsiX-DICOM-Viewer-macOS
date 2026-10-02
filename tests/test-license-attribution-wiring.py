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
xcconfig = (root / 'Horos/Horos.xcconfig').read_text(encoding='utf-8')


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
if 'Yves Starreveld' not in xcconfig:
    fail('HUMAN_READABLE_COPYRIGHT no longer credits the donor author')
if 'L368' not in notice or 'test-license-attribution.py' not in notice:
    fail('distributed NOTICE does not identify catalog L368 and its public tests')
# Internal localization/audit contracts are deliberately outside this public test.
for text, label in ((notice, 'NOTICE'), (readme, 'README'), (licenses, 'licenses.html')):
    if re.search(r'(?<![/\w])docs/', text) or 'MANIFEST.json' in text or 'license snapshot' in text:
        fail(label + ' promises an unpublished internal audit artifact')
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

print('PASS: About path, pbx resources, README/NOTICE, the fork author in every notice')

# Every local license link must resolve to a nonempty readable bundled text.
index = root / 'Binaries/Splash/ThirdParty/licenses.html'
index_text = index.read_text(encoding='utf-8')
for link in re.findall(r'href="([^"]+)"', index_text):
    if ':' in link or link.startswith('#'):
        continue
    path = index.parent / link
    if not path.is_file() or not path.read_bytes().strip():
        fail('third-party license link has no readable full text: ' + link)
for component in ('FeedbackReporter', 'cocoahttpserver', 'dicom3tools', 'Weasis', 'KFSplitView', 'FlyAssistant', 'Provenance.json'):
    if component not in index_text:
        fail('third-party license index omits ' + component)
if 'ThirdParty/licenses.html' not in licenses:
    fail('About license catalog does not link the full third-party texts')
if 'https://github.com/nroduit/Weasis/tree/v3.6.0' not in index_text:
    fail('portable Weasis lacks its corresponding source location')
# Check byte preservation of native primary texts, including the runtime CharLS copy.
for source in ('DCMTK/COPYRIGHT',
               'FeedbackReporter/LICENSE.txt',
               'cocoahttpserver/LICENSE.txt', 'DCMTK/dcmjpls/docs/License.txt'):
    if (index.parent / 'Native' / source).read_bytes() != (root / source).read_bytes():
        fail('native license text was changed: ' + source)
# The source archive is no longer versioned; its untouched license remains in
# Splash, independently checkable without downloading optional build inputs.
import hashlib
import json
source_pin = json.loads((root / 'Horos/Scripts/external-sources.json').read_text())['OpenJPEG']
if hashlib.sha256((index.parent / 'Native/OpenJPEG/LICENSE').read_bytes()).hexdigest() != source_pin['licenseSha256']:
    fail('OpenJPEG license does not match the source declaration')
vtk_pin = json.loads((root / 'Horos/Scripts/external-sources.json').read_text())['VTK']
if hashlib.sha256((index.parent / 'Native/VTK/Copyright.txt').read_bytes()).hexdigest() != vtk_pin['licenseSha256']:
    fail('VTK license does not match the original release declaration')
itk_pin = json.loads((root / 'Horos/Scripts/external-sources.json').read_text())['ITK']
for bundled, field in (('Native/ITK/LICENSE', 'licenseSha256'), ('Native/ITK/NOTICE', 'noticeSha256')):
    if hashlib.sha256((index.parent / bundled).read_bytes()).hexdigest() != itk_pin[field]:
        fail('ITK %s does not match the original release declaration' % bundled.rsplit('/', 1)[1])
# The complete terms for retained dictionary data travel independently of the
# retired parser tree and of the optional GDCM copy inside the ITK distribution.
import hashlib
selected_terms = index.parent / 'Compatibility/SelectedAnonymizationCatalog-Copyright.txt'
if hashlib.sha256(selected_terms.read_bytes()).hexdigest() != '31a64b1bc4f367401fdd689daee273af8195c24eb5d8dcd5b694f201b06721ed':
    fail('the original GDCM copyright/terms for selected anonymization data changed')
if 'Compatibility/SelectedAnonymizationCatalog-Copyright.txt' not in index_text:
    fail('the derived dictionary data has no linked license text')
print('PASS: full linked/portable third-party texts, source links and byte preservation')

# Extensionless originals remain byte-identical, while WebKit reads HTML pages.
from html.parser import HTMLParser
class LicenseReader(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_pre = False
        self.text = ''
    def handle_starttag(self, tag, attrs):
        if tag == 'pre': self.in_pre = True
    def handle_endtag(self, tag):
        if tag == 'pre': self.in_pre = False
    def handle_data(self, data):
        if self.in_pre: self.text += data
original_links = re.findall(r'<link rel="license" href="([^"]+)">', index_text)
if len(original_links) < 100: fail('HTML reader verification has no complete original text set')
for original in original_links:
    page = index.parent / ('Rendered/' + original + '.html')
    if not page.is_file(): fail('no HTML reader for ' + original)
    reader = LicenseReader()
    reader.feed(page.read_bytes().decode('utf-8'))
    encoding = re.search(r'<meta name="license-text-encoding" content="([^"]+)">', page.read_text()).group(1)
    if reader.text.encode(encoding) != (index.parent / original).read_bytes():
        fail('HTML reader changes the original license text: ' + original)
print('PASS: WebKit HTML readers preserve every original license text')

# Exercise the existing release auditor on disposable copies of distributed notices.
import plistlib
import shutil
import subprocess
import tempfile
with tempfile.TemporaryDirectory(prefix='horos-notice-audit-') as scratch:
    bundle = Path(scratch) / 'Isis DICOM Viewer.app'
    resources = bundle / 'Contents/Resources'
    resources.mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.notices'}))
    for name in ('LICENSE', 'COPYING.LESSER', 'NOTICE'):
        shutil.copyfile(root / name, resources / name)
    shutil.copytree(root / 'Binaries/Splash', resources / 'Splash')
    command = [sys.executable, str(root / 'tools/audit-release-bundle.py'), str(bundle), '--notices']
    def audit(expected):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != expected:
            fail('release notice auditor unexpected result: ' + result.stdout + result.stderr)
    audit(0)
    for relative in ('NOTICE', 'Splash/ThirdParty/Native/ITK/NOTICE',
                     'Splash/ThirdParty/Rendered/Native/ITK/NOTICE.html',
                     'Splash/ThirdParty/Native/Legacy/NOTICES.txt',
                     'Splash/ThirdParty/Provenance.json'):
        file = resources / relative
        saved = file.read_bytes()
        file.unlink()
        audit(1)
        file.write_bytes(b'')
        audit(1)
        file.write_bytes(saved)
    wrapper = resources / 'Splash/ThirdParty/Rendered/Native/ITK/NOTICE.html'
    saved = wrapper.read_bytes()
    wrapper.write_bytes(saved.replace(b'<pre>', b'<pre>modified notice'))
    audit(1)
    wrapper.write_bytes(saved)
    audit(0)
print('PASS: release notice auditor rejects missing/empty texts and changed HTML readers')
