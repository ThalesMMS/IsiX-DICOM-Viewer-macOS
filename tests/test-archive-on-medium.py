#!/usr/bin/env python3
"""A disc carrying a ZIP imports the rest of the disc as well.

`-[DicomDatabase scanAtPath:isVolume:]` expands an archive it meets into a
temporary place and scans that. It asked for the place like this:

    NSString* tempPath = [NSFileManager.defaultManager tmpFilePathInDir:self.tempDirPath];
    [NSFileManager.defaultManager confirmDirectoryAtPath:tempPath];

`-tmpFilePathInDir:` is `mkstemp`, which *creates* the file and leaves it there,
so `-confirmDirectoryAtPath:` on the same path found a file in its way and
raised. `scanAtPath:` rethrows from its `@catch`, so the whole medium went with
it. Measured on a disc holding a DICOMDIR, the same instances loose in EXPANDED/
and the same instances again inside expanded.zip:

    (scanAtPath): Scanning DICOMDIR at /Volumes/HOROSCD/DICOMDIR
    NSGenericException (in -[MountedDatabaseNodeIdentifier volumeScanThread]):
      Cannot create directory: an existing file occupies /private/var/folders/...
    --- volumeScanThread: end
      studies 0  series 0  images 0

Nothing at all, from a disc whose index alone named ten instances. With a
temporary directory asked for instead, and the branch wrapped so one archive
cannot take the medium with it, the same disc with 400 instances written three
times over - 806 files - ends at 1 study, 4 series, 400 images in 1.4 s; and
pulled out one second in, at 196 copied, 196 indexed and 196 files, with nothing
to tidy up by hand.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import is_swift, source_text  # noqa: E402

failures = []
scan = (root / 'Horos/Sources/DicomDatabase+Scan.mm').read_bytes().decode('latin1')
# NSFileManager (N2) is Swift; the checks below name both spellings.
manager = source_text('NSFileManager+N2')
swift = is_swift('NSFileManager+N2')
SPELLING = {
    # what                   Objective-C                              Swift
    'selector':          ('tmpDirectoryPathInDir:',                '@objc(tmpDirectoryPathInDir:)'),
    'definition':        ('-(NSString*)tmpDirectoryPathInDir:',    'func tmpDirectoryPath(inDir dirPath'),
    'end of body':       ('\n}',                                   '\n    }\n'),
    'confirm parent':    ('confirmDirectoryAtPath:dirPath',        'confirmDirectory(atPath: dirPath)'),
    'in tmp':            ('-(NSString*)tmpDirectoryPathInTmp',     'func tmpDirectoryPathInTmp()'),
    'calls in dir':      ('tmpDirectoryPathInDir',                 'tmpDirectoryPath(inDir:'),
}
spelled = {key: pair[1 if swift else 0] for key, pair in SPELLING.items()}
header = (root / 'Nitrogen/Sources/NSFileManager+N2.h').read_text(errors='replace')

code = re.sub(r'//[^\n]*', '', scan)
at = code.find('osirixzip')
if at < 0:
    failures.append('the branch that expands an archive found on a medium is gone')
else:
    branch = code[at:at + 1800]
    if 'tmpFilePathInDir' in branch:
        failures.append('the archive is still expanded into a path made for a file, and making a '
                        'directory there raises')
    if 'tmpDirectoryPathInDir' not in branch:
        failures.append('the archive is not expanded into a temporary directory')
    if '@catch' not in branch:
        failures.append('an archive that raises still takes the whole medium with it')
    if 'the rest of the medium is still read' not in scan:
        failures.append('nothing says the medium carried on after an archive it could not expand')
    if 'unzipFile' not in branch or 'scanAtPath:tempPath' not in branch:
        failures.append('the archive is no longer expanded and scanned')

live = re.sub(r'//[^\n]*', '', manager)
if spelled['selector'] not in live:
    failures.append('there is no way to ask for a temporary directory inside a chosen directory')
else:
    at = live.find(spelled['definition'])
    body = live[at:live.find(spelled['end of body'], at)] if at >= 0 else ''
    if 'mkdtemp' not in body:
        failures.append('the temporary directory is not made by mkdtemp')
    if spelled['confirm parent'] not in body:
        failures.append('the parent directory is not made first, so the first archive on a fresh '
                        'database fails')
    at = live.find(spelled['in tmp'])
    if at < 0:
        failures.append('-tmpDirectoryPathInTmp is gone')
    elif spelled['calls in dir'] not in live[at:at + 200]:
        failures.append('the two ways of asking for a temporary directory have drifted apart')
if 'tmpDirectoryPathInDir:' not in header:
    failures.append('the new method is not declared, so nothing outside the category can use it')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an archive on a medium is expanded into a directory of its own, and one it cannot '
      'expand does not stop the rest of the medium')
