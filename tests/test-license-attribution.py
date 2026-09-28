#!/usr/bin/env python3
"""License texts, credits and bundle notices stay complete and are not a blind origin replace."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
snap = root / 'docs/third-party/donor-horos-23722fb552d96fa2d60c7f58a6d4ac2c27950f86'
# The donor checkout is a read-only reference that no clone provides. Point
# HOROS_DONOR_CHECKOUT at it to run the byte-for-byte comparison; without it
# the snapshot is still checked against its pinned hashes.
_donor = os.environ.get('HOROS_DONOR_CHECKOUT')
origin = Path(_donor).expanduser() if _donor else None
revision = '23722fb552d96fa2d60c7f58a6d4ac2c27950f86'
origin_license_sha = 'd885acd3300b5464fe5e6774610b35fb2d83192f272be3325d69b89d2d666f38'
origin_copying_sha = 'c9f740e3eddbb3a01de0d3924a9afd17782567e20c28e55d0e2436376b5c9000'


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(message):
    print('FAIL:', message, file=sys.stderr)
    sys.exit(1)


manifest = json.loads((snap / 'MANIFEST.json').read_text())
if manifest['revision'] != revision:
    fail('MANIFEST revision is not the documented donor SHA')
if sha256(snap / 'LICENSE') != origin_license_sha:
    fail('snapshotted LICENSE hash drifted')
if sha256(snap / 'COPYING.LESSER') != origin_copying_sha:
    fail('snapshotted COPYING.LESSER hash drifted')
if sha256(root / 'COPYING.LESSER') != origin_copying_sha:
    fail('root COPYING.LESSER no longer matches the origin snapshot')

if origin is not None and origin.is_dir():
    # The origin is a read-only reference whose working tree may sit on any
    # revision: the Delta-3 phase reads three later commits from the same clone.
    # Compare the snapshot with the blobs of the pinned revision, which is what
    # it claims to be a copy of, instead of with whatever HEAD happens to be.
    try:
        subprocess.run(['git', '-C', str(origin), 'cat-file', '-e', revision + '^{commit}'],
                       check=True, capture_output=True)
    except subprocess.CalledProcessError:
        fail('the donor checkout does not contain the snapshotted revision %s' % revision)
    for name in ('LICENSE', 'COPYING.LESSER'):
        blob = subprocess.run(['git', '-C', str(origin), 'show', '%s:%s' % (revision, name)],
                              check=True, capture_output=True).stdout
        if blob != (snap / name).read_bytes():
            fail('snapshot %s is not a byte-for-byte copy of %s at %s' % (name, name, revision[:12]))
        # The later revisions this phase adopts must not have changed the terms
        # without the snapshot being renewed.
        for adopted in ('8a37f4b3a46832ce0c0343f35ec57ece78235a47',
                        '8be8b977f8574877118cf9e6b3470baf7bf7ba2f',
                        'e2acd36ed1f25ea94f0b6e5cfc7359fd95e262d9'):
            present = subprocess.run(['git', '-C', str(origin), 'cat-file', '-e', adopted + '^{commit}'],
                                     capture_output=True)
            if present.returncode != 0:
                continue
            later = subprocess.run(['git', '-C', str(origin), 'show', '%s:%s' % (adopted, name)],
                                   check=True, capture_output=True).stdout
            if later != blob:
                fail('%s changed between %s and %s; renew the snapshot before adopting it'
                     % (name, revision[:12], adopted[:12]))

workbench_license = (root / 'LICENSE').read_text(encoding='utf-8')
origin_license = (snap / 'LICENSE').read_text(encoding='utf-8')
if workbench_license == origin_license:
    fail('root LICENSE is a blind replacement of the origin file')
if 'Purview' not in workbench_license or 'HorosCloud' not in workbench_license:
    fail('root LICENSE dropped the Purview/HorosCloud notice')
if 'Yves Starreveld' not in workbench_license:
    fail('root LICENSE does not credit Yves Starreveld')
# Nothing links Grok since #617: LICENSE and NOTICE must not say it does.
if 'Grok' in workbench_license:
    fail('root LICENSE still says Horos is linked against Grok')
if 'Lesser General Public License' not in workbench_license:
    fail('root LICENSE dropped the Horos LGPLv3 terms')

notice = (root / 'NOTICE').read_text(encoding='utf-8')
readme = (root / 'README.md').read_text(encoding='utf-8')
about = (root / 'Binaries/Splash/about.html').read_text(encoding='utf-8')
licenses_html = (root / 'Binaries/Splash/licenses.html').read_text(encoding='utf-8')
for text, label in ((notice, 'NOTICE'), (readme, 'README.md'), (about, 'about.html'),
                    (licenses_html, 'licenses.html')):
    if 'Yves Starreveld' not in text:
        fail('%s does not credit Yves Starreveld' % label)
    if 'OsiriX' not in text:
        fail('%s dropped OsiriX credit' % label)

if 'HorosCloud' not in notice or 'Do not import that removal' not in notice and 'not imported' not in notice:
    if 'not imported' not in notice.lower() and 'not import' not in notice:
        fail('NOTICE does not keep the HorosCloud/Purview disposition')
if 'Grok' in notice:
    fail('NOTICE still lists Grok')
if 'Do not treat the tree as uniformly LGPL' not in notice:
    fail('NOTICE no longer says the tree is not uniformly LGPL')
if 'ONNX' not in notice:
    fail('NOTICE does not record that model weights were not imported')

# Every Swift file of this fork names its author (#794): a new file carries the
# new-file header, a file converted from Objective-C keeps the Horos/OsiriX block
# of its original with the author's line right below it. None of them is
# attributed to the Horos Project, which did not write it.
new_header = '''//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
'''
modifications = '*/\n//\n//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork\n'
# DICOM-Swift is Apache-2.0 code of its own, vendored with its LICENSE (#799).
vendored = ('VTK/', 'ITK/', 'DCMTK/', 'GDCM/', 'OpenSSL/', 'OpenJPEG/', 'Horos/Sources/DICOM-Swift/')
swift_files = [name for name in subprocess.run(['git', '-C', str(root), 'ls-files', '*.swift'], check=True,
                                               capture_output=True, text=True).stdout.splitlines()
               if not name.startswith(vendored)]
if len(swift_files) < 400:
    fail('found only %d Swift files of this fork' % len(swift_files))
unattributed = []
for name in swift_files:
    text = (root / name).read_text(encoding='utf-8')
    if text.startswith('#!'):
        text = text[text.index('\n') + 1:]
    if 'Copyright (c) 2026 Horos Project' in text:
        unattributed.append(name + ' (Horos Project)')
    elif text.startswith('/*===='):
        if text[text.index('*/'):].find(modifications) != 0:
            unattributed.append(name + ' (no author line below the Horos block)')
    elif not text.startswith(new_header):
        unattributed.append(name + ' (no new-file header)')
if unattributed:
    fail('%d Swift files do not name the fork author: %s' % (len(unattributed), ', '.join(unattributed[:5])))

# DICOM-Swift (#799): its Apache license travels unchanged, next to the files and
# in the bundle; the README says where they came from; every file the README
# lists as modified carries a modification notice, and only those (Apache 2.0,
# section 4(b)).
dicom_swift = root / 'Horos/Sources/DICOM-Swift'
apache = (dicom_swift / 'LICENSE').read_text(encoding='utf-8')
if 'Apache License' not in apache or 'Version 2.0, January 2004' not in apache or 'Thales Matheus Mendon' not in apache:
    fail('Horos/Sources/DICOM-Swift/LICENSE is not the Apache 2.0 license of DICOM-Swift')
if (root / 'Binaries/Splash/DICOM-Swift-LICENSE.txt').read_bytes() != (dicom_swift / 'LICENSE').read_bytes():
    fail('the bundled DICOM-Swift license differs from the vendored one')
vendored_readme = (dicom_swift / 'README.md').read_text(encoding='utf-8')
for needed in ('1947fefa46e646a23f73019fd083f169088a1ab1', 'Apache License', 'Isis-DICOM-Viewer', 'What was changed'):
    if needed not in vendored_readme:
        fail('the DICOM-Swift README does not give ' + needed)
if 'horos-workbench' in vendored_readme:
    fail('the DICOM-Swift README names the private repository')
listed = {}
for line in vendored_readme.splitlines():
    cells = [cell.strip() for cell in line.split('|')]
    if len(cells) > 3 and cells[1].startswith('`') and cells[1].endswith('.swift`'):
        listed[cells[1].strip('`')] = cells[2]
present = {path.name for path in dicom_swift.glob('*.swift')}
if set(listed) != present:
    fail('the DICOM-Swift README lists %s, the folder has %s' % (sorted(listed), sorted(present)))
for name, status in listed.items():
    marked = (dicom_swift / name).read_text(encoding='utf-8').startswith('// Modified for Horos by Thales Matheus M Santos (ThalesMMS)')
    if marked != status.startswith('modified'):
        fail('%s is %s in the README but %s a modification notice' % (name, status, 'has' if marked else 'lacks'))

code = r'''
import Foundation

precondition(LicenseAttribution.donorRevision == "23722fb552d96fa2d60c7f58a6d4ac2c27950f86")
precondition(LicenseAttribution.donorAuthor == "Yves Starreveld")
precondition(LicenseAttribution.catalogID == "L368")
precondition(LicenseAttribution.originLicenseSHA256 == "d885acd3300b5464fe5e6774610b35fb2d83192f272be3325d69b89d2d666f38")
precondition(LicenseAttribution.originCopyingLesserSHA256 == "c9f740e3eddbb3a01de0d3924a9afd17782567e20c28e55d0e2436376b5c9000")
precondition(!LicenseAttribution.treatsAllComponentsAsLGPL())

let components = LicenseAttribution.components()
let ids = Set(components.map(\.identifier))
for needed in ["fork", "horos", "osirix", "donor", "dcmtk", "itk", "vtk", "gdcm",
               "openjpeg", "openssl", "charls", "dicom-swift", "horoscloud", "weights"] {
    precondition(ids.contains(needed), "missing \(needed)")
}

precondition(!ids.contains("grok"), "Grok is listed, but nothing links it since #617")
let openssl = components.first { $0.identifier == "openssl" }!
precondition(openssl.license == "Apache-2.0")
precondition(openssl.sourcePath == "OpenSSL/upstream/LICENSE.txt")

let dicomSwift = components.first { $0.identifier == "dicom-swift" }!
precondition(dicomSwift.license == "Apache-2.0" && dicomSwift.incorporated)
precondition(dicomSwift.sourcePath == "Horos/Sources/DICOM-Swift/LICENSE")

let fork = components.first { $0.identifier == "fork" }!
precondition(fork.incorporated && fork.license == "LGPLv3" && fork.origin == "fork")
precondition(LicenseAttribution.creditsForkAuthor(in: workbenchLicense))
precondition(LicenseAttribution.creditsForkAuthor(in: LicenseAttribution.aboutCreditsHTML()))
precondition(!LicenseAttribution.aboutCreditsHTML().contains("published by the Horos Project"))
precondition(!LicenseAttribution.creditsForkAuthor(in: originLicense))

let donor = components.first { $0.identifier == "donor" }!
precondition(donor.incorporated)
precondition(donor.origin == "adapted-source")
precondition(donor.name.contains("Yves Starreveld"))

let cloud = components.first { $0.identifier == "horoscloud" }!
precondition(cloud.incorporated)
precondition(cloud.origin == "local-workbench")

let weights = components.first { $0.identifier == "weights" }!
precondition(!weights.incorporated)

precondition(LicenseAttribution.preservesPurviewNotice(in: workbenchLicense))
precondition(LicenseAttribution.creditsDonor(in: workbenchLicense))
precondition(!LicenseAttribution.isBlindOriginReplacement(originLicense: originLicense,
                                                        workbenchLicense: workbenchLicense))
precondition(LicenseAttribution.creditsDonor(in: LicenseAttribution.aboutCreditsHTML()))
precondition(LicenseAttribution.aboutCreditsHTML().contains("AGPLv3"))
precondition(LicenseAttribution.materialQuestions().count >= 3)

let package = URL(fileURLWithPath: packageRoot)
precondition(LicenseAttribution.missingNotices(inDirectory: package).isEmpty)

let incomplete = URL(fileURLWithPath: incompleteRoot)
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("NOTICE"))
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("Splash/licenses.html"))
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("Splash/OpenSSL-LICENSE.txt"))
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("Splash/DICOM-Swift-LICENSE.txt"))

print("PASS: license catalog, Purview, donor credit, AGPL split, bundle notices")
'''

with tempfile.TemporaryDirectory(prefix='horos-license-') as d:
    package = Path(d) / 'Resources'
    (package / 'Splash').mkdir(parents=True)
    for name in ('LICENSE', 'COPYING.LESSER', 'NOTICE'):
        (package / name).write_bytes((root / name).read_bytes())
    (package / 'Splash/about.html').write_bytes((root / 'Binaries/Splash/about.html').read_bytes())
    (package / 'Splash/licenses.html').write_bytes((root / 'Binaries/Splash/licenses.html').read_bytes())
    (package / 'Splash/OpenSSL-LICENSE.txt').write_bytes((root / 'Binaries/Splash/OpenSSL-LICENSE.txt').read_bytes())
    (package / 'Splash/DICOM-Swift-LICENSE.txt').write_bytes((root / 'Binaries/Splash/DICOM-Swift-LICENSE.txt').read_bytes())
    incomplete = Path(d) / 'Incomplete'
    (incomplete / 'Splash').mkdir(parents=True)
    (incomplete / 'LICENSE').write_bytes((root / 'LICENSE').read_bytes())
    (incomplete / 'COPYING.LESSER').write_bytes((root / 'COPYING.LESSER').read_bytes())
    (incomplete / 'Splash/about.html').write_bytes((root / 'Binaries/Splash/about.html').read_bytes())

    swift = Path(d) / 'main.swift'
    swift.write_text(
        'let workbenchLicense = """\n%s\n"""\n'
        'let originLicense = """\n%s\n"""\n'
        'let packageRoot = "%s"\n'
        'let incompleteRoot = "%s"\n'
        '%s' % (
            workbench_license.replace('\\', '\\\\'),
            origin_license.replace('\\', '\\\\'),
            str(package),
            str(incomplete),
            code,
        )
    )
    subprocess.run([
        'xcrun', 'swiftc',
        str(root / 'Horos/Sources/LicenseAttribution.swift'),
        str(swift), '-o', str(Path(d) / 'test'),
    ], check=True)
    subprocess.run([str(Path(d) / 'test')], check=True)

print('PASS: origin snapshots, consolidated LICENSE, credits, catalog L368, the author in %d Swift headers, DICOM-Swift license, origin and modification notices' % len(swift_files))
