#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX reaches the instance variables of the
host's classes now implemented in Swift.

The former SDK declared instance variables that plugins read and write
directly: PluginFilter's viewerController, which almost every image filter
reads, and the _height, _width, _fImage, ... of PluginFileFormatDecoder, which
a file-format plugin fills in its -checkLoadAtPath:. Such a plugin's binary
finds each one's offset through the _OBJC_IVAR_$_Class.ivar symbol, by flat
lookup in the application. The classes are now Swift (@objc @implementation)
and keep these variables as stored properties of the same names, whose offsets
Swift stores in symbols of its own: the application target links with
the linker response file Horos/Scripts/Horos/legacy-plugin-ivar-aliases.rsp,
whose -alias lines export each one under the Objective-C name too and whose -u
lines keep those names through dead stripping (Release strips them otherwise).

The shipped PluginFilter.swift, PluginFileFormatDecoder.swift, their headers
and the response file are compiled and linked here, dead stripped, into a host executable, in a
module named Horos as in the application (the Swift symbols carry the module's
name), with a stand-in ViewerController. A bundle built as the former plugins
were (Objective-C without ARC, -undefined dynamic_lookup), whose classes
subclass both as the former SDK declared them, instance variables included, is
loaded by the host, which checks that:

- the bundle loads: every _OBJC_IVAR_$_ symbol it needs is found;
- after -prepareFilter:, the subclass's direct read of viewerController answers
  the viewer, and its direct write is what the property answers;
- viewerController holds its viewer without owning it, as the former SDK's
  variable did: replacing a viewer the subclass stored with no retain does not
  release it, and the filter does not keep a viewer alive;
- a decoder starts with _isRGB YES, as the former -init set it;
- after the subclass's -checkLoadAtPath: stores the values directly, the
  inherited -height, -width, -rowBytes, -windowWidth, -windowLevel, -isRGB,
  -patientName ... -seriesDescription answer them, and Swift reads the same
  through the stored properties;
- the decoder, with the objects the subclass stored retained, is released
  without a crash.

A line of the response file whose Swift symbol is no longer defined (a property
renamed, retyped or moved) fails the link.

    python3 tests/test-legacy-plugin-instance-variables.py
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ALIASES = ROOT / 'Horos/Scripts/Horos/legacy-plugin-ivar-aliases.rsp'
SOURCES = {'PluginFilter': ROOT / 'Horos/Sources/PluginFilter.swift',
           'PluginFileFormatDecoder': ROOT / 'Horos/Sources/PluginFileFormatDecoder.swift'}
HEADERS = {'PluginFilter': ROOT / 'Horos/Sources/PluginFilter.h',
           'PluginFileFormatDecoder': ROOT / 'Horos/Sources/PluginFileFormatDecoder.h'}

interfaces = []
for name, header in HEADERS.items():
    found = re.search(r'^@interface ' + name + r' : NSObject\b.*?^@end\b', header.read_bytes().decode('latin1'), re.S | re.M)
    if found is None:
        print(f'FAIL: {header.relative_to(ROOT)} does not declare @interface {name} : NSObject')
        raise SystemExit(1)
    interfaces.append(found.group(0))
host_header = ('#import <Cocoa/Cocoa.h>\n#import <CoreData/CoreData.h>\n@class ViewerController;\n'
               + '\n'.join(interfaces) + '\n')

# What the application gives PluginFilter.swift: the open viewers and a viewer's copy.
stand_ins = r'''
import Foundation

@objc(ViewerController) public final class ViewerController: NSObject {
    nonisolated(unsafe) public static var released = 0
    deinit { ViewerController.released += 1 }
    @objc(getDisplayed2DViewers) public class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray() }
    @MainActor @objc(horosDuplicatedViewerWindow) public func horosDuplicatedViewerWindow() -> ViewerController? { nil }
}
'''

host = r'''
import Foundation

var failed = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: " + what); failed += 1 }
}
func send(_ target: AnyObject, _ name: String, _ argument: AnyObject?) -> AnyObject? {
    target.perform(NSSelectorFromString(name), with: argument)?.takeUnretainedValue()
}
func sendLong(_ target: AnyObject, _ name: String, _ argument: AnyObject?) -> Int {
    let selector = NSSelectorFromString(name)
    typealias Method = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    return unsafeBitCast(target.method(for: selector), to: Method.self)(target, selector, argument)
}

let bundle = Bundle(path: CommandLine.arguments[1])!
do { try bundle.loadAndReturnError() } catch { print("FAIL: the bundle does not load: \(error)"); exit(1) }

// PluginFilter.viewerController
guard let filterClass = bundle.classNamed("LegacyIvarFilter") as? PluginFilter.Type, let filter = filterClass.filter() else {
    print("FAIL: no LegacyIvarFilter"); exit(1)
}
let viewer = ViewerController()
check(sendLong(filter, "prepareFilter:", viewer) == 0, "-prepareFilter: answers 0")
check(send(filter, "readViewer", nil) === viewer, "the subclass reads the viewer -prepareFilter: kept in its viewerController instance variable")
let other = ViewerController()
_ = send(filter, "writeViewer:", other)
check(filter.viewerController === other, "what the subclass stores in viewerController is what the property answers")

// The variable holds its viewer without owning it, as the former SDK's did: a
// plugin stores a viewer there with no retain, and what replaces it must not
// release what the plugin never retained.
autoreleasepool {
    var stored: ViewerController? = ViewerController()
    _ = send(filter, "writeViewer:", stored)
    check(sendLong(filter, "prepareFilter:", nil) == 0 && filter.viewerController == nil, "-prepareFilter: with no viewer empties the variable")
    if ViewerController.released != 0 {
        print("FAIL: replacing a viewer the subclass stored without a retain released it"); exit(1)
    }
    stored = nil
}
check(ViewerController.released == 1, "the viewer the subclass stored is released once, by its owner: \(ViewerController.released)")
// Nor does the filter keep alive the viewer -prepareFilter: gave it.
autoreleasepool {
    var kept: ViewerController? = ViewerController()
    weak let watched = kept
    _ = sendLong(filter, "prepareFilter:", kept)
    kept = nil
    check(watched == nil, "the filter does not own the viewer -prepareFilter: gave it")
}
_ = sendLong(filter, "prepareFilter:", nil)

// PluginFileFormatDecoder._height, ...
autoreleasepool {
    guard let decoderClass = bundle.classNamed("LegacyIvarDecoder") as? PluginFileFormatDecoder.Type else {
        print("FAIL: no LegacyIvarDecoder"); exit(1)
    }
    // As DicomFile and DCMPix make it: the principal class, as an NSObject class, sent -init.
    let decoder = (decoderClass as NSObject.Type).init() as! PluginFileFormatDecoder
    check(decoder.isRGB() && decoder._isRGB, "a new decoder is RGB, as the former -init made it")
    check(decoder.height() == nil && decoder.patientName() == nil, "a new decoder answers nil")
    let pixels = decoder.checkLoad(atPath: "/synthetic/image.jpc")
    check(pixels != nil && pixels?[0] == 12.5 && pixels?[5] == -3.0, "-checkLoadAtPath: is the subclass's and answers its pixels")
    check(decoder.height()?.intValue == 3 && decoder.width()?.intValue == 2 && decoder.rowBytes()?.intValue == 8
          && decoder.windowWidth()?.intValue == 400 && decoder.windowLevel()?.intValue == 40,
          "-height, -width, -rowBytes, -windowWidth, -windowLevel answer what the subclass stored")
    check(!decoder.isRGB() && !decoder._isRGB, "-isRGB answers the NO the subclass stored")
    check(decoder.patientName() == "SYNTHETIC^IVAR" && decoder.patientID() == "IVAR-1" && decoder.studyID() == "S1"
          && decoder.seriesID() == "SE1" && decoder.imageID() == "I1" && decoder.studyDescription() == "Study"
          && decoder.seriesDescription() == "Series",
          "-patientName ... -seriesDescription answer what the subclass stored")
    check(decoder._fImage == pixels && decoder._height?.intValue == 3, "Swift reads the same values through the stored properties")
    free(pixels)
    decoder._fImage = nil
}
if failed > 0 { exit(1) }
print("ok")
'''

plugin = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#include <stdlib.h>
// The classes as the former SDK declared them, instance variables included; the
// classes themselves are the host's.
@class ViewerController;
@interface PluginFilter : NSObject
{
    ViewerController *viewerController;
}
+ (PluginFilter *)filter;
- (long)prepareFilter:(ViewerController *)vC;
@end
@interface PluginFileFormatDecoder : NSObject
{
    NSNumber *_height;
    NSNumber *_width;
    float *_fImage;
    NSNumber * _rowBytes;
    NSNumber *_windowWidth;
    NSNumber *_windowLevel;
    BOOL _isRGB;

    NSString *_patientName;
    NSString *_patientID;
    NSString *_studyID;
    NSString *_seriesID;
    NSString *_imageID;
    NSString *_studyDescription;
    NSString *_seriesDescription;
}
- (float *)checkLoadAtPath:(NSString *)path;
@end

@interface LegacyIvarFilter : PluginFilter
@end
@implementation LegacyIvarFilter
- (id)readViewer { return (id)viewerController; }
- (void)writeViewer:(id)viewer { viewerController = viewer; }
@end

@interface LegacyIvarDecoder : PluginFileFormatDecoder
@end
@implementation LegacyIvarDecoder
- (float *)checkLoadAtPath:(NSString *)path
{
    _height = [[NSNumber numberWithInt:3] retain];
    _width = [[NSNumber numberWithInt:2] retain];
    _rowBytes = [[NSNumber numberWithInt:8] retain];
    _windowWidth = [[NSNumber numberWithInt:400] retain];
    _windowLevel = [[NSNumber numberWithInt:40] retain];
    _isRGB = NO;
    _patientName = [@"SYNTHETIC^IVAR" retain];
    _patientID = [@"IVAR-1" retain];
    _studyID = [@"S1" retain];
    _seriesID = [@"SE1" retain];
    _imageID = [@"I1" retain];
    _studyDescription = [@"Study" retain];
    _seriesDescription = [[NSString alloc] initWithFormat:@"%@", @"Series"];
    float *pixels = malloc(6 * sizeof(float));
    for (int i = 0; i < 6; i++) pixels[i] = i == 0 ? 12.5f : -3.0f;
    _fImage = pixels;
    return _fImage;
}
@end
'''


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


with tempfile.TemporaryDirectory(prefix='horos-legacy-ivars-') as temporary:
    work = Path(temporary)
    (work / 'Host.h').write_text(host_header, encoding='latin1')
    for name, source in SOURCES.items():
        (work / source.name).write_bytes(source.read_bytes())
    (work / 'StandIns.swift').write_text(stand_ins)
    (work / 'main.swift').write_text(host)
    (work / 'Legacy.m').write_text(plugin)
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy-ivars', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyIvarFilter'}))
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', '-import-objc-header', str(work / 'Host.h'),
                 *[str(work / s.name) for s in SOURCES.values()], str(work / 'StandIns.swift'), str(work / 'main.swift'),
                 # As the application target passes it, "-Wl,@file": inside -Wl the file reaches ld unexpanded.
                 '-Xlinker', '-dead_strip', '-Xclang-linker', '-Wl,@' + str(ALIASES), '-o', str(work / 'host')])
    if built.returncode != 0:
        print('FAIL: the host does not build with the response file: ' + built.stderr[-3000:])
        raise SystemExit(1)
    built = run(['xcrun', 'clang', '-bundle', '-fno-objc-arc', '-framework', 'Foundation', '-framework', 'CoreData',
                 '-undefined', 'dynamic_lookup', '-mmacosx-version-min=15.0', str(work / 'Legacy.m'),
                 '-o', str(legacy / 'Contents/MacOS/Legacy')])
    if built.returncode != 0:
        print('FAIL: the plugin does not build: ' + built.stderr[-3000:])
        raise SystemExit(1)
    probe = run([str(work / 'host'), str(legacy)], timeout=60)
    if probe.returncode != 0:
        died = f' (signal {-probe.returncode})' if probe.returncode < 0 else ''
        print((probe.stdout + probe.stderr).strip())
        print(f'FAIL: the host ended with status {probe.returncode}{died}')
        raise SystemExit(1)
print('PluginFilter.viewerController and the instance variables of PluginFileFormatDecoder: '
      'a former plugin reads and writes them directly and the host answers the same')
