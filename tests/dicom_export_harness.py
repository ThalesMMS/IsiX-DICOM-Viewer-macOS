"""DICOMExport as the app compiles it, with a driver, for a test.

DICOMExport.swift and DICOMExport+Dataset.swift are compiled as they are
written, with the IsiXDICOMFile module and the DCMTK adapter they call
(IsiXDCMTKFile, against the DCMTK of the Debug build: exit 2 without it), and
stand-ins for what the write only consults of the application. Every source a
driver names is taken as DICOM, so the export is written over its attributes.

    check = build(folder, DRIVER)       # DRIVER: the Swift of main.swift
    output = driver(check, 'mode', path, ...)

`TOOLS` is the bin folder of that DCMTK and `DICTIONARY` its dicom.dic.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402
import process_graph_stand_in  # noqa: E402
import harness_defaults  # noqa: E402  the harness's preferences stay in its own process
import objc_exception_guards  # noqa: E402
from dcmtk_build import BUILD, INSTALL, ROOT, dcmtk_flags  # noqa: E402

EXPORT = ['Horos/Sources/DICOMExport.swift', 'Horos/Sources/DICOMExport+Dataset.swift']
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
TOOLS = INSTALL / 'bin'
# IsiXDCMTKFile changes representation through the host's codecs, JPEG 2000 included.
OPENJPEG = BUILD / 'OpenJPEG.build/Install'


def requirements(*tools):
    """The DCMTK flags and its dictionary; exit 2 when the build, or one of
    `tools` of its bin folder, is not there."""
    flags = dcmtk_flags('dcmnet', 'dcmjpls', 'dcmtkcharls', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16', 'dcmimage', 'dcmimgle')
    dictionaries = sorted((INSTALL / 'share').glob('dcmtk*/dicom.dic'))
    missing = [path for path in [OPENJPEG / 'lib/libopenjp2.a', *[TOOLS / tool for tool in tools]] if not path.is_file()]
    if not dictionaries and not missing:
        missing = [INSTALL / 'share/dcmtk/dicom.dic']
    if missing:
        print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(missing[0]))
        raise SystemExit(2)
    return flags, dictionaries[0]


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

# What the write consults of the application, standing in: every source here
# is DICOM, there is no browser, nothing is decompressed.
STUBS = r'''
import Foundation
import IsiXContracts
import IsiXDICOMFile

final class DicomFile {
    static func isDICOMFile(_ path: String) -> Bool { true }
    init?(_ path: String) { return nil }
    func element(forKey key: String) -> Any? { nil }
}

final class DicomDatabase {
    func uniquePathForNewDataFile(withExtension ext: String) -> String? { nil }
}

struct NoConversion: DatabaseFileConverting {
    func convertNow(_ paths: [String], mode: FileConversionMode, into destination: String?) -> Bool { true }
    func convertInChunks(_ paths: [String], mode: FileConversionMode, into destination: String?) throws {}
    func convertLater(_ paths: [String], mode: FileConversionMode, into destination: String?) {}
    var isConverting: Bool { false }
}

struct DatabaseIngest {
    static let process = DatabaseIngest()
    var browserDatabase: DicomDatabase? { nil }
    func fileConverting(of database: DicomDatabase?) -> any DatabaseFileConverting { NoConversion() }
}

extension FileManager {
    func tmpDirPath() -> String { NSTemporaryDirectory() }
}

extension NSString {
    static func encoding(forDICOMCharacterSet value: String) -> UInt {
        DICOMCharacterSet.encoding(forDICOMCharacterSet: value)
    }
}

'''


def compile_step(command, what):
    built = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: %s does not compile' % what)
        raise SystemExit(1)


def build(work, driver_source):
    """The executable of the exporter with `driver_source` as its main.swift."""
    flags, _ = requirements()
    openjpeg = ['-I' + str(OPENJPEG / 'include'), *['-I' + str(path) for path in sorted((OPENJPEG / 'include').glob('openjpeg-*'))]]
    for path in EXPORT:
        (work / Path(path).name).write_text((ROOT / path).read_text(encoding='utf-8'), encoding='utf-8')
    (work / 'bridge.h').write_text(BRIDGE)
    (work / 'plugin.m').write_text(PLUGIN)
    # The exporter's guard is the module's own member of HorosObjCException.
    (work / 'stubs.swift').write_text(STUBS + objc_exception_guards.source(log=False).replace('import Foundation\n', '', 1))
    (work / 'main.swift').write_text(harness_defaults.SWIFT + driver_source)
    modules = work / 'modules'
    module_flags = isix_modules.module_flags('IsiXDICOMFile', modules) + isix_modules.module_flags('IsiXContracts', modules)
    # The exporter reads its choice of writer through the process graph.
    module_flags += process_graph_stand_in.swift_flags(modules)
    includes = ['-I' + str(ROOT / 'Horos/Sources'), '-I' + str(ADAPTERS)]
    objects = []
    for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKFile.mm'):
        obj = work / (name + '.o')
        compile_step(['xcrun', 'clang++', '-std=gnu++17', '-w', '-mmacosx-version-min=15.0', '-g', '-fobjc-arc',
                      '-x', 'objective-c++', *includes, *flags[:2], '-c', str(ADAPTERS / name), '-o', str(obj)], name)
        objects.append(str(obj))
    codec = work / 'HorosJPEG2000Codec.o'
    compile_step(['xcrun', 'clang++', '-std=gnu++17', '-w', '-mmacosx-version-min=15.0', '-x', 'c++', *includes,
                  *openjpeg, *flags[:2], '-c', str(ADAPTERS / 'HorosJPEG2000Codec.cpp'), '-o', str(codec)],
                 'HorosJPEG2000Codec.cpp')
    objects.append(str(codec))
    for path in (ROOT / 'Horos/Sources/HorosObjCException.m', work / 'plugin.m'):
        obj = work / (path.name + '.o')
        compile_step(['xcrun', 'clang', '-fobjc-arc', '-g', '-mmacosx-version-min=15.0', *includes, '-c', str(path),
                      '-o', str(obj)], path.name)
        objects.append(str(obj))
    swift = [str(work / Path(path).name) for path in EXPORT] + [str(work / 'stubs.swift'), str(work / 'main.swift')]
    compile_step(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', '-g', '-Onone',
                  '-import-objc-header', str(work / 'bridge.h'), *[part for flag in includes for part in ('-Xcc', flag)],
                  *module_flags, *swift, *objects, *flags[2:], str(OPENJPEG / 'lib/libopenjp2.a'), '-Xlinker', '-lc++',
                  '-framework', 'Cocoa', '-o', str(work / 'check')], 'DICOMExport with its driver')
    return work / 'check'


def driver(check, *arguments):
    try:
        run = subprocess.run([str(check), *map(str, arguments)], capture_output=True, text=True, timeout=60,
                             env={'PATH': '/usr/bin:/bin'})
    except subprocess.TimeoutExpired:
        print('FAIL: the driver did not end within 60 s')
        raise SystemExit(1)
    if run.returncode:
        print(run.stdout + run.stderr[-2000:])
        print('FAIL: the driver exited with %d' % run.returncode)
        raise SystemExit(1)
    return run.stdout
