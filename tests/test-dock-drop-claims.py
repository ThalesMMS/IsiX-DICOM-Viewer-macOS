#!/usr/bin/env python3
"""The application takes folders, discs, archives and any file dropped on its Dock icon.

    python3 tests/test-dock-drop-claims.py [APPLICATION]

Horos claimed everything with the OSTypes '****', 'fold' and 'disk' of its
"DICOM Image" document type, so a folder of DICOM files dropped on the Dock
icon was imported. That entry then gained LSItemContentTypes [org.nema.dicom]
for Quick Look, and LaunchServices reads nothing else of an entry that has
that key: the OSTypes, the extensions and the MIME types beside it were
ignored, and the Dock refused folders, discs, archives and DICOM files without
an extension.

In Horos/Info.plist:

- "DICOM Image" keeps org.nema.dicom and the dcm extension, and nothing an
  entry with LSItemContentTypes cannot claim;
- an entry claims folders, volumes and zip archives by their types, and an
  entry without LSItemContentTypes claims any file by '****' with the
  osirixzip and dcmURLs extensions; both as a viewer of alternate rank, so the
  application takes those without becoming what opens them;
- no entry puts '****', 'fold' or 'disk' beside LSItemContentTypes, where
  they would be ignored;
- what is dropped is remembered for a sandboxed build before it is imported.

With APPLICATION, a built bundle LaunchServices knows (one that was opened),
LaunchServices itself is asked whether the application accepts a folder, a
volume, a zip archive, .osirixzip, .dcmURLs, a DICOM file without an extension
and a .dcm file. Without it, that part is not run.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

from sources import source_text

ROOT = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


info = plistlib.loads((ROOT / 'Horos/Info.plist').read_bytes())
types = info['CFBundleDocumentTypes']
ignored = {'****', 'fold', 'disk'}
for entry in types:
    if entry.get('LSItemContentTypes'):
        beside = ignored & set(entry.get('CFBundleTypeOSTypes', []))
        check(not beside, f'{entry.get("CFBundleTypeName")}: {sorted(beside)} beside LSItemContentTypes are ignored by LaunchServices')

dicom = [entry for entry in types if 'dcm' in entry.get('CFBundleTypeExtensions', [])]
check(len(dicom) == 1 and dicom[0].get('LSItemContentTypes') == ['org.nema.dicom'] and dicom[0].get('LSHandlerRank') == 'Default',
      'the DICOM document type is not bound to org.nema.dicom alone, as the default viewer')

by_type = [entry for entry in types if {'public.folder', 'public.volume', 'public.zip-archive'} <= set(entry.get('LSItemContentTypes', []))]
check(len(by_type) == 1, 'no entry claims folders, volumes and zip archives by their types')
wildcard = [entry for entry in types if not entry.get('LSItemContentTypes') and '****' in entry.get('CFBundleTypeOSTypes', [])]
check(len(wildcard) == 1, 'no entry without LSItemContentTypes claims any file by ****')
for entry in by_type + wildcard:
    check(entry.get('LSHandlerRank') == 'Alternate' and entry.get('CFBundleTypeRole') == 'Viewer',
          f'{entry.get("CFBundleTypeName")}: not a viewer of alternate rank')
if wildcard:
    check({'osirixzip', 'dcmURLs'} <= set(wildcard[0].get('CFBundleTypeExtensions', [])), 'the wildcard entry does not name osirixzip and dcmURLs')
    check({'fold', 'disk'} <= set(wildcard[0].get('CFBundleTypeOSTypes', [])), 'the wildcard entry does not name fold and disk')
check(not [entry for entry in types if entry.get('LSHandlerRank') in ('Default', 'Owner')
           and (set(entry.get('LSItemContentTypes', [])) & {'public.folder', 'public.volume', 'public.zip-archive', 'public.data', 'public.item'}
                or '****' in entry.get('CFBundleTypeOSTypes', []))],
      'the application claims folders, archives or every file as their default application')

dropped = source_text('DroppedFilesImport')
add = dropped[dropped.index('func add(_ paths: [String], overriding overrides: [AnyHashable: Any] = [:]) {'):]
check(add.index('for path in paths { SandboxFileAccess.remember(URL(fileURLWithPath: path)) }') < add.index('DroppedItemsPlan.actions(forDroppedPaths: paths'),
      'what is dropped is not remembered for a sandboxed build before it is imported')
handler = source_text('ExternalRequestHandler')
check('browser?.subSelectFilesAndFolders(toAdd: passed)' in handler, 'files opened from the Finder no longer go to the import')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('PASS: DICOM Image keeps org.nema.dicom; folders, volumes and zip archives are claimed by type and any file by ****, as an alternate viewer; '
      'what is dropped is remembered before it is imported')

if len(sys.argv) < 2:
    print('NOTE: no APPLICATION given: LaunchServices was not asked')
    sys.exit(0)

application = Path(sys.argv[1]).resolve()
built = plistlib.loads((application / 'Contents/Info.plist').read_bytes())
built_types = [(entry.get('CFBundleTypeName'), entry.get('LSItemContentTypes'), entry.get('CFBundleTypeOSTypes')) for entry in built['CFBundleDocumentTypes']]
source_types = [(entry.get('CFBundleTypeName'), entry.get('LSItemContentTypes'), entry.get('CFBundleTypeOSTypes')) for entry in types]
if built_types != source_types:
    print(f'FAIL: {application} was not built from this Info.plist')
    sys.exit(1)

program = r'''
import CoreServices
import Foundation
let application = URL(fileURLWithPath: CommandLine.arguments[1])
var refused = 0
for argument in CommandLine.arguments.dropFirst(2) {
    let parts = argument.split(separator: "=", maxSplits: 2).map(String.init)
    let expected = parts[0] == "yes"
    var accepts: DarwinBoolean = false
    let status = LSCanURLAcceptURL(URL(fileURLWithPath: parts[2]) as CFURL, application as CFURL, .all, [], &accepts)
    let answer = status == noErr && accepts.boolValue
    print("\(answer == expected ? "ok  " : "FAIL") \(parts[1]): \(answer ? "accepted" : "refused")\(status == noErr ? "" : " (status \(status))")")
    if answer != expected { refused += 1 }
}
exit(refused == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='horos-dock-drop-') as directory:
    work = Path(directory)
    items = work / 'items'
    (items / 'folder with DICOM').mkdir(parents=True)
    dicom = b'\0' * 128 + b'DICM' + b'\x02\x00\x00\x00UL\x04\x00\x00\x00\x00\x00'
    (items / 'folder with DICOM/IM0001').write_bytes(dicom)
    (items / 'empty folder').mkdir()
    (items / 'IM0002').write_bytes(dicom)
    (items / 'image.dcm').write_bytes(dicom)
    subprocess.run(['/usr/bin/zip', '-q', '-j', str(items / 'study.zip'), str(items / 'IM0002')], check=True)
    (items / 'study.osirixzip').write_bytes((items / 'study.zip').read_bytes())
    (items / 'list.dcmURLs').write_text('https://example.invalid/wado?objectUID=1\n')
    (work / 'main.swift').write_text(program)
    build = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'cache'), str(work / 'main.swift'), '-o', str(work / 'ask')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    asked = [('a folder with DICOM files', items / 'folder with DICOM'), ('an empty folder', items / 'empty folder'), ('a volume', Path('/')),
             ('a zip archive', items / 'study.zip'), ('.osirixzip', items / 'study.osirixzip'), ('.dcmURLs', items / 'list.dcmURLs'),
             ('a DICOM file without an extension', items / 'IM0002'), ('a .dcm file', items / 'image.dcm')]
    done = subprocess.run([str(work / 'ask'), str(application), *(f'yes={name}={path}' for name, path in asked)], capture_output=True, text=True, timeout=120)
    print(done.stdout.strip())
    if done.returncode:
        print(f'FAIL: LaunchServices does not accept everything for {application}; if the bundle was never opened, it does not know it yet')
        sys.exit(1)
print('PASS: LaunchServices accepts a folder, a volume, a zip archive, .osirixzip, .dcmURLs, a DICOM file without an extension and a .dcm file for the application')
