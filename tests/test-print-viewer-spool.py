#!/usr/bin/env python3
"""The legacy viewer spools its printed frames privately, or refuses.

Printing requires that hidden identifiers not survive "nos metadados, frames,
páginas ou **temporários**", and that a print job never comes out incomplete.
The viewer wrote every rendered frame to a fixed `/tmp/print` — the same path
for every user of the machine and every job, pre-creatable by anyone — and
appended the path to the job whether or not the write had worked. `printView`
draws nothing for a missing file, so a failed write printed a blank cell and
said nothing.

This compiles the real methods against the real `HorosPrintSelection`, with a
genuine image and a genuine directory. The spool methods, -endPrint: and
-printOperationDidRun:success:contextInfo: are Swift, in
ViewerController+Export+PrintMovie.swift: they are taken from there as they
stand and compiled with swiftc as an extension of a Swift double of the viewer
that has the `horos_printSpoolDirectory` accessor they use; -dealloc stays in
ViewerController.m.
"""
from pathlib import Path
import re
import json
import xml.etree.ElementTree as ET
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from sources import source_text

root = Path(__file__).resolve().parents[1]
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
swift_viewer = source_text('ViewerController+Export+PrintMovie')
failures = []

start = swift_viewer.index('    @objc(preparePrintSpoolDirectory)')
methods = swift_viewer[start:swift_viewer.index('    @objc(presentPrintPreparationFailure)', start)]

helper_start = swift_viewer.index('/// Layout titles retain a numeric grid prefix')
layout_helpers = swift_viewer[helper_start:swift_viewer.index('/// volumeData[index]', helper_start)]
assert 'restorePrintLayout(self.horos_printLayout, settings: p)' in swift_viewer

EXTENSION = '''
import AppKit
''' + layout_helpers + '''

// The viewer's print spool accessor (ViewerController+SwiftIvars.h).
@objc(Viewer) public class Viewer: NSObject {
    @objc public var horos_printSpoolDirectory: String?
}

public extension Viewer {
''' + methods + '''
    @MainActor @objc func restoreLayout(_ popup: NSPopUpButton, settings: NSDictionary?) {
        restorePrintLayout(popup, settings: settings)
    }
}
'''

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import "Horos-Swift.h"

@interface Viewer (Spool)
- (NSString *)spool;
@end

@implementation Viewer (Spool)
- (NSString *)spool { return self.horos_printSpoolDirectory; }
@end

static NSImage *SyntheticFrame(void) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    [image lockFocus];
    [[NSColor colorWithDeviceWhite:0.25 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 8, 8));
    [image unlockFocus];
    return image;
}

#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); return 1; } } while (0)

int main(void) { @autoreleasepool {
    NSArray *englishLayouts = ENGLISH_LAYOUTS;
    NSArray *portugueseLayouts = PORTUGUESE_LAYOUTS;
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popup addItemsWithTitles:portugueseLayouts];
    for (NSUInteger i = 0; i < popup.numberOfItems; i++)
        [popup itemAtIndex:i].tag = [LAYOUT_TAGS[i] integerValue];
    Viewer *layoutViewer = [[Viewer alloc] init];
    // Equal image counts do not collapse different grid orientations.
    [layoutViewer restoreLayout:popup settings:@{ @"layout": englishLayouts[2], @"columns": @2, @"rows": @1 }];
    CHECK([popup.selectedItem.title isEqual:portugueseLayouts[2]] && popup.selectedItem.tag == 2,
          "English 2x1 preference did not retain its grid in Portuguese");
    [layoutViewer restoreLayout:popup settings:@{ @"layout": englishLayouts[6] }];
    CHECK([popup.selectedItem.title isEqual:portugueseLayouts[6]], "legacy title did not restore 3x2 in Portuguese");
    for (NSDictionary *settings in @[@{ @"layout": @"unknown layout" },
                                    @{ @"layout": @"", @"columns": @0, @"rows": @0 },
                                    @{ @"layout": @"unknown", @"columns": @-1, @"rows": @2 },
                                    @{ @"columns": @999, @"rows": @999 }]) {
        [layoutViewer restoreLayout:popup settings:settings];
        CHECK([popup.selectedItem.title isEqual:portugueseLayouts[0]] && popup.selectedItem.tag == 1,
              "invalid saved layout left the popup empty or unsafe");
    }
    [popup selectItem:nil];
    [layoutViewer restoreLayout:popup settings:@{ @"layout": englishLayouts[0], @"columns": @1, @"rows": @1 }];
    CHECK([popup.selectedItem.title isEqual:portugueseLayouts[0]], "English 1x1 did not restore in Portuguese");
    [layoutViewer restoreLayout:popup settings:nil];
    CHECK(popup.selectedItem != nil && popup.selectedItem.tag == 1, "missing settings did not keep a safe default");
    puts("PASS: production print layout restoration uses real AppKit popup and localized XIB titles, preserves grid orientation across English/Portuguese, migrates legacy titles and safely defaults invalid settings");

    NSFileManager *manager = NSFileManager.defaultManager;
    Viewer *viewer = [[Viewer alloc] init];
    NSString *patient = @"SYNTHETIC^PRINT384";
    NSString *identifier = @"LOCAL-PRINT-384";

    // A job's spool is its own, private, and never a fixed path.
    CHECK([viewer preparePrintSpoolDirectory], "the spool directory could not be prepared");
    NSString *first = [[viewer spool] copy];
    CHECK(first.length > 0, "no spool directory was remembered");
    CHECK([HorosPrintSelection isSpoolDirectory:first], "the spool is not one HorosPrintSelection owns");
    CHECK(![first isEqualToString:@"/tmp/print"], "the fixed path is back");
    CHECK([first hasPrefix:NSTemporaryDirectory()], "the spool is outside the per-user temporary directory");
    BOOL isDirectory = NO;
    CHECK([manager fileExistsAtPath:first isDirectory:&isDirectory] && isDirectory, "the spool was not created");
    NSNumber *mode = [manager attributesOfItemAtPath:first error:NULL][NSFilePosixPermissions];
    CHECK(mode.unsignedShortValue == 0700, "the spool is readable by others: %o", mode.unsignedShortValue);

    // Preparing again takes the previous one away: one job, one spool.
    CHECK([viewer preparePrintSpoolDirectory], "a second job could not be prepared");
    NSString *second = [[viewer spool] copy];
    CHECK(![second isEqualToString:first], "two jobs shared a spool directory");
    CHECK(![manager fileExistsAtPath:first], "the previous job's pages survived");

    // A written page is a real file, in order, named by index alone.
    NSMutableArray *files = [NSMutableArray array];
    NSImage *frame = SyntheticFrame();
    for (int i = 0; i < 10; i++)
        CHECK([viewer writePrintPage:frame index:i into:files], "page %d was not written", i);
    CHECK(files.count == 10, "expected ten pages, got %lu", (unsigned long)files.count);
    CHECK([NSSet setWithArray:files].count == 10, "a page path was repeated");
    for (int i = 0; i < 10; i++) {
        NSString *path = files[i];
        CHECK([manager fileExistsAtPath:path], "page %d has a path but no file", i);
        NSString *name = path.lastPathComponent;
        CHECK([name isEqualToString:[HorosPrintSelection viewerPageTemporaryNameWithIndex:i]],
              "page %d is not named by the shared policy: %s", i, name.UTF8String);
        CHECK(![HorosPrintSelection temporaryNameLeaksIdentifiers:name patientName:patient patientID:identifier],
              "the temporary name carries an identifier: %s", name.UTF8String);
        NSImage *back = [[NSImage alloc] initWithContentsOfFile:path];
        CHECK(back != nil && back.size.width == 8 && back.size.height == 8,
              "page %d is not a readable image", i);
    }
    // Order is the order of capture, which is the order printView draws.
    for (int i = 1; i < 10; i++)
        CHECK([files[i - 1] compare:files[i]] == NSOrderedAscending, "page order is not the capture order");

    // A page that cannot be written is not a page in the job.
    NSUInteger before = files.count;
    CHECK([manager setAttributes:@{NSFilePosixPermissions: @(0500)} ofItemAtPath:second error:NULL],
          "could not make the spool read-only");
    CHECK(![viewer writePrintPage:frame index:99 into:files], "an unwritable spool reported success");
    CHECK(files.count == before, "a page with no file was added to the job");
    CHECK([manager setAttributes:@{NSFilePosixPermissions: @(0700)} ofItemAtPath:second error:NULL], "restore");

    // An image with nothing in it is not a page either.
    NSImage *empty = [[NSImage alloc] initWithSize:NSZeroSize];
    CHECK(![viewer writePrintPage:empty index:100 into:files], "an empty capture reported success");
    CHECK(files.count == before, "an empty capture was added to the job");

    // The pages go when the job goes, and going twice is not a failure.
    [viewer discardPrintSpoolDirectory];
    CHECK(![manager fileExistsAtPath:second], "the spool survived the job");
    for (NSString *path in files)
        CHECK(![manager fileExistsAtPath:path], "a page survived the job");
    [viewer discardPrintSpoolDirectory];
    CHECK([viewer spool] == nil, "the discarded spool is still remembered");

    // With no spool there is no page, and no crash.
    CHECK(![viewer writePrintPage:frame index:0 into:files], "a page was written without a spool");

    puts("PASS: the viewer spools each job privately at 0700, names pages by index, refuses a page it "
         "could not write, and takes the pages away with the job");
    return 0;
} }
'''

def layout_items(locale):
    tree = ET.parse(root / 'Horos/Resources' / f'{locale}.lproj/Viewer.xib')
    return tree.findall('.//popUpButton[@id="1847"]/popUpButtonCell/menu/items/menuItem')

english = layout_items('en')
portuguese = layout_items('pt-BR')
assert len(english) == len(portuguese) and len(english) > 6
assert [item.get('tag') for item in english] == [item.get('tag') for item in portuguese]
def objc_array(values):
    return '@[' + ', '.join('@' + json.dumps(value, ensure_ascii=False) for value in values) + ']'
DRIVER = DRIVER.replace('ENGLISH_LAYOUTS', objc_array([item.get('title') for item in english]))
DRIVER = DRIVER.replace('PORTUGUESE_LAYOUTS', objc_array([item.get('title') for item in portuguese]))
DRIVER = DRIVER.replace('LAYOUT_TAGS', objc_array([item.get('tag') for item in english]))

swift = root / 'Horos/Sources/PrintSelection.swift'
with tempfile.TemporaryDirectory(prefix='horos-print-viewer-spool-') as folder:
    path = Path(folder)
    (path / 'Check.m').write_text(DRIVER, encoding='utf-8')
    (path / 'Viewer.swift').write_text(EXTENSION, encoding='utf-8')
    build = subprocess.run(['xcrun', 'swiftc', '-emit-library', '-emit-objc-header',
                            '-emit-objc-header-path', str(path / 'Horos-Swift.h'),
                            '-module-name', 'Horos', str(swift), str(path / 'Viewer.swift'),
                            '-o', str(path / 'libHoros.dylib')], capture_output=True, text=True)
    if build.returncode:
        failures.append('the print policy or the viewer spool methods do not build: %s' % build.stderr.strip()[-900:])
    else:
        compiled = subprocess.run(['xcrun', 'clang', '-I', str(path), '-L', str(path),
                                   '-lHoros', '-Wl,-rpath,' + str(path), '-framework', 'Cocoa',
                                   str(path / 'Check.m'), '-o', str(path / 'check')],
                                  capture_output=True, text=True)
        if compiled.returncode:
            failures.append('the viewer spool methods do not compile: %s' % compiled.stderr.strip()[-900:])
        else:
            run = subprocess.run([str(path / 'check')], capture_output=True, text=True)
            print(run.stdout.strip())
            if run.returncode:
                failures.append('the viewer spool does not hold: %s' % (run.stderr.strip()[-500:] or 'no output'))

# The caller has to be the one that changed, not only the policy.
if '/tmp/print"' in viewer or '/tmp/print"' in swift_viewer:
    failures.append('the fixed /tmp/print path is still used')
end_print = swift_viewer[swift_viewer.index('    @objc(endPrint:)'):swift_viewer.index('    @objc(printSlider:)')]
if 'self.preparePrintSpoolDirectory() == false' not in end_print:
    failures.append('a spool directory that cannot be made must stop the print, not be ignored')
if 'self.writePrintPage(im, index: i, into: files) == false' not in end_print:
    failures.append('the capture loop must write through the checked writer')
if '!preparationCancelled && !preparationFailed' not in end_print:
    failures.append('a failed preparation must not submit the prefix it captured')
if 'printOperation.jobTitle = "IsiX DICOM Viewer"' not in end_print:
    failures.append('the job title must be a constant: the window title carries the patient name')
if 'presentPrintPreparationFailure' not in end_print:
    failures.append('a failed preparation must say so')
did_run = swift_viewer[swift_viewer.index('    @objc(printOperationDidRun:success:contextInfo:)'):start]
if 'discardPrintSpoolDirectory' not in did_run:
    failures.append('the finished job must remove its own spool directory')
if 'success == false' not in did_run:
    failures.append('a cancelled or failed operation must not be recorded as a success')
if 'discardPrintSpoolDirectory' not in viewer[viewer.index('- (void) dealloc\n{\n    [ViewerController clearFrontMost2DViewerCache];'):][:2000]:
    failures.append('a viewer closed with a spool still around must take it with it')
printing = '\n'.join(line for line in (end_print + did_run + methods).splitlines()
                      if not line.lstrip().startswith('//'))
if '@"/tmp' in printing or '"/tmp' in printing:
    failures.append('the printing path names a fixed temporary location again')

if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)
print('PASS: the viewer print path asks for its own spool, checks every page it writes, refuses an '
      'incomplete job and removes the pages with the job')
