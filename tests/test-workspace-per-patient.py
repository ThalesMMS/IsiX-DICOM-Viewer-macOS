#!/usr/bin/env python3
"""A study's saved workspace holds only the viewers of its own patient.

+[ViewerController saveWindowsStateWithDICOMSR:name:] wrote the whole layout,
every displayed viewer, into the windowsState of each study shown: with two
patients side by side, one patient's workspace (and its DICOM SR) held the
other's series, window and zoom. Each study now keeps the viewers whose study
has its patientUID, compared as -databaseOpenStudy: compares them. Part of a
layout is saved without window frames or tiling, which describe the whole of
it; the loader treats an entry without a window position as a partial layout
and tiles the viewers it opens.

The production HorosWindowsStateOfPatient runs here; the call site and the
loader are checked in the sources.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('utf-8')
start = viewer.index('static NSArray *HorosWindowsStateOfPatient(')
helper = viewer[start:viewer.index('\n}\n', start) + 3]

code = r'''
#import <Foundation/Foundation.h>
HELPER
#define check(...) do { if (!(__VA_ARGS__)) { NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } } while (0)
static NSDictionary *entry(NSString *series) {
    return @{@"seriesInstanceUID": series, @"window position": @"110 79 905 889", @"screen": @"{{110, 79}, {1810, 889}}",
             @"screenIndex": @0, @"LastWindowsTilingRowsColumns": @"12", @"wl": @40, @"ww": @400, @"scale": @1.5};
}
int main() { @autoreleasepool {
    NSArray *state = @[entry(@"A1"), entry(@"B1"), entry(@"A2")];
    NSArray *patients = @[@"DOE^JOHN-1", @"ROE^JANE-2", @"doe^john-1"];

    // Each patient keeps its own viewers, in order, without the layout's frames.
    NSArray *a = HorosWindowsStateOfPatient(state, patients, @"Doe^John-1");
    check(a.count == 2 && [a[0][@"seriesInstanceUID"] isEqual:@"A1"] && [a[1][@"seriesInstanceUID"] isEqual:@"A2"]);
    for (NSDictionary *d in a) {
        check(d[@"window position"] == nil && d[@"screen"] == nil && d[@"screenIndex"] == nil && d[@"LastWindowsTilingRowsColumns"] == nil);
        check([d[@"wl"] isEqual:@40] && [d[@"ww"] isEqual:@400] && [d[@"scale"] isEqual:@1.5]);
    }
    NSArray *b = HorosWindowsStateOfPatient(state, patients, @"ROE^JANE-2");
    check(b.count == 1 && [b[0][@"seriesInstanceUID"] isEqual:@"B1"] && b[0][@"window position"] == nil);
    check(state[0][@"window position"] != nil); // the whole layout is not changed

    // One patient: the whole layout, frames and tiling kept.
    NSArray *single = HorosWindowsStateOfPatient(@[entry(@"A1"), entry(@"A2")], @[@"P", @"P"], @"P");
    check(single.count == 2 && [single[0][@"window position"] isEqual:@"110 79 905 889"] && [single[1][@"LastWindowsTilingRowsColumns"] isEqual:@"12"]);

    // A missing patientUID is the empty one on both sides; another patient keeps nothing.
    check(HorosWindowsStateOfPatient(@[entry(@"X")], @[@""], nil).count == 1);
    check(HorosWindowsStateOfPatient(state, patients, @"OTHER").count == 0);
    NSLog(@"PASS: each patient keeps its own viewers; part of a layout loses its frames; one patient keeps all");
}}
'''.replace('HELPER', helper)

with tempfile.TemporaryDirectory(prefix='horos-workspace-patient-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-framework', 'Foundation', str(p / 'test.m'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

save = viewer[viewer.index('+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name'):]
save = save[:save.index('\n}\n')]
assert '[statePatients addObject: [[view seriesObj] valueForKeyPath:@"study.patientUID"] ?: @""];' in save
studies = save[save.index('for( DicomStudy *study in studiesArray)'):]
assert 'HorosWindowsStateOfPatient( state, statePatients, [study valueForKey:@"patientUID"])' in studies
assert '[study setValue: studyState forKey:@"windowsState"];' in studies and 'setValue: windowsState forKey' not in studies, \
    'a study is still given the whole layout'
loader = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.swift').read_text(encoding='utf-8')
assert 'viewersToLoad.contains { objcValue($0, "window position") == nil }' in loader, 'a layout saved without frames is not tiled'
print('PASS: workspaces are saved per patient and restored by tiling when partial')
