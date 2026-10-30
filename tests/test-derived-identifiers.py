#!/usr/bin/env python3
"""A file with no identifier of its own is still given one that UI can hold.

A DICOM without SeriesInstanceUID was indexed with an empty series identifier,
and one without StudyInstanceUID under the patient's name. Both are what the
C-FIND SCP answers with, as a UI - which allows 64 characters of digits and dots.
Measured before the change, a SERIES level query against the database answered
with an empty (0020,000e) and a (0020,000d) of `Noname`.

The identifier is derived from what the importer already groups the object on,
so the same file imported twice lands in the same series; that is why it is not
dcmGenerateUniqueIdentifier, which the exporter uses to make something new.

HorosDerivedUID (the IsiXImaging module's DerivedUID, which the application and
the Decompress helper link) is compiled and run here, and so is HorosDerivedUID.m
of the last revision that has it: both must derive the same UIDs from the same
keys, short, long, empty, missing and not ASCII, under the two roots and a root
too long to leave room for digits.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text
import sources
import history_reference  # noqa: E402
import isix_modules  # noqa: E402
failures = []
# The DICOM reading is Swift (DicomFile+DICOMReading.swift).
importer = sources.class_text('DicomFile')
database = sources.class_text('DicomDatabase')  # DicomDatabase is Swift
# The repair is in the Swift extension; the database still runs it at open.
repair = source_text('DicomDatabase+Other')

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "HorosDerivedUID.h"
static void emit(NSString *key, NSString *value) {
    printf("%s\t%s\n", key.UTF8String, value.UTF8String);
}
int main(void) { @autoreleasepool {
    NSString *a = [HorosDerivedUID seriesUIDForKey: @"study|series one"];
    NSString *b = [HorosDerivedUID seriesUIDForKey: @"study|series one"];
    NSString *c = [HorosDerivedUID seriesUIDForKey: @"study|series two"];
    emit(@"series", a);
    emit(@"stable", [a isEqualToString: b] ? @"yes" : @"no");
    emit(@"distinct", [a isEqualToString: c] ? @"no" : @"yes");
    emit(@"seriesLength", [NSString stringWithFormat: @"%d", (int) a.length]);
    emit(@"seriesConformant", [HorosDerivedUID isConformantUID: a] ? @"yes" : @"no");
    emit(@"seriesRoot", [a hasPrefix: [HorosDerivedUID seriesRoot]] ? @"yes" : @"no");

    NSString *study = [HorosDerivedUID studyUIDForKey: @"QA^NoUID"];
    emit(@"studyConformant", [HorosDerivedUID isConformantUID: study] ? @"yes" : @"no");
    emit(@"studyLength", [NSString stringWithFormat: @"%d", (int) study.length]);
    emit(@"studyRoot", [study hasPrefix: [HorosDerivedUID studyRoot]] ? @"yes" : @"no");
    emit(@"rootsDiffer", [[HorosDerivedUID studyRoot] isEqualToString: [HorosDerivedUID seriesRoot]] ? @"no" : @"yes");

    // An empty key is still a usable identifier, not a crash and not a bare root.
    NSString *empty = [HorosDerivedUID seriesUIDForKey: @""];
    emit(@"emptyKeyConformant", [HorosDerivedUID isConformantUID: empty] ? @"yes" : @"no");
    emit(@"emptyKeyDistinct", [empty isEqualToString: a] ? @"no" : @"yes");
    emit(@"nilKeyConformant", [HorosDerivedUID isConformantUID: [HorosDerivedUID seriesUIDForKey: nil]] ? @"yes" : @"no");

    // What UI cannot hold.
    emit(@"rejectsEmpty", [HorosDerivedUID isConformantUID: @""] ? @"no" : @"yes");
    emit(@"rejectsNil", [HorosDerivedUID isConformantUID: nil] ? @"no" : @"yes");
    emit(@"rejectsLetters", [HorosDerivedUID isConformantUID: @"LOCALIZER1.2.3"] ? @"no" : @"yes");
    emit(@"rejectsDoubleDot", [HorosDerivedUID isConformantUID: @"1..2"] ? @"no" : @"yes");
    emit(@"rejectsLeadingZero", [HorosDerivedUID isConformantUID: @"1.02"] ? @"no" : @"yes");
    emit(@"rejectsTooLong", [HorosDerivedUID isConformantUID:
        [@"" stringByPaddingToLength: 65 withString: @"1" startingAtIndex: 0]] ? @"no" : @"yes");
    emit(@"acceptsZeroComponent", [HorosDerivedUID isConformantUID: @"1.0.2"] ? @"yes" : @"no");
    NSArray *keys = @[@"", @"a", @"study|series one", @"QA^NoUID", @"Ma\u00EFa^\u00C9l\u00E9onore|1.2.3",
                      @"\u60A3\u8005|\u30B7\u30EA\u30FC\u30BA", [@"" stringByPaddingToLength: 300 withString: @"xy" startingAtIndex: 0]];
    for (NSUInteger i = 0; i < 2000; i++)
        keys = [keys arrayByAddingObject: [NSString stringWithFormat: @"%lu|%lu", (unsigned long) i, (unsigned long) (i * 7919)]];
    NSString *longRoot = [@"1." stringByPaddingToLength: 63 withString: @"9" startingAtIndex: 0];
    for (NSString *key in keys) {
        emit([@"series " stringByAppendingString: key], [HorosDerivedUID seriesUIDForKey: key]);
        emit([@"study " stringByAppendingString: key], [HorosDerivedUID studyUIDForKey: key]);
        emit([@"short root " stringByAppendingString: key], [HorosDerivedUID uidForKey: key root: @"1.2"]);
        emit([@"long root " stringByAppendingString: key], [HorosDerivedUID uidForKey: key root: longRoot]);
    }
    emit(@"nil key", [HorosDerivedUID seriesUIDForKey: nil]);
    for (NSString *value in @[@"0", @"00", @"1.0", @"1.00", @"\u0661.2", @"1.2.", @".1", @"1.2.3"])
        emit([@"conformant " stringByAppendingString: value], [HorosDerivedUID isConformantUID: value] ? @"yes" : @"no");
    return 0;
} }
'''

def derive(work, name, flags):
    built = subprocess.run(['xcrun', 'clang', '-fobjc-arc', *flags, str(work / 'main.m'), '-framework', 'Foundation',
                            '-o', str(work / name)], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('%s does not compile:\n%s' % (name, built.stderr[-1200:]))
        return None
    run = subprocess.run([str(work / name)], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        failures.append('the %s driver failed: %s' % (name, run.stderr[-600:]))
    return run.stdout


results = {}
with tempfile.TemporaryDirectory(prefix='horos-derived-uid-') as directory:
    work = Path(directory)
    (work / 'main.m').write_text(DRIVER)
    module = work / 'IsiXImaging'
    current = derive(work, 'module', ['-I', str(root / 'Horos/Sources'), *isix_modules.clang_module_flags('IsiXImaging', module),
                                      *isix_modules.link_flags('IsiXImaging', module)])
    for line in (current or '').splitlines():
        key, _, value = line.partition('\t')
        results[key] = value
    # The Objective-C class it replaced, from the last revision that has it.
    reference = history_reference.before_removal('Horos/Sources/HorosDerivedUID.m')
    if reference is None and subprocess.run(['git', '-C', str(root), 'cat-file', '-e', 'HEAD:Horos/Sources/HorosDerivedUID.m'],
                                            capture_output=True).returncode == 0:
        reference = 'HEAD'  # removed in the working tree, not yet committed
    if reference is None:
        print('skipped: no revision of this history has HorosDerivedUID.m to compare with', file=sys.stderr)
    else:
        old = work / 'old'
        old.mkdir()
        for name in ('HorosDerivedUID.h', 'HorosDerivedUID.m'):
            (old / name).write_bytes(history_reference.show(reference, 'Horos/Sources/' + name))
        (work / 'main.m').write_text(DRIVER.replace('#import "HorosDerivedUID.h"', '#import "%s"' % (old / 'HorosDerivedUID.h')))
        former = derive(work, 'former', ['-I', str(old), str(old / 'HorosDerivedUID.m')])
        if current and former and current != former:
            lines = [(a, b) for a, b in zip(former.splitlines(), current.splitlines()) if a != b]
            failures.append('the module derives other UIDs than HorosDerivedUID.m at %s: %s' % (reference[:12], lines[:3]))
        elif current and former:
            print('PASS: %d results identical to HorosDerivedUID.m at %s' % (len(current.splitlines()), reference[:12]))

if results:
    for key in ('stable', 'distinct', 'seriesConformant', 'seriesRoot', 'studyConformant',
                'studyRoot', 'rootsDiffer', 'emptyKeyConformant', 'emptyKeyDistinct',
                'nilKeyConformant', 'rejectsEmpty', 'rejectsNil', 'rejectsLetters',
                'rejectsDoubleDot', 'rejectsLeadingZero', 'rejectsTooLong',
                'acceptsZeroComponent'):
        if results.get(key) != 'yes':
            failures.append('%s is %r, expected yes' % (key, results.get(key)))
    for key in ('seriesLength', 'studyLength'):
        length = int(results.get(key, '0') or 0)
        if not 30 <= length <= 64:
            failures.append('%s is %d, which is not a usable UID length' % (key, length))

# --- the importer derives when the file carries nothing ----------------------
if 'DerivedUID.studyUID(forKey:' not in importer:
    failures.append('a file with no StudyInstanceUID is still indexed under the patient name')
if 'DerivedUID.seriesUID(forKey:' not in importer:
    failures.append('a file with no SeriesInstanceUID still leaves the identifier empty')
if not re.search(r'\(elements\.object\(forKey: "seriesDICOMUID"\) as\? NSString\)\?\.length \?\? 0\) == 0', importer):
    failures.append('the derivation does not check whether the file already carried one')
# And the grouping must be unchanged: the derived value comes from the key the
# importer groups on, not from something new.
at = importer.find('DerivedUID.seriesUID(forKey:')
if at > 0 and 'serieID ?? "(null)"' not in importer[at - 200:at + 200]:
    failures.append('the derived series identifier does not come from the grouping key, so a '
                    're-import would land somewhere else')

# --- and rows indexed before that are repaired -------------------------------
if 'repairEmptySeriesIdentifiersInContext:' not in repair:
    failures.append('series indexed before this still answer C-FIND with an empty identifier')
else:
    at = repair.find('@objc(repairEmptySeriesIdentifiersInContext:)')
    end = repair.find('@objc(', at + 1)
    body = repair[at:end if end > at else len(repair)] if at >= 0 else ''
    if 'seriesDICOMUID == nil OR seriesDICOMUID ==' not in body:
        failures.append('the repair does not select the rows that have no identifier')
    if 'try context.save()' not in body:
        failures.append('the repair does not save through the context, so nothing persists')
    if 'seriesInstanceUID' not in body or 'study.studyInstanceUID' not in body:
        failures.append('the repair does not derive from what the row is grouped on')
    if 'DicomDatabase.repairEmptySeriesIdentifiers(in: self.managedObjectContext)' not in database:
        failures.append('the repair is never run')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an object with no identifier gets a conformant one derived from what it is grouped '
      'on, the same one every time, and rows indexed before are repaired at open')
