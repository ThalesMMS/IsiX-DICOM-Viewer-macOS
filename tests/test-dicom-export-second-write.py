#!/usr/bin/env python3
"""A DICOMExport that made 16-bit pixels square writes them again, intact.

A viewer keeps one DICOMExport for the images of a series. When the pixel
spacing is not square, the first write resamples 16-bit pixels to square ones
and from then on the exporter's image is square: its height and its spacing
say so, and its pixels are the resampled ones. That buffer was freed at the
end of the first write while the exporter still pointed at it, so the second
write copied freed memory into its Pixel Data (or crashed).

DICOMExport.swift and DICOMExport+Dataset.swift are compiled here as they are
written, under Address Sanitizer, with the IsiXDICOMFile module and the DCMTK
adapter they call (IsiXDCMTKFile, against the DCMTK of the Debug build: exit 2
without it), and stand-ins for the application classes the write only consults
(DicomFile, the browser's database, the decompression). The driver gives one
exporter 16-bit pixels of 8 x 6 at 0.5 x 0.75 mm, writes two files, reads both
back through DCMTK and requires the same square 8 x 8 image in each, numbered
1 and 2, with the pixels it was given resampled; then sets new pixels on the
same exporter and writes a third file of them. Address Sanitizer stops the
program on any read of freed memory.

`<git revision>` as an optional argument reads the two Swift files from that
revision, the negative control.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402

revision = sys.argv[1] if len(sys.argv) > 1 else None
EXPORT = ['Horos/Sources/DICOMExport.swift', 'Horos/Sources/DICOMExport+Dataset.swift']
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'

flags = dcmtk_flags('dcmnet', 'dcmjpls', 'dcmtkcharls', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16', 'dcmimage', 'dcmimgle')
# IsiXDCMTKFile changes representation through the host's codecs, JPEG 2000 included.
OPENJPEG = BUILD / 'OpenJPEG.build/Install'
if not (OPENJPEG / 'lib/libopenjp2.a').is_file():
    print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(OPENJPEG / 'lib/libopenjp2.a'))
    raise SystemExit(2)
openjpeg = ['-I' + str(OPENJPEG / 'include'), *['-I' + str(path) for path in sorted((OPENJPEG / 'include').glob('openjpeg-*'))]]


def source(path):
    if revision:
        return subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, path)], check=True,
                              capture_output=True).stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


BRIDGE = r'''
#import <Cocoa/Cocoa.h>
#import "DICOMExport.h"
#import "IsiXDCMTKFile.h"
#import "HorosObjCException.h"
@interface DCMExportPlugin : NSObject
@end
'''

PLUGIN = r'''
#import <Foundation/Foundation.h>
@interface DCMExportPlugin : NSObject
@end
@implementation DCMExportPlugin
@end
'''

# What the write consults of the application, standing in: no source file is
# DICOM, there is no browser, nothing is decompressed.
STUBS = r'''
import Foundation
import IsiXDICOMFile

final class DicomFile {
    static func isDICOMFile(_ path: String) -> Bool { false }
    init?(_ path: String) { return nil }
    func element(forKey key: String) -> Any? { nil }
}

final class DicomDatabase {
    func uniquePathForNewDataFile(withExtension ext: String) -> String? { nil }
    static func decompressDicomFiles(atPaths paths: [String]) {}
}

final class BrowserController {
    static func currentBrowser() -> BrowserController? { nil }
    var database: DicomDatabase? { nil }
}

extension FileManager {
    func tmpDirPath() -> String { NSTemporaryDirectory() }
}

extension NSString {
    static func encoding(forDICOMCharacterSet value: String) -> UInt {
        DICOMCharacterSet.encoding(forDICOMCharacterSet: value)
    }
}

extension HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? {
        do {
            try perform(body)
            return nil
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
    }
}
'''

DRIVER = r'''
import Foundation

func fail(_ reason: String) -> Never { print("FAIL: " + reason); exit(1) }

struct Written { let rows: UInt16; let columns: UInt16; let instance: String; let pixels: [UInt16] }

func read(_ path: String) -> Written {
    let file = IsiXDCMTKFile()
    guard (try? file.read(fileAtPath: path)) != nil else { fail("\(path) cannot be read back") }
    file.loadAllDataIntoMemory()
    var rows: UInt16 = 0, columns: UInt16 = 0
    guard file.dataset.getUInt16(&rows, forTag: 0x0028_0010, index: 0),
          file.dataset.getUInt16(&columns, forTag: 0x0028_0011, index: 0),
          let data = file.dataset.bytes(forTag: 0x7fe0_0010) else { fail("\(path) has no image") }
    let instance = file.dataset.string(forTag: 0x0020_0013).map { String(cString: $0) } ?? ""
    let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    return Written(rows: rows, columns: columns, instance: instance.trimmingCharacters(in: .whitespaces), pixels: pixels)
}

let folder = CommandLine.arguments[1]
UserDefaults.standard.set(true, forKey: "useDCMTKForDicomExport")

let width = 8, height = 6
let given = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
for y in 0..<height { for x in 0..<width { given[y * width + x] = UInt16(100 * y + 10 * x + 5) } }

let exporter = DICOMExport()
_ = exporter.setPixelData(UnsafeMutableRawPointer(given).assumingMemoryBound(to: UInt8.self), samplesPerPixel: 1,
                          bitsPerSample: 16, width: width, height: height)
exporter.setPixelSpacing(0.5, 0.75)
exporter.setSeriesDescription("second write")
guard exporter.writeDCMFile(folder + "/first.dcm") != nil else { fail("the first write wrote nothing") }
// The caller's pixels change after the first write: the exporter's image is
// the square one it made of them, not the caller's buffer.
for i in 0..<(width * height) { given[i] = 9999 }
guard exporter.writeDCMFile(folder + "/second.dcm") != nil else { fail("the second write wrote nothing") }

let first = read(folder + "/first.dcm"), second = read(folder + "/second.dcm")
if first.rows != 8 || first.columns != 8 { fail("the first image is \(first.columns) x \(first.rows), not 8 x 8") }
if second.rows != first.rows || second.columns != first.columns {
    fail("the second image is \(second.columns) x \(second.rows), the first \(first.columns) x \(first.rows)")
}
if first.pixels.count != 64 || second.pixels != first.pixels {
    fail("the second image's pixels are not the first's: \(Array(second.pixels.prefix(16))) where \(Array(first.pixels.prefix(16)))")
}
// Resampled top to bottom only: each row still rises by 10 from one column to the next.
let rowsRise = (0..<8).allSatisfy { y in (0..<8).allSatisfy { x in
    Int(first.pixels[y * 8 + x]) - Int(first.pixels[y * 8]) == 10 * x } }
if !rowsRise || first.pixels.contains(9999) {
    fail("the square image is not the given pixels resampled: \(Array(first.pixels.prefix(16)))")
}
if first.instance != "1" || second.instance != "2" {
    fail("the images are numbered \(first.instance) and \(second.instance), not 1 and 2")
}

// New pixels on the same exporter: the square ones it owned are let go, and
// the new image, already square in its spacing, is written as it is.
let next = UnsafeMutablePointer<UInt16>.allocate(capacity: 8 * 8)
for i in 0..<64 { next[i] = UInt16(3 * i + 1) }
_ = exporter.setPixelData(UnsafeMutableRawPointer(next).assumingMemoryBound(to: UInt8.self), samplesPerPixel: 1,
                          bitsPerSample: 16, width: 8, height: 8)
guard exporter.writeDCMFile(folder + "/third.dcm") != nil else { fail("the third write wrote nothing") }
let third = read(folder + "/third.dcm")
if third.pixels != (0..<64).map({ UInt16(3 * $0 + 1) }) { fail("the third image is not the new pixels") }
given.deallocate()
next.deallocate()
print("PASS: two writes of one exporter after squaring 16-bit pixels write the same square image, "
      + "and new pixels after them are written as given (Address Sanitizer on)")
'''

with tempfile.TemporaryDirectory(prefix='isix-export-second-write-') as directory:
    work = Path(directory)
    for path in EXPORT:
        (work / Path(path).name).write_text(source(path), encoding='utf-8')
    (work / 'bridge.h').write_text(BRIDGE)
    (work / 'plugin.m').write_text(PLUGIN)
    (work / 'stubs.swift').write_text(STUBS)
    (work / 'main.swift').write_text(DRIVER)
    (work / 'files').mkdir()
    modules = work / 'modules'
    module_flags = isix_modules.module_flags('IsiXDICOMFile', modules)
    includes = ['-I' + str(ROOT / 'Horos/Sources'), '-I' + str(ADAPTERS)]
    objects = []

    def compile_step(command, what):
        built = subprocess.run(command, capture_output=True, text=True, timeout=600)
        if built.returncode:
            print(built.stderr[-4000:])
            print('FAIL: %s does not compile' % what)
            raise SystemExit(1)

    for name, language, arc in (('IsiXDCMTKError.mm', 'objective-c++', True), ('IsiXDCMTKFile.mm', 'objective-c++', True)):
        obj = work / (name + '.o')
        compile_step(['xcrun', 'clang++', '-std=gnu++17', '-w', '-mmacosx-version-min=15.0', '-fsanitize=address', '-g',
                      '-fobjc-arc', '-x', language, *includes, *flags[:2], '-c', str(ADAPTERS / name), '-o', str(obj)],
                     name)
        objects.append(str(obj))
    codec = work / 'HorosJPEG2000Codec.o'
    compile_step(['xcrun', 'clang++', '-std=gnu++17', '-w', '-mmacosx-version-min=15.0', '-x', 'c++', *includes,
                  *openjpeg, *flags[:2], '-c', str(ADAPTERS / 'HorosJPEG2000Codec.cpp'), '-o', str(codec)],
                 'HorosJPEG2000Codec.cpp')
    objects.append(str(codec))
    for path in (ROOT / 'Horos/Sources/HorosObjCException.m', work / 'plugin.m'):
        obj = work / (path.name + '.o')
        compile_step(['xcrun', 'clang', '-fobjc-arc', '-fsanitize=address', '-g', '-mmacosx-version-min=15.0',
                      *includes, '-c', str(path), '-o', str(obj)], path.name)
        objects.append(str(obj))
    swift = [str(work / Path(path).name) for path in EXPORT] + [str(work / 'stubs.swift'), str(work / 'main.swift')]
    compile_step(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', '-sanitize=address', '-g', '-Onone',
                  '-import-objc-header', str(work / 'bridge.h'), *[part for flag in includes for part in ('-Xcc', flag)],
                  *module_flags, *swift, *objects, *flags[2:], str(OPENJPEG / 'lib/libopenjp2.a'), '-Xlinker', '-lc++', '-framework', 'Cocoa',
                  '-o', str(work / 'check')], 'DICOMExport with its driver')
    try:
        run = subprocess.run([str(work / 'check'), str(work / 'files')], capture_output=True, text=True, timeout=60,
                             env={'ASAN_OPTIONS': 'detect_leaks=0:abort_on_error=0', 'PATH': '/usr/bin:/bin'})
    except subprocess.TimeoutExpired:
        print('FAIL: the driver did not end within 60 s')
        raise SystemExit(1)
    print(run.stdout, end='')
    if run.returncode:
        report = [line for line in run.stderr.splitlines() if 'ERROR: AddressSanitizer' in line or 'SUMMARY' in line]
        print('\n'.join(report) or run.stderr[-2000:])
        print('FAIL: the driver exited with %d' % run.returncode)
        raise SystemExit(1)
