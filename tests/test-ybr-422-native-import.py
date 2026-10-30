#!/usr/bin/env python3
"""Native YBR_FULL_422 is imported and shown in its colours.

YBR_FULL_422 subsamples the chrominance horizontally: native pixel data stores
two pixels as Y Y Cb Cr, two bytes per pixel at 8 bits, although the object
declares three samples per pixel. The incoming triage (EnhancedImportTriage,
IVUSImportTriage for ultrasound) required three bytes per pixel and sent every
such file to NOT READABLE ("Pixel Data is 6144 bytes where 9216 are needed"
for 64 x 48); the rule is now IsiXDICOMFile's
DICOMImportRules.storedSamplesPerPixel, which DicomFile's pixel check uses too.

The files come from tools/generate-colour-space-fixture.py, 64 x 48: the same
picture as interleaved RGB, as YBR_FULL_422 and, grey, as YBR_FULL_422.

1. triage: both triage sources (of the tree, or of `--revision`, the negative
   control), compiled with the module, let the two YBR_FULL_422 files and the
   RGB one into the database.
2. in the application (the Debug development bundle, a copy with an injected
   driver; skipped with --triage-only): the three files put into INCOMING are
   indexed and none goes to NOT READABLE; DCMPix then loads each indexed file
   and its ARGB pixels must be the RGB file's colours (the grey one, grey),
   within the error that sharing one chrominance pair between two pixels makes.

Exit 2 without a Python with pydicom, numpy and Pillow (HOROS_PYTHON or the
local venvs), or without the Debug bundle for the second part.

    python3 tests/test-ybr-422-native-import.py [--revision REV] [--triage-only] [--keep DIR]
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import native_app  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--revision', help='read the triage sources from this revision (negative control)')
parser.add_argument('--triage-only', action='store_true', help='only the triage part')
parser.add_argument('--app', type=Path, default=native_app.DEVELOPMENT_APP)
parser.add_argument('--keep', type=Path, help='keep the answers and the log here')
arguments = parser.parse_args()

TRIAGE = ['Horos/Sources/DICOMTriageMetadata.swift', 'Horos/Sources/WrappedImageFragments.swift',
          'Horos/Sources/EnhancedImportTriage.swift', 'Horos/Sources/IVUSImportTriage.swift']
FILES = ['rgb-interleaved.dcm', 'ybr-422.dcm', 'ybr-422-grey.dcm']
ROWS, COLUMNS = 48, 64
# One chrominance pair for two pixels, and the integer matrix: the picture's
# red and green change by 4 a column, so a pixel's colour is off by a few levels.
TOLERANCE = 12


def find_python():
    candidates = [os.environ.get('HOROS_PYTHON'), str(ROOT / 'local-validation/venv/bin/python'),
                  str(ROOT.parent.parent.parent / 'local-validation/net-venv/bin/python')
                  if ROOT.parent.name == 'worktrees' else None,
                  str(ROOT / 'local-validation/net-venv/bin/python'), sys.executable]
    for candidate in filter(None, candidates):
        if Path(candidate).exists() and subprocess.run([candidate, '-c', 'import pydicom, numpy, PIL'],
                                                       capture_output=True).returncode == 0:
            return candidate
    return None


def source(path):
    if arguments.revision:
        return subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (arguments.revision, path)],
                              capture_output=True, check=True).stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


TRIAGE_DRIVER = r'''
import Foundation
let folder = CommandLine.arguments[1]
var failed = false
for name in CommandLine.arguments.dropFirst(2) {
    let path = folder + "/" + name
    let stack = EnhancedImportTriage.assessPath(path), ivus = IVUSImportTriage.assessPath(path)
    let merged = ivus.appliesToFile ? ivus.mayMergeIntoIncoming : stack.mayMergeIntoIncoming
    let why = (ivus.appliesToFile ? ivus.recordedError : stack.recordedError) ?? "nothing"
    print("\(name): \(merged ? "merged" : "refused") (\(why))")
    if !merged || stack.recordedError != nil || ivus.recordedError != nil { failed = true }
}
exit(failed ? 1 : 0)
'''

APP_DRIVER = r'''
#import <Cocoa/Cocoa.h>

@interface NSObject (YBR422Probe)
- (id)initWithPath:(NSString *)s :(long)pos :(long)tot :(float *)ptr :(long)f :(long)ss isBonjour:(BOOL)hello imageObj:(id)iO;
- (void)CheckLoad;
- (float *)fImage;
- (long)pwidth;
- (long)pheight;
- (BOOL)isRGB;
@end

// Waits for go.json (the indexed files), loads each with DCMPix and writes its
// size, whether it is colour, and its ARGB pixels as [R, G, B] to answers.json.
__attribute__((constructor)) static void IsiXYBR422Start(void)
{
    NSString *exchange = NSProcessInfo.processInfo.environment[@"ISIX_YBR422_EXCHANGE"];
    if (!exchange) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *go = [exchange stringByAppendingPathComponent:@"go.json"];
        while (![NSFileManager.defaultManager fileExistsAtPath:go]) usleep(200000);
        @autoreleasepool {
            NSDictionary *paths = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:go] options:0 error:NULL];
            NSMutableDictionary *answers = [NSMutableDictionary dictionary];
            for (NSString *name in paths) {
                id pix = [[NSClassFromString(@"DCMPix") alloc] initWithPath:paths[name] :0 :1 :NULL :0 :0 isBonjour:NO imageObj:nil];
                [pix CheckLoad];
                unsigned char *argb = pix ? (unsigned char *) [pix fImage] : NULL;
                long width = pix ? [pix pwidth] : 0, height = pix ? [pix pheight] : 0;
                BOOL colour = pix ? [pix isRGB] : NO;
                NSMutableArray *pixels = [NSMutableArray array];
                if (argb && colour)
                    for (long i = 0; i < width * height; i++)
                        [pixels addObject:@[@(argb[4 * i + 1]), @(argb[4 * i + 2]), @(argb[4 * i + 3])]];
                answers[name] = @{@"loaded": @(argb != NULL), @"rgb": @(colour), @"width": @(width), @"height": @(height),
                                  @"pixels": pixels};
            }
            NSData *data = [NSJSONSerialization dataWithJSONObject:answers options:0 error:NULL];
            [data writeToFile:[exchange stringByAppendingPathComponent:@".answers.json"] atomically:YES];
            [NSFileManager.defaultManager moveItemAtPath:[exchange stringByAppendingPathComponent:@".answers.json"]
                                                  toPath:[exchange stringByAppendingPathComponent:@"answers.json"] error:NULL];
        }
    });
}
'''


def triage(work, files):
    (work / 'triage').mkdir()
    sources = []
    for path in TRIAGE:
        target = work / 'triage' / Path(path).name
        target.write_text(source(path), encoding='utf-8')
        sources.append(str(target))
    (work / 'triage' / 'main.swift').write_text(TRIAGE_DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', *isix_modules.module_flags('IsiXDICOMFile', work / 'modules'), *sources,
                            str(work / 'triage' / 'main.swift'), '-o', str(work / 'triage' / 'check')],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        raise SystemExit('FAIL: the triage does not compile:\n' + built.stderr[-3000:])
    run = subprocess.run([str(work / 'triage' / 'check'), str(files), *FILES], capture_output=True, text=True, timeout=60)
    print(run.stdout, end='')
    if run.returncode:
        raise SystemExit('FAIL: the incoming triage refuses a file it can index')


def in_app(work, files, expected):
    app = arguments.app
    if not (app / 'Contents/MacOS/IsiX DICOM Viewer').exists() or not (ROOT / 'build/Development/entitlements.plist').exists():
        print('skipped: the import and DCMPix part needs the Debug bundle from script/build_and_run.sh --verify')
        raise SystemExit(2)
    (work / 'driver.m').write_text(APP_DRIVER)
    library = work / 'driver.dylib'
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-framework', 'Cocoa', str(work / 'driver.m'),
                    '-o', str(library)], check=True, capture_output=True, timeout=300)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)], check=True, capture_output=True)
    bundle = work / 'HorosDevelopment.app'
    shutil.copytree(app, bundle, symlinks=True)
    entitlements = plistlib.loads((ROOT / 'build/Development/entitlements.plist').read_bytes())
    entitlements['com.apple.security.cs.allow-dyld-environment-variables'] = True
    (work / 'entitlements.plist').write_bytes(plistlib.dumps(entitlements))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements',
                    str(work / 'entitlements.plist'), str(bundle)], check=True, capture_output=True)
    exchange = work / 'exchange'
    exchange.mkdir()
    test_root = work / 'root'
    process = native_app.launch(test_root, work / 'app.log', ['-ApplePersistenceIgnoreState', 'YES'], app=bundle,
                                environment={'DYLD_INSERT_LIBRARIES': str(library), 'ISIX_YBR422_EXCHANGE': str(exchange)})
    try:
        data = native_app.wait_for(lambda: process.poll() is not None or (
            (native_app.database_folder(test_root) / 'INCOMING.noindex').is_dir() and native_app.database_folder(test_root)),
            120, description='the database to open')
        if process.poll() is not None:
            raise SystemExit('FAIL: the application ended before the import (%s)' % process.returncode)
        for name in FILES:
            staging = data / 'INCOMING.noindex' / ('.%s.part' % name)
            shutil.copy(files / name, staging)
            os.rename(staging, data / 'INCOMING.noindex' / name)
        refused = data / 'NOT READABLE'

        def settled():
            if process.poll() is not None:
                return 'ended'
            if refused.is_dir() and any(p.is_file() for p in refused.rglob('*')):
                return 'refused'
            if (native_app.image_count(test_root) or 0) >= len(FILES) and \
                    len(list((data / 'DATABASE.noindex').rglob('*.dcm'))) >= len(FILES):
                return 'indexed'
            return None
        state = native_app.wait_for(settled, 180, interval=0.5, description='the import')
        time.sleep(2)  # what else the import does with a refused file
        if refused.is_dir() and any(p.is_file() for p in refused.rglob('*')):
            raise SystemExit('FAIL: the import sent %s to NOT READABLE'
                             % sorted(p.name for p in refused.rglob('*') if p.is_file()))
        if state != 'indexed':
            raise SystemExit('FAIL: the import did not index the files (%s)' % state)

        # The indexed copies, told apart by their series description.
        script = ('import json, sys, pydicom\n'
                  'print(json.dumps({p: str(pydicom.dcmread(p, stop_before_pixels=True).SeriesDescription) '
                  'for p in sys.argv[1:]}))\n')
        indexed = sorted(str(p) for p in (data / 'DATABASE.noindex').rglob('*.dcm'))
        described = json.loads(subprocess.run([python, '-c', script, *indexed], capture_output=True, text=True,
                                              check=True).stdout)
        paths = {}
        for entry in expected:
            if entry['name'] + '.dcm' in FILES:
                found = [p for p, description in described.items() if description == entry['series']]
                if len(found) != 1:
                    raise SystemExit('FAIL: %s is indexed %d times' % (entry['name'], len(found)))
                paths[entry['name']] = found[0]
        (exchange / '.go.json').write_text(json.dumps(paths))
        (exchange / '.go.json').rename(exchange / 'go.json')
        native_app.wait_for(lambda: (exchange / 'answers.json').exists() or process.poll() is not None, 120,
                            description='DCMPix')
        if not (exchange / 'answers.json').exists():
            raise SystemExit('FAIL: the application ended while DCMPix loaded the files (%s)' % process.returncode)
    finally:
        native_app.stop(process)
        if arguments.keep:
            arguments.keep.mkdir(parents=True, exist_ok=True)
            for name in ('app.log', 'exchange/answers.json'):
                if (work / name).exists():
                    shutil.copy(work / name, arguments.keep / Path(name).name)
    return json.loads((exchange / 'answers.json').read_text())


def compare(answers, expected):
    failures = []
    columns = {entry['name']: entry['columns'] for entry in expected}
    reference = answers.get('rgb-interleaved', {}).get('pixels', [])
    for name, answer in sorted(answers.items()):
        if not answer['loaded'] or not answer['rgb'] or (answer['width'], answer['height']) != (COLUMNS, ROWS):
            failures.append('%s: DCMPix loaded %s, colour %s, %d x %d' % (name, answer['loaded'], answer['rgb'],
                                                                          answer['width'], answer['height']))
            continue
        pixels = answer['pixels']
        # The file's own colours, for every row of the picture.
        wanted = [columns[name][index % COLUMNS] for index in range(len(pixels))]
        worst = max(max(abs(a - b) for a, b in zip(got, want)) for got, want in zip(pixels, wanted))
        if worst > (0 if name == 'rgb-interleaved' else TOLERANCE):
            failures.append('%s: a pixel is %d levels from the colour the file carries' % (name, worst))
        if name == 'ybr-422':
            against_rgb = max(max(abs(a - b) for a, b in zip(got, want)) for got, want in zip(pixels, reference))
            print('%s: at most %d levels from the file\'s colours, %d from the RGB file as DCMPix shows it'
                  % (name, worst, against_rgb))
            if against_rgb > TOLERANCE:
                failures.append('ybr-422: a pixel is %d levels from the same picture in RGB' % against_rgb)
        else:
            print('%s: at most %d levels from the file\'s colours' % (name, worst))
    return failures


python = find_python()
if python is None:
    print('skipped: the files need a Python with pydicom, numpy and Pillow (HOROS_PYTHON)')
    raise SystemExit(2)

with tempfile.TemporaryDirectory(prefix='isix-ybr-422-') as directory:
    work = Path(directory)
    files = work / 'files'
    subprocess.run([python, str(ROOT / 'tools/generate-colour-space-fixture.py'), str(files), '--rows', str(ROWS),
                    '--columns', str(COLUMNS)], check=True, capture_output=True, timeout=120)
    expected = json.loads((files / 'expected.json').read_text())
    triage(work, files)
    if arguments.triage_only or arguments.revision:
        print('PASS: the incoming triage lets native YBR_FULL_422 in')
        raise SystemExit(0)
    answers = in_app(work, files, expected)
    failures = compare(answers, expected)
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        raise SystemExit(1)
    print('PASS: native YBR_FULL_422 passes the triage, is indexed without going to NOT READABLE, and DCMPix '
          'shows it in the colours of the same picture in RGB (grey stays grey)')
