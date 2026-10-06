"""Compile a test driver against the reader DCMPix uses.

The driver imports "HorosDCMTKObject.h", calls HorosTestRegisterDecoders() at
the start of main (declared by the header this module inserts), and reads files with
+[HorosDCMTKObject objectWithContentsOfFile:], which is DCMTK underneath and the
DCMObject interface on top. It is linked with the built DCM.framework (for the
attribute classes) and the DCMTK and OpenJPEG archives of the same build.

HorosDICOMWriter is compiled in as well, and the encoders registered, so that
DCMObject reading and writing through DCM.framework - which forwards both to
these host classes - works in the driver as it does in the application.
"""
import shutil
import subprocess
from pathlib import Path

from dcmtk_build import BUILD, ROOT, dcmtk_flags

SETUP = r'''
#undef verify
#include "HorosJPEG2000Codec.h"
#include <dcmtk/dcmjpeg/djdecode.h>
#include <dcmtk/dcmjpeg/djencode.h>
#include <dcmtk/dcmjpls/djdecode.h>
#include <dcmtk/dcmjpls/djencode.h>
#include <dcmtk/dcmdata/dcrledrg.h>
#include <dcmtk/dcmdata/dcrleerg.h>

// What -[AppController initDCMTK] and Decompress register, decoders and
// encoders. Called from main: a static constructor would run before DCMTK's
// own static codec list exists.
extern "C" void HorosTestRegisterDecoders(void)
{
    DJDecoderRegistration::registerCodecs(EDC_photometricInterpretation, EUC_never);
    DJEncoderRegistration::registerCodecs();
    DJLSDecoderRegistration::registerCodecs();
    DJLSEncoderRegistration::registerCodecs();
    DcmRLEDecoderRegistration::registerCodecs();
    DcmRLEEncoderRegistration::registerCodecs();
    HorosJPEG2000Registration::registerCodecs();
}
'''


def missing(products):
    """Why the reader cannot be built from `products`, or None."""
    products = Path(products)
    if not (products / 'DCM.framework').is_dir():
        return 'no DCM.framework in %s' % products
    if not (BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a').is_file():
        return 'no OpenJPEG in the build'
    return None


def compile_reader(products, source, output, work):
    """Compile the Objective-C `source` file into `output`.

    `output` has to sit one folder below a `Frameworks` link to `products`,
    because DCM.framework is installed as @executable_path/../Frameworks.
    """
    products, work = Path(products).resolve(), Path(work)
    setup = work / 'horos-reader-setup.mm'
    setup.write_text(SETUP)
    openjpeg = BUILD / 'OpenJPEG.build/Install'
    flags = dcmtk_flags('dcmjpeg', 'horosdcmjpls', 'dcmimage', 'dcmimgle', 'ijg8', 'ijg12', 'ijg16')
    # The host's DCMTK tag dictionaries, which DCM.framework asks for by name,
    # with the dicom.dic the application ships beside the executable.
    dictionaries = work / 'dictionaries.o'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-w', *flags[:2], '-c',
                    str(ROOT / 'Horos/Sources/DICOMDataDictionary.mm'), '-o', str(dictionaries)], check=True)
    shipped = BUILD.parent.parent.parent / 'Products' / BUILD.name / 'DCMTK/dicom.dic'
    if shipped.is_file():
        shutil.copy(shipped, Path(output).parent / 'dicom.dic')
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-fmodules', '-fcxx-modules', '-w',
                    '-F', str(products), '-I', str(products / 'DCM.framework/Headers'),
                    '-I', str(openjpeg / 'include'), *flags[:2],
                    '-x', 'objective-c++', str(source), str(setup),
                    str(ROOT / 'Horos/Sources/HorosDCMTKObject.mm'), str(ROOT / 'Horos/Sources/HorosDICOMServices.mm'),
                    str(ROOT / 'Horos/Sources/HorosDICOMWriter.mm'),
                    '-x', 'c++', str(ROOT / 'Horos/Sources/HorosJPEG2000Codec.cpp'), '-x', 'none', str(dictionaries),
                    '-framework', 'DCM', '-framework', 'Foundation',
                    str(openjpeg / 'lib/libopenjp2.a'),
                    *flags[2:], '-o', str(output)], check=True)
