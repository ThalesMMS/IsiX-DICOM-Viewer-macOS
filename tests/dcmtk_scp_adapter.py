"""Compile a driver with the listener's DCMTK adapter.

The listener reaches DCMTK only through Horos/Sources/Adapters/DCMTK:
IsiXDCMTKQueryRetrieveSCP (the port, TLS, the associations) and
IsiXDCMTKSCPDatabase (the database handle and the C-STORE), with the error,
dataset and C-MOVE files they use. `build(folder, driver)` compiles them, as
the application does (ARC, and strict warnings), with `driver` - an
Objective-C++ file that implements the host and database protocols - against
the DCMTK, OpenSSL and OpenJPEG the Debug build installed, and returns the
executable. Without that build it exits 2, which tools/run-tests.py reports as
skipped.
"""
import subprocess
import sys
from pathlib import Path

from dcmtk_build import BUILD, ROOT, dcmtk_flags

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SOURCES = [ADAPTERS / name for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKDataset.mm', 'IsiXDCMTKQueryRetrieveSCP.mm',
                                        'IsiXDCMTKSCPDatabase.mm')]
# Compiled without ARC, as in the application; its representation helpers need
# the application's JPEG 2000 codec.
MRC_SOURCES = [ADAPTERS / 'IsiXDCMTKMoveContext.mm']
CODEC = ADAPTERS / 'HorosJPEG2000Codec.cpp'
OPENSSL = BUILD / 'OpenSSL.build/Install'

# What the application's Swift answers for the headers the adapter includes.
SWIFT_HEADER = r'''
#import <Foundation/Foundation.h>
@interface HorosDIMSEPolicy : NSObject
+ (NSInteger)rankAccepted:(NSString *)accepted original:(NSString *)original;
+ (BOOL)requiresConversionAccepted:(NSString *)accepted original:(NSString *)original;
@end
'''

STUBS = r'''
#import <Foundation/Foundation.h>
#include <cstddef>
#import "Horos-Swift.h"
extern "C" BOOL HorosDIMSEAssociationPDUIsValid(const unsigned char *, ptrdiff_t) noexcept { return YES; }
@implementation HorosDIMSEPolicy
+ (NSInteger)rankAccepted:(NSString *)accepted original:(NSString *)original { return 0; }
+ (BOOL)requiresConversionAccepted:(NSString *)accepted original:(NSString *)original { return NO; }
@end
'''


def build(folder, driver):
    folder = Path(folder)
    flags = dcmtk_flags('dcmqrdb', 'dcmnet', 'dcmtls', 'dcmjpls', 'dcmtkcharls', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16',
                        'dcmimage', 'dcmimgle')
    archives = [OPENSSL / 'lib/libssl.a', OPENSSL / 'lib/libcrypto.a', BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a']
    missing = [path for path in archives if not path.is_file()]
    if missing:
        print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(missing[0]))
        raise SystemExit(2)
    openjpeg = ['-I' + str(BUILD / 'OpenJPEG.build/Install/include'),
                *['-I' + str(path) for path in sorted((BUILD / 'OpenJPEG.build/Install/include').glob('openjpeg-*'))]]
    (folder / 'Horos-Swift.h').write_text(SWIFT_HEADER)
    (folder / 'stubs.mm').write_text(STUBS)
    (folder / 'driver.mm').write_text(driver)
    includes = ['-I' + str(folder), '-I' + str(ADAPTERS), '-I' + str(OPENSSL / 'include'), *openjpeg]
    objects = []
    for source in MRC_SOURCES + [CODEC, folder / 'stubs.mm', folder / 'driver.mm']:
        language = 'c++' if source.suffix == '.cpp' else 'objective-c++'
        obj = folder / (source.stem + '.o')
        arc = ['-fno-objc-arc'] if source in MRC_SOURCES else (['-fobjc-arc'] if language != 'c++' else [])
        built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-w', *includes, *arc, '-x', language, '-c', str(source),
                                *flags[:2], '-o', str(obj)], capture_output=True, text=True)
        if built.returncode:
            print(built.stderr[-4000:])
            print('FAIL: %s does not compile against the build\'s DCMTK' % source.name)
            sys.exit(1)
        objects.append(str(obj))
    executable = folder / 'check'
    # The adapter's own files: as the application compiles them, and without a warning.
    linked = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror', '-Wno-unused-parameter',
                             *includes, *map(str, SOURCES), *objects, *flags, *map(str, archives),
                             '-framework', 'Foundation', '-framework', 'Security', '-o', str(executable)],
                            capture_output=True, text=True)
    if linked.returncode:
        print(linked.stderr[-4000:])
        print('FAIL: the listener\'s adapter does not compile or link against the build\'s DCMTK')
        sys.exit(1)
    return executable


def openssl():
    """The openssl the build installed, or the system's."""
    return str(OPENSSL / 'bin/openssl') if (OPENSSL / 'bin/openssl').exists() else 'openssl'
