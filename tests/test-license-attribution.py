#!/usr/bin/env python3
"""License texts, credits and bundle notices stay complete and are not a blind origin replace."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
# Public-distribution check. Internal donor snapshots and audit manifests are
# verified separately, not required by these checks of distributed notices.
origin_copying_sha = 'c9f740e3eddbb3a01de0d3924a9afd17782567e20c28e55d0e2436376b5c9000'


def fail(message):
    print('FAIL:', message, file=sys.stderr)
    sys.exit(1)


for name in ('LICENSE', 'COPYING.LESSER', 'NOTICE', 'Binaries/Splash/about.html',
             'Binaries/Splash/licenses.html', 'Binaries/Splash/OpenSSL-LICENSE.txt',
             'Binaries/Splash/DICOM-Swift-LICENSE.txt'):
    if not (root / name).is_file():
        fail('required distributed notice is missing: ' + name)
if hashlib.sha256((root / 'COPYING.LESSER').read_bytes()).hexdigest() != origin_copying_sha:
    fail('COPYING.LESSER no longer contains the unchanged LGPLv3 and GPLv3 texts')

workbench_license = (root / 'LICENSE').read_text(encoding='utf-8')
if 'Purview' not in workbench_license or 'HorosCloud' not in workbench_license:
    fail('root LICENSE dropped the Purview/HorosCloud notice')
if 'Yves Starreveld' not in workbench_license:
    fail('root LICENSE does not credit Yves Starreveld')
# Nothing links Grok: LICENSE and NOTICE must not say it does.
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

for text, label in ((notice, 'NOTICE'), (licenses_html, 'licenses.html')):
    for credit in ('KFSplitView', 'Ken Ferry', 'Kirk Baker', 'John Pannell', 'CC BY-NC 1.0'):
        if credit not in text:
            fail(label + ' omitted split compatibility credit: ' + credit)

# The shipped provenance records are verified offline, without internal docs.
import json
manifest = json.loads((root / 'Horos/Sources/ThirdParty/Libarchive/UPSTREAM.json').read_text())
if manifest['revision'] != '5649597e7975dd1f8c24ab0176f131f47a1cdae0': fail('unexpected Apple libarchive revision')
for name, record in manifest['files'].items():
    data = (root / 'Horos/Sources/ThirdParty/Libarchive' / name).read_bytes()
    if len(data) != record['size'] or hashlib.sha256(data).hexdigest() != record['sha256'] or hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest() != record['git_blob_sha1']:
        fail('libarchive header differs from Apple pin: ' + name)
if manifest['header_version'] != '3.7.4' or 'macOS' not in manifest['runtime']: fail('libarchive header/runtime distinction missing')
# Exercise the existing selector: source integrity, single selection, adjusted copies.
import importlib.util
spec = importlib.util.spec_from_file_location('feedback_prepare', root / 'Horos/Scripts/FeedbackReporter/prepare.py')
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)
with tempfile.TemporaryDirectory(prefix='horos-feedback-provenance-') as scratch:
    prepared = selector.prepare(root / 'FeedbackReporter', Path(scratch) / 'prepared')
    record = json.loads((prepared / 'BuildSource.json').read_text())
    if record['revision'] != '92230feade69e1298cd5a8cbc0c8ddd2dc939934' or len(record['hostSources']) != 4: fail('incorrect FeedbackReporter selection identity')
    for name, digest in record['hostSources'].items():
        source = root / 'Horos/FeedbackReporter' / name
        if hashlib.sha256(source.read_bytes()).hexdigest() != digest: fail('host source identity mismatch: ' + name)
        if b'Modified in this fork:' not in source.read_bytes(): fail('host Apache source lacks notice: ' + name)
        if (prepared / 'Sources/Main' / name).resolve() != source.resolve(): fail('wrong host source selected: ' + name)
    adjusted = list((prepared / 'Resources').glob('*.lproj/FeedbackReporter.xib'))
    if len(adjusted) != 8 or any(b'Modified in this fork:' not in f.read_bytes() for f in adjusted): fail('adjusted XIB lacks notice')
provenance = json.loads((root / 'Binaries/Splash/ThirdParty/Provenance.json').read_text())
ids = set()
for component in provenance['components']:
    ids.add(component['id'])
    if not component['origin'] or not component['license'] or not component['roles'] or not component['consumer']:
        fail('incomplete source/resource classification: ' + component['id'])
    for name, record in component['files'].items():
        path = root / name
        if component['roles'] == ['stored-only'] and not path.exists(): continue
        data = path.read_bytes()
        if len(data) != record['size'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            fail('distributed provenance mismatch: ' + name)
        if 'members' in record:
            import zipfile
            with zipfile.ZipFile(path) as archive:
                members = {entry.filename for entry in archive.infolist() if not entry.is_dir()}
                if members != set(record['members']): fail('archive member inventory mismatch: ' + name)
                for member, expected in record['members'].items():
                    content = archive.read(member)
                    if len(content) != expected['size'] or hashlib.sha256(content).hexdigest() != expected['sha256']:
                        fail('archive member content mismatch: ' + name + '/' + member)
selected_data = next(component for component in provenance['components']
                     if component['id'] == 'selected-anonymization-data')
if selected_data['version'] != '3.2.11' or selected_data['license'] != 'BSD-3-Clause' or \
        selected_data['roles'] != ['source', 'build', 'runtime-data']:
    fail('selected anonymization data provenance changed its scope or terms')
if selected_data['notice'] != 'Compatibility/SelectedAnonymizationCatalog-Copyright.txt' or \
        'Horos/Sources/HorosSelectedAnonymizationCatalog.h' not in selected_data['files']:
    fail('derived dictionary data provenance lacks source and independent notice')
if selected_data.get('runtime_library') is not False:
    fail('selected dictionary data is falsely classified as a runtime library')
vtk = next(component for component in provenance['components'] if component['id'] == 'vtk')
vtk_source = json.loads((root / vtk['source_manifest']).read_text())['VTK']
vtk_freetype = json.loads((root / vtk['freetype_source_manifest']).read_text())
if vtk['source_selection'] != vtk_source or vtk_source['sourcePatches'] != [] or not vtk_source['readOnly']:
    fail('VTK provenance differs from the selected original read-only source')
if vtk['freetype_source_selection'] != vtk_freetype or vtk_freetype['archiveSha256'] != vtk_source['sha256']:
    fail('FreeType source does not belong to the selected original VTK release')
vtk_license = root / 'Binaries/Splash/ThirdParty/Native/VTK/Copyright.txt'
if hashlib.sha256(vtk_license.read_bytes()).hexdigest() != vtk_source['licenseSha256']:
    fail('bundled VTK copyright differs from the original source selection')
if vtk['host_binary_adaptation']['bundled_record'] != 'Contents/Resources/CompiledSources/VTK/freetype-host-adaptation.json':
    fail('VTK binary adaptation is not identified separately in the product')
installer = next(component for component in provenance['components'] if component['id'] == 'lets-move')
installer_manifest = json.loads((root / installer['source_manifest']).read_text())
if installer['implementation'] != installer_manifest['implementation'] or installer['implementation'] != 'native-host':
    fail('installer provenance does not identify the native host engine')
if installer['upstream_sources_shipped'] is not False or installer_manifest['upstream_sources_shipped'] is not False:
    fail('installer catalog falsely claims the inspected provider is shipped')
if installer['inspected_candidate'] != installer_manifest['inspected_candidate']:
    fail('installer candidate decision differs from source record')
if installer_manifest['source'] not in installer['files']:
    fail('installer provenance omits the actual Swift implementation')
if not {'libarchive-headers', 'nifti', 'feedback-reporter', 'portal-javascript', 'legacy-controls', 'weasis-portable', 'validator'} <= ids:
    fail('source/resource catalog omits active families')
print('PASS: offline upstream headers, FeedbackReporter deltas and distributed source/payload hashes')

# Every Swift file of this fork names its author: a new file carries the
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
# Third-party sources keep their original licenses; the resolved public client
# has no Swift source in the host checkout.
vendored = ('VTK/', 'ITK/', 'DCMTK/', 'OpenSSL/', 'OpenJPEG/')
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

# The public client is resolved as a package; only unchanged license/provenance
# snapshots belong in the host. No embedded client source remains.
apache = (root / 'Binaries/Splash/DICOM-Swift-LICENSE.txt').read_text(encoding='utf-8')
if 'Apache License' not in apache or 'Version 2.0, January 2004' not in apache or 'Thales Matheus Mendon' not in apache:
    fail('the bundled DICOM-Swift license lacks original Apache terms/credit')
if (root / 'Horos/Sources/DICOM-Swift').exists():
    fail('the embedded DICOMweb client coexists with the public package')
import json
package_lock = json.loads((root / 'Horos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
client_pin = next(pin for pin in package_lock['pins'] if pin['identity'] == 'dicom-swift')
if client_pin['location'] != 'https://github.com/ThalesMMS/DICOM-Swift.git' or client_pin['state']['version'] != '2.0.2':
    fail('the public client pin is not the approved exact release')
if client_pin['state']['revision'] != 'f60fe313b669fefc4c3bc6e5dfa342901168a175':
    fail('the public client revision differs from the selected release')
client_family = next(component for component in provenance['components'] if component['id'] == 'dicom-swift')
if client_family['selected_pin'] != client_pin:
    fail('delivered public client provenance differs from the actual host pin')
resolved_only = [pin for pin in package_lock['pins'] if pin['identity'] != 'dicom-swift']
if client_family['resolved_only_dependencies'] != resolved_only:
    fail('optional resolution was conflated with selected package products')
spec = importlib.util.spec_from_file_location('release_metadata', root / 'script/release-metadata.py')
release_metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_metadata)
notice_files = {str(Path('Binaries') / bundled): source
                for source, bundled in release_metadata.PACKAGE_NOTICE_PATHS.items()}
if client_family['package_notice_files'] != notice_files:
    fail('delivered client notices differ from the effective release selection')
objects = release_metadata.project_objects(root)
host_target = next(item for item in objects.values() if item.get('isa') == 'PBXNativeTarget' and item.get('name') == 'Horos')
products = sorted(objects[ref]['productName'] for ref in host_target['packageProductDependencies'])
if client_family['direct_products'] != products or client_family['transitive_products'] != ['DicomData']:
    fail('delivered client product scope differs from the Horos target selection')
public_provenance = json.loads((root / 'Binaries/Splash/ThirdParty/DICOMSwift/DistributionProvenance.json').read_text())
materials = {item['id']: item for item in public_provenance['materials']}
dictionary_origins = {item['id'] for item in public_provenance['embeddedOrigins']
                      if any(path.startswith('Sources/DicomData/') for path in item.get('destinationPatterns', []))}
if set(client_family['dictionary_origin_ids']) != dictionary_origins:
    fail('generated dictionary data lost its separate original origins')
for identifier, bundled in {
    'pydicom/LICENSE': 'pydicom/LICENSE', 'DCMTK/COPYRIGHT': 'DCMTK/COPYRIGHT',
    'GDCM/Copyright.txt': 'GDCM/Copyright.txt',
    'GDCM/Source/DataDictionary/COPYRIGHT.dicom3tools': 'GDCM/COPYRIGHT.dicom3tools',
}.items():
    path = root / 'Binaries/Splash/ThirdParty/DICOMSwift' / bundled
    if hashlib.sha256(path.read_bytes()).hexdigest() != materials[identifier]['sha256']:
        fail('public generated-dictionary material does not match its provenance: ' + identifier)

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
for needed in ["fork", "horos", "osirix", "donor", "dcmtk", "itk", "vtk",
               "openjpeg", "openssl", "charls", "dicom-swift", "horoscloud", "weights",
               "feedback-reporter", "cocoa-http-server", "dicom3tools", "weasis", "kfsplitview"] {
    precondition(ids.contains(needed), "missing \(needed)")
}

let split = components.first { $0.identifier == "kfsplitview" }!
precondition(split.origin == "independent-implementation" && split.incorporated)
precondition(split.license.contains("historical CC BY-NC 1.0"))
precondition(split.distributionNote.contains("Ken Ferry") && split.distributionNote.contains("Kirk Baker") && split.distributionNote.contains("John Pannell"))

precondition(!ids.contains("gdcm"), "the retired GDCM runtime is listed")
let vtk = components.first { $0.identifier == "vtk" }!
precondition(vtk.sourcePath == "Horos/Scripts/external-sources.json")
precondition(vtk.origin == "upstream release archive")
precondition(vtk.distributionNote.contains("binary adaptation record"))
let selectedData = components.first { $0.identifier == "selected-anonymization-data" }!
precondition(selectedData.license == "BSD-3-Clause" && selectedData.incorporated)
precondition(selectedData.origin == "derived-dictionary-data")
precondition(selectedData.sourcePath == "Binaries/Splash/ThirdParty/Compatibility/SelectedAnonymizationCatalog-Copyright.txt")
precondition(LicenseAttribution.requiredThirdPartyResourceNames.contains("Compatibility/SelectedAnonymizationCatalog-Copyright.txt"))

precondition(!ids.contains("grok"), "Grok is listed, but nothing links it")
let openssl = components.first { $0.identifier == "openssl" }!
precondition(openssl.license == "Apache-2.0")
precondition(openssl.sourcePath == "OpenSSL/upstream/LICENSE.txt")

let dicomSwift = components.first { $0.identifier == "dicom-swift" }!
precondition(dicomSwift.license == "Apache-2.0" && dicomSwift.incorporated)
precondition(dicomSwift.sourcePath == "Binaries/Splash/DICOM-Swift-LICENSE.txt")
precondition(dicomSwift.origin == "remote-package")
precondition(dicomSwift.distributionNote.contains("2.0.2") && dicomSwift.distributionNote.contains("f60fe313b669fefc4c3bc6e5dfa342901168a175"))
precondition(!dicomSwift.distributionNote.contains("Horos/Sources/DICOM-Swift"))

let fork = components.first { $0.identifier == "fork" }!
precondition(fork.incorporated && fork.license == "LGPLv3" && fork.origin == "fork")
precondition(LicenseAttribution.creditsForkAuthor(in: workbenchLicense))
precondition(LicenseAttribution.creditsForkAuthor(in: LicenseAttribution.aboutCreditsHTML()))
precondition(!LicenseAttribution.aboutCreditsHTML().contains("published by the Horos Project"))
precondition(!LicenseAttribution.creditsForkAuthor(in: "Copyright Horos Project"))

let donor = components.first { $0.identifier == "donor" }!
precondition(donor.incorporated)
precondition(donor.sourcePath == "LICENSE")
precondition(donor.origin == "adapted-source")
precondition(donor.name.contains("Yves Starreveld"))

let cloud = components.first { $0.identifier == "horoscloud" }!
precondition(cloud.incorporated)
precondition(cloud.origin == "local-fork")

let weights = components.first { $0.identifier == "weights" }!
precondition(!weights.incorporated)

precondition(LicenseAttribution.preservesPurviewNotice(in: workbenchLicense))
precondition(LicenseAttribution.creditsDonor(in: workbenchLicense))
precondition(!LicenseAttribution.isBlindOriginReplacement(originLicense: "Copyright Horos Project",
                                                        workbenchLicense: workbenchLicense))
precondition(LicenseAttribution.isBlindOriginReplacement(originLicense: workbenchLicense,
                                                       workbenchLicense: workbenchLicense))
precondition(LicenseAttribution.creditsDonor(in: LicenseAttribution.aboutCreditsHTML()))
precondition(donor.license == "LGPLv3" && donor.sourcePath == "LICENSE")
precondition(LicenseAttribution.snapshotDirectory == "docs/third-party/donor-horos-23722fb552d96fa2d60c7f58a6d4ac2c27950f86")
precondition(!LicenseAttribution.aboutCreditsHTML().contains("License texts from that revision are versioned"))
precondition(!components.contains { $0.sourcePath.hasPrefix("docs/") })
precondition(LicenseAttribution.materialQuestions().count >= 3)

let package = URL(fileURLWithPath: packageRoot)
precondition(LicenseAttribution.missingNotices(inDirectory: package).isEmpty)
// Every required resource is a real omission, even without internal audit files.
let required = LicenseAttribution.requiredRootResourceNames
    + LicenseAttribution.requiredSplashResourceNames.map { "Splash/\($0)" }
    + LicenseAttribution.requiredThirdPartyResourceNames.map { "Splash/ThirdParty/\($0)" }
for name in required {
    let file = package.appendingPathComponent(name)
    let saved = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    precondition(LicenseAttribution.missingNotices(inDirectory: package) == [name])
    try Data().write(to: file)
    precondition(LicenseAttribution.missingNotices(inDirectory: package) == [name])
    try saved.write(to: file)
}
// A transitive notice is required through its real index link, too.
let transitive = package.appendingPathComponent("Splash/ThirdParty/Native/VTK/ThirdParty/freetype/vtkfreetype/docs/FTL.TXT")
let transitiveData = try Data(contentsOf: transitive)
try FileManager.default.removeItem(at: transitive)
precondition(LicenseAttribution.missingNotices(inDirectory: package).contains("Splash/ThirdParty/Native/VTK/ThirdParty/freetype/vtkfreetype/docs/FTL.TXT"))
try transitiveData.write(to: transitive)


let incomplete = URL(fileURLWithPath: incompleteRoot)
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("NOTICE"))
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("Splash/licenses.html"))
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("Splash/OpenSSL-LICENSE.txt"))
precondition(LicenseAttribution.missingNotices(inDirectory: incomplete).contains("Splash/DICOM-Swift-LICENSE.txt"))

print("PASS: license catalog, Purview, donor credit, distinct component terms, bundle notices")
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
    shutil.copytree(root / 'Binaries/Splash/ThirdParty', package / 'Splash/ThirdParty')
    incomplete = Path(d) / 'Incomplete'
    (incomplete / 'Splash').mkdir(parents=True)
    (incomplete / 'LICENSE').write_bytes((root / 'LICENSE').read_bytes())
    (incomplete / 'COPYING.LESSER').write_bytes((root / 'COPYING.LESSER').read_bytes())
    (incomplete / 'Splash/about.html').write_bytes((root / 'Binaries/Splash/about.html').read_bytes())

    swift = Path(d) / 'main.swift'
    swift.write_text(
        'let workbenchLicense = """\n%s\n"""\n'
        'let packageRoot = "%s"\n'
        'let incompleteRoot = "%s"\n'
        '%s' % (
            workbench_license.replace('\\', '\\\\'),
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

print('PASS: unchanged LGPL/GPL texts, consolidated LICENSE, credits, catalog L368, the author in %d Swift headers, DICOM-Swift public pin, licenses and dictionary provenance' % len(swift_files))
