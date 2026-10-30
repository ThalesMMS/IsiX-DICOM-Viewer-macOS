#!/usr/bin/env python3
"""The DICOM value types answer through DCMTK as DCM.framework did through its own tables.

DCMTransferSyntax (the dataset model, IsiXDICOMDataset), the dates of
IsiXDICOMFile and the DICOM reader's text decoding ask the host's
HorosDICOMServices (DcmXfer, DCMTK's DA/TM/DT parsers, oficonv). The same
driver is built twice: against the former DCM.framework of the last revision
that has it (`git show`), without the host services - its own tables and
parsers - and against the current model and module with them; their answers
are compared:

- every transfer syntax DCMTK knows, and some it does not: name and flags;
- DA, TM and DT values, full, partial, fractional, with offsets and invalid;
- text in each DICOM character set: DCMTK's conversion against the former
  table's.

A difference fails unless it is one of the corrections listed below. Also
checks that every standard UID IsiXDICOMFile names is one DCMTK knows.

Usage: python test-dcm-host-services.py [--reference REV]
       Exit 2 without the Debug build's DCMTK or the history.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402
from isix_modules import build_module, dicom_file_flags  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--reference', help='revision of the former DCM.framework (default: the last that has it)')
parser.add_argument('products', nargs='?', help='ignored; the DCMTK of the Debug build is used')
arguments = parser.parse_args()
FRAMEWORK = 'DCM Framework'
PROBE = FRAMEWORK + '/DCMCalendarDate.m'


def git(*command):
    return subprocess.run(['git', '-C', str(ROOT), *command], capture_output=True)


reference = arguments.reference
if reference is None:
    reference = 'HEAD' if git('cat-file', '-e', 'HEAD:' + PROBE).returncode == 0 else history_reference.before_removal(PROBE)
if reference is None:
    print('skipped: needs the history that has DCM.framework', file=sys.stderr)
    raise SystemExit(2)
if not (BUILD / 'DCMTK.build/Install/lib/libdcmnet.a').is_file():
    print('skipped: needs the Debug build\'s DCMTK from script/build_and_run.sh --verify', file=sys.stderr)
    raise SystemExit(2)
flags = dcmtk_flags('dcmnet')
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
# The former framework's classes the driver asks, compiled from the reference
# with every header of the framework beside them.
FORMER = ['DCMTransferSyntax', 'DCMCalendarDate', 'DCMCharacterSet']

header = (ROOT / 'DCMTK/dcmdata/include/dcmtk/dcmdata/dcxfer.h').read_text(errors='replace')
syntaxes = sorted(set(re.findall(r'"(1\.2\.840\.10008\.1\.2[0-9.]*)"',
                                 (ROOT / 'DCMTK/dcmdata/include/dcmtk/dcmdata/dcuid.h').read_text(errors='replace'))))
syntaxes += ['1.2.3.4', '1.2.840.10008.1.2.4.9999']

DATES = ['20260926', '2026.09.26', '19000101', '20261345', '20260230', '202609', '2026', '0', '20260926 ']
TIMES = ['123456', '123456.789', '123456.000001', '1234', '12', '12:34:56', '12:34:56.5', '246060', '000000', '235959.999999']
DATETIMES = ['20260926123456', '20260926123456.123456', '20260926123456+0200', '20260926123456.5-0300',
             '20260926123456.123+0530', '2026092612', '202609261234', '20260926', '2026', '20261345123456']

driver = r'''
#import <Foundation/Foundation.h>
#ifdef HOST
// The current classes, under the names the former framework gave them.
#import "DCMModel.h"
#import "HorosDICOMServices.h"
@compatibility_alias DCMCalendarDate IsiXDICOMCalendarDate;
#else
#import "DCM.h"
#endif
static id orNull(id v) { return v ?: [NSNull null]; }
static NSDictionary *describe(DCMCalendarDate *d)
{
    if (d == nil) return (id) [NSNull null];
    return @{@"instant": @(d.timeIntervalSinceReferenceDate), @"date": orNull([d dateString]),
             @"time": orNull([d timeStringWithMilliseconds]), @"dateTime": orNull([d dateTimeString: YES]),
             @"description": orNull([d description])};
}
int main(int argc, char **argv) { @autoreleasepool {
    NSDictionary *input = [NSJSONSerialization JSONObjectWithData: [NSData dataWithContentsOfFile: @(argv[1])] options: 0 error: NULL];
    // The first transfer syntaxes of a process are asked for on many threads
    // at once, as the first files of an import are read: released together,
    // none may find the syntax table half built.
    {
        NSArray *first = input[@"syntaxes"];
        __block volatile int ready = 0, done = 0;
        __block volatile BOOL go = NO;
        for (int t = 0; t < 8; t++)
            [NSThread detachNewThreadWithBlock: ^{
                @autoreleasepool {
                    __sync_fetch_and_add(&ready, 1);
                    while (!go) {}
                    for (NSUInteger i = 0; i < first.count; i++)
                        [[[DCMTransferSyntax alloc] initWithTS: first[(i + t) % first.count]] release];
                }
                __sync_fetch_and_add(&done, 1);
            }];
        while (ready < 8) {}
        go = YES;
        while (done < 8) usleep(1000);
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableDictionary *syntaxes = [NSMutableDictionary dictionary];
    for (NSString *uid in input[@"syntaxes"]) {
        DCMTransferSyntax *ts = [[[DCMTransferSyntax alloc] initWithTS: uid] autorelease];
        syntaxes[uid] = @{@"name": orNull(ts.name), @"encapsulated": @(ts.isEncapsulated),
                          @"littleEndian": @(ts.isLittleEndian), @"explicit": @(ts.isExplicit)};
    }
    out[@"syntaxes"] = syntaxes;
    NSMutableDictionary *dates = [NSMutableDictionary dictionary];
    for (NSString *s in input[@"dates"]) dates[[@"DA " stringByAppendingString: s]] = describe([DCMCalendarDate dicomDate: s]);
    for (NSString *s in input[@"times"]) dates[[@"TM " stringByAppendingString: s]] = describe([DCMCalendarDate dicomTime: s]);
    for (NSString *s in input[@"datetimes"]) dates[[@"DT " stringByAppendingString: s]] = describe([DCMCalendarDate dicomDateTime: s]);
    out[@"dates"] = dates;
    // Text: the former table's reading without the host, DCMTK's with it.
    NSMutableDictionary *texts = [NSMutableDictionary dictionary];
    for (NSDictionary *sample in input[@"texts"]) {
        NSData *bytes = [[NSData alloc] initWithBase64EncodedString: sample[@"bytes"] options: 0];
#ifdef HOST
        NSString *text = [HorosDICOMCharacterSets stringWithBytes: (const char *) bytes.bytes length: bytes.length characterSet: sample[@"code"]];
#else
        DCMCharacterSet *set = [[[DCMCharacterSet alloc] initWithCode: sample[@"code"]] autorelease];
        NSString *text = [DCMCharacterSet stringWithBytes: (char *) bytes.bytes length: (unsigned) bytes.length encodings: set.encodings];
#endif
        texts[sample[@"code"]] = orNull(text);
        [bytes release];
    }
    out[@"texts"] = texts;
    NSData *json = [NSJSONSerialization dataWithJSONObject: out options: NSJSONWritingSortedKeys error: NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    return 0;
}}
'''

# One name per DICOM defined term, with the Python codec that writes it.
TEXTS = [
    ('ISO_IR 100', 'latin-1', 'Müller^José'), ('ISO_IR 101', 'iso8859-2', 'Dvořák^Łukasz'),
    ('ISO_IR 144', 'iso8859-5', 'Иванов^Иван'), ('ISO_IR 126', 'iso8859-7', 'Παπαδόπουλος'),
    ('ISO_IR 138', 'iso8859-8', 'כהן'), ('ISO_IR 148', 'iso8859-9', 'Yılmaz^Ağa'),
    ('ISO_IR 127', 'iso8859-6', 'محمد'), ('ISO_IR 166', 'tis-620', 'สมชาย'),
    ('ISO_IR 192', 'utf-8', '山田^太郎=やまだ'), ('GB18030', 'gb18030', '王^小明'), ('GBK', 'gbk', '李^四'),
]
import base64
samples = [{'code': c, 'text': t, 'bytes': base64.b64encode(t.encode(codec)).decode()} for c, codec, t in TEXTS]

with tempfile.TemporaryDirectory(prefix='horos-host-services-') as work:
    work = Path(work)
    (work / 'bin').mkdir()
    (work / 'driver.mm').write_text(driver)
    (work / 'input.json').write_text(json.dumps({'syntaxes': syntaxes, 'dates': DATES, 'times': TIMES,
                                                 'datetimes': DATETIMES, 'texts': samples}))
    # The former framework: every header of the reference, its three classes compiled.
    framework = work / 'framework'
    framework.mkdir()
    listed = git('ls-tree', '--name-only', reference, FRAMEWORK + '/').stdout.decode().split('\n')
    for path in filter(None, listed):
        if path.endswith('.h'):
            (framework / Path(path).name).write_bytes(git('show', '%s:%s' % (reference, path)).stdout)
    former_objects = []
    for name in FORMER:
        (framework / (name + '.m')).write_bytes(git('show', '%s:%s/%s.m' % (reference, FRAMEWORK, name)).stdout)
        subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', '-mmacosx-version-min=15.0', '-I', str(framework),
                        '-c', str(framework / (name + '.m')), '-o', str(work / (name + '.former.o'))], check=True)
        former_objects.append(str(work / (name + '.former.o')))
    # The current side: the model's DCMTransferSyntax (the IsiXDICOMDataset
    # module, over IsiXDICOMFile) and the services, a DCMTK adapter compiled
    # with ARC; the protocols they adopt are the modules'.
    module_includes, module_links = dicom_file_flags(work / 'modules')
    build_module('IsiXDICOMDataset', work / 'modules', ['-target', 'arm64-apple-macos15.0'])
    module_links = [str(work / 'modules/libIsiXDICOMDataset.a'), *module_links]
    module_includes = [*module_includes, '-I', str(ROOT / 'Horos/Sources')]
    current = []
    for name in ('HorosDICOMServices.mm', 'IsiXDCMTKError.mm'):
        subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-fmodules', '-fcxx-modules', '-w', '-I', str(ADAPTERS), *module_includes, *flags[:2],
                        '-c', str(ADAPTERS / name), '-o', str(work / (name + '.o'))], check=True)
        current.append(str(work / (name + '.o')))
    common = ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-fmodules', '-fcxx-modules', '-w', '-mmacosx-version-min=15.0']
    subprocess.run([*common, '-I', str(framework), '-x', 'objective-c++', str(work / 'driver.mm'), '-x', 'none',
                    *former_objects, '-framework', 'Foundation', '-o', str(work / 'bin/former')], check=True)
    subprocess.run([*common, '-DHOST', '-I', str(ADAPTERS), *module_includes, *flags[:2], '-x', 'objective-c++',
                    str(work / 'driver.mm'), '-x', 'none', *current, '-framework', 'Foundation', *flags[2:], *module_links,
                    '-o', str(work / 'bin/host')], check=True)
    env = {**os.environ, 'TZ': 'America/Sao_Paulo'}
    former = json.loads(subprocess.run([str(work / 'bin/former'), str(work / 'input.json')], capture_output=True, check=True, env=env).stdout)
    host = json.loads(subprocess.run([str(work / 'bin/host'), str(work / 'input.json')], capture_output=True, check=True, env=env).stdout)

failures, corrections = [], []

# Transfer syntaxes: the ones the former table named must answer the same.
FORMER_UNKNOWN = {'name': 'Unknown Syntax', 'encapsulated': True, 'littleEndian': True, 'explicit': True}
for uid in syntaxes:
    a, b = former['syntaxes'][uid], host['syntaxes'][uid]
    if a == b:
        continue
    if a == FORMER_UNKNOWN and b['name'] != 'Unknown Syntax':
        corrections.append('syntax %s: DCMTK knows it: %s' % (uid, b))
    elif a == FORMER_UNKNOWN and b == FORMER_UNKNOWN:
        continue
    else:
        failures.append('syntax %s: %s, formerly %s' % (uid, b, a))

# Dates: the same instant and strings, except where the former parser invented
# a date for an impossible value or placed a fractional date-time with an
# offset in the local zone.
EXPECTED_DATE_CHANGES = {
    'DA 20261345': 'impossible month: no date instead of an invented one',
    'DA 20260230': 'impossible day: no date instead of an invented one',
    'TM 246060': 'impossible time: no time instead of an invented one',
    'DT 20261345123456': 'impossible month: no date-time instead of an invented one',
    'DT 20260926123456.5-0300': 'the offset places the instant, not only the label',
    'DT 20260926123456.123+0530': 'the offset places the instant, not only the label',
    'DT 20260926123456+0200': 'same instant, shown in its own offset as the fractional form always was',
}
for key in sorted(former['dates']):
    a, b = former['dates'][key], host['dates'][key]
    if a == b:
        continue
    if key in EXPECTED_DATE_CHANGES:
        corrections.append('%s: %s (%s -> %s)' % (key, EXPECTED_DATE_CHANGES[key],
                                                  a and a.get('dateTime'), b and b.get('dateTime')))
    else:
        failures.append('%s: %s, formerly %s' % (key, b, a))

# Text: DCMTK has to give the name back; where the former table did too, the two agree.
expected_texts = {sample['code']: sample['text'] for sample in samples}
for code, dcmtk in sorted(host['texts'].items()):
    if dcmtk != expected_texts[code]:
        failures.append('%s: DCMTK reads %r, the name is %r' % (code, dcmtk, expected_texts[code]))
    elif former['texts'][code] != expected_texts[code]:
        corrections.append('%s: DCMTK reads the name the former table did not (%r)' % (code, former['texts'][code]))

# UIDs: every standard one IsiXDICOMFile names is one DCMTK knows.
sop_classes = (ROOT / 'Modules/IsiXDICOMFile/Sources/DICOMSOPClass.swift').read_text(encoding='utf-8')
named = dict(re.findall(r'static let\s+(\w+)\s*=\s*"([0-9.]+)"', sop_classes))
known = set(re.findall(r'#define\s+UID_\w+\s+"([0-9.]+)"',
                       (ROOT / 'DCMTK/dcmdata/include/dcmtk/dcmdata/dcuid.h').read_text(errors='replace')))
for name, uid in sorted(named.items()):
    if not re.fullmatch(r'[1-9][0-9]*(\.(0|[1-9][0-9]*))+', uid):
        failures.append('UID %s (%s) is not a well-formed UID' % (name, uid))
    elif uid.startswith('1.2.840.10008.') and uid not in known:
        failures.append('UID %s (%s) is not one DCMTK knows' % (name, uid))
vendor = sum(1 for uid in named.values() if not uid.startswith('1.2.840.10008.'))

print('%d transfer syntaxes, %d date/time values, %d character sets and %d standard UIDs compared; '
      '%d vendor UIDs are not DICOM\'s' % (len(syntaxes), len(former['dates']), len(host['texts']),
                                           len(named) - vendor, vendor))
for c in corrections:
    print('corrected: ' + c)
for f in failures:
    print('FAIL: ' + f)
sys.exit(1 if failures else 0)
