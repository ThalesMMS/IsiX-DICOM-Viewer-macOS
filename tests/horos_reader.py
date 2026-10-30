"""Compile a test driver against the reader DCMPix uses.

The driver imports "HorosDCMTKObject.h", calls HorosTestRegisterDecoders() at
the start of main (declared by the header this module inserts), and reads files with
+[HorosDCMTKObject objectWithContentsOfFile:], which is DCMTK underneath and the
DCMObject interface on top. It is linked with the DCMTK and OpenJPEG archives
of the built application.

The dataset model (DCMObject and its attributes) is the IsiXDICOMDataset
module, built here with the modules below it. The reader, the writer and the
other DICOM host services the model finds by name are the DCMTK adapters of
Horos/Sources/Adapters/DCMTK, compiled as the application compiles them (ARC
for the IsiXDCMTK adapters, manual retain and release for HorosDCMTKObject.mm).
HorosDICOMWriter (Horos/Sources/HorosDICOMWriter.swift) is compiled with swiftc
against a bridging header of the adapter headers, and the encoders are
registered, so that DCMObject reading and writing works in the driver as it
does in the application.
"""
import re
import shutil
import subprocess
from pathlib import Path

from dcmtk_build import BUILD, ROOT, dcmtk_flags
from isix_modules import build_module
import history_reference

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
# The adapters compiled with ARC, as the application compiles them.
ARC_ADAPTERS = ['IsiXDCMTKError.mm', 'IsiXDCMTKFile.mm', 'IsiXDCMTKDataset.mm', 'IsiXDCMTKDictionary.mm',
                'IsiXDCMTKObjectWriter.mm', 'HorosDICOMServices.mm']
# The Objective-C dataset model a revision before IsiXDICOMDataset had in the
# adapter folder (model_objects with a revision), compiled with manual retain
# and release, as the application compiled it.
MODEL = ['DCMObject.m', 'DCMAttribute.m', 'DCMSequenceAttribute.m', 'DCMTransferSyntax.m', 'DCMEncapsulatedPDF.m',
         'DCMPixelDataAttribute.mm']
MODEL_HEADERS = ['DCMObject.h', 'DCMAttribute.h', 'DCMSequenceAttribute.h', 'DCMTransferSyntax.h',
                 'DCMEncapsulatedPDF.h', 'DCMPixelDataAttribute.h', 'DCMHostServices.h', 'DCMUIDs.h', 'DCMModel.h']

SETUP = r'''
#undef verify
#include "HorosJPEG2000Codec.hpp"
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

# What HorosDICOMWriter.swift sees of Objective-C, as the application's
# bridging header gives it.
WRITER_BRIDGE = r'''
#import <Foundation/Foundation.h>
#import "HorosDICOMWriter.h"
#import "IsiXDCMTKError.h"
#import "IsiXDCMTKFile.h"
#import "IsiXDCMTKDataset.h"
#import "IsiXDCMTKDictionary.h"
#import "HorosDICOMServices.h"
'''


# The former DCM.framework's names, for drivers and reference sources written
# against it: its umbrella and value type headers, each the dataset model of
# the DCMTK adapter, with the IsiXDICOMFile classes under the names the
# framework gave them (same selectors).
FORMER_ALIASES = {'DCMAttributeTag': 'IsiXDICOMAttributeTag', 'DCMCalendarDate': 'IsiXDICOMCalendarDate',
                  'DCMAbstractSyntaxUID': 'IsiXDICOMSOPClass', 'DCMCharacterSet': 'IsiXDICOMCharacterSet',
                  'DCMTagDictionary': 'IsiXDICOMTagDictionary', 'DCMTagForNameDictionary': 'IsiXDICOMTagDictionary'}
UIDS = 'Horos/Sources/Adapters/DCMTK/DCMUIDs.h'
FORMER_HEADERS = ['DCM', 'DCMObject', 'DCMAttribute', 'DCMSequenceAttribute', 'DCMPixelDataAttribute',
                  'DCMTransferSyntax', 'DCMEncapsulatedPDF', *FORMER_ALIASES]


def former_names(folder, model_headers=True):
    """A header folder that answers #import <DCM/X.h>, "DCM.h" and
    "DCMAttributeTag.h" (and the other value types) with the current model;
    pass it with -I. With `model_headers`, "DCMObject.h" and the other
    headers the Objective-C model had answer too; a reference compiled with
    that model from history (model_objects with a revision) has its own."""
    folder = Path(folder)
    (folder / 'DCM').mkdir(parents=True, exist_ok=True)
    umbrella = folder / 'DCMFormerNames.h'
    umbrella.write_text('#import "DCMModel.h"\n#import <Accelerate/Accelerate.h>\n'
                        + ''.join('@compatibility_alias %s %s;\n' % pair for pair in FORMER_ALIASES.items()))
    for name in FORMER_HEADERS:
        (folder / 'DCM' / (name + '.h')).write_text('#import "DCMFormerNames.h"\n')
        if name in FORMER_ALIASES or name == 'DCM' or model_headers:
            (folder / (name + '.h')).write_text('#import "DCMFormerNames.h"\n')
    if model_headers:
        # The framework's table of UID constants, which nothing has replaced:
        # the last revision that had it.
        revision = history_reference.before_removal(UIDS) or 'HEAD'
        uids = history_reference.show(revision, UIDS)
        (folder / 'DCMUIDs.h').write_bytes(uids)
        (folder / 'DCM' / 'DCMUIDs.h').write_bytes(uids)
    return folder


MODEL_CLASSES = ('DCMObject', 'DCMAttribute', 'DCMSequenceAttribute', 'DCMPixelDataAttribute', 'DCMTransferSyntax')


def without_model_forward_declarations(folder):
    """Has the sources in `folder` import DCMModel.h for the model's classes
    their @class lines declare: from history, they declared the classes the
    former names now alias to the module's, and an alias cannot follow a class
    of its name."""
    pattern = re.compile(r'^@class\s+([^;]*);', re.M)

    def kept(match):
        names = [n.strip() for n in match.group(1).split(',')]
        others = [n for n in names if n not in MODEL_CLASSES]
        if len(others) == len(names):
            return match.group(0)
        return '#import "DCMModel.h"\n' + ('@class %s;' % ', '.join(others) if others else '')
    for path in Path(folder).iterdir():
        if path.suffix in ('.h', '.m', '.mm'):
            text = path.read_bytes().decode('latin1')
            changed = pattern.sub(kept, text)
            if changed != text:
                path.write_bytes(changed.encode('latin1'))


def missing(products):
    """Why the reader cannot be built from `products`, or None."""
    products = Path(products)
    if not (BUILD / 'DCMTK.build/Install/lib/libdcmdata.a').is_file():
        return 'no DCMTK in the build'
    if not (BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a').is_file():
        return 'no OpenJPEG in the build'
    return None


def swift_link_flags():
    """Where the linker finds the Swift runtime libraries a Swift object asks for."""
    toolchain = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parents[1]
    return ['-L/usr/lib/swift', '-L' + str(toolchain / 'lib/swift/macosx'), '-Wl,-rpath,/usr/lib/swift']


def reader_flags(products):
    """The DCMTK flags (include folders, then archives) and the header search the host's sources need."""
    products = Path(products).resolve()
    flags = dcmtk_flags('dcmjpeg', 'horosdcmjpls', 'dcmimage', 'dcmimgle', 'ijg8', 'ijg12', 'ijg16', 'dcmnet')
    headers = ['-I', str(ADAPTERS),
               '-I', str(ROOT / 'Horos/Sources'),
               '-I', str(BUILD / 'OpenJPEG.build/Install/include'), *flags[:2]]
    return flags, headers


def model_objects(work, revision=None):
    """The dataset model (DCMObject and its attributes) in `work`, followed by
    the archives of the modules it uses. Its host services are found by name
    at run time; link with link_flags().

    The model is the IsiXDICOMDataset module, with IsiXDICOMFile and
    IsiXImaging below it. With `revision`, it is the Objective-C model that
    revision had in the adapter folder instead, compiled with manual retain
    and release from its sources and headers, which are exported to
    `work`/model-sources: pass that folder with -I before the adapters."""
    work = Path(work)
    modules = work / 'modules'
    target = ['-target', 'arm64-apple-macos15.0']
    if revision is None:
        build_module('IsiXDICOMDataset', modules, target)
        return [str(modules / 'libIsiXDICOMDataset.a'), str(modules / 'libIsiXDICOMFile.a'),
                str(modules / 'libIsiXImaging.a')]
    build_module('IsiXImaging', modules, target)
    build_module('IsiXDICOMFile', modules, [*target, '-I', str(modules)])
    sources = work / 'model-sources'
    sources.mkdir(parents=True, exist_ok=True)
    for name in MODEL + MODEL_HEADERS + ['DCMObject+IsiXAttributeSource.m']:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:Horos/Sources/Adapters/DCMTK/%s' % (revision, name)],
                               capture_output=True)
        if shown.returncode == 0:
            (sources / name).write_bytes(shown.stdout)
    objects = []
    for name in MODEL:
        language = 'objective-c++' if name.endswith('.mm') else 'objective-c'
        standard = ['-std=c++17', '-fcxx-modules'] if language == 'objective-c++' else []
        obj = work / ('model-' + name + '.o')
        subprocess.run(['xcrun', 'clang++', *standard, '-fno-objc-arc', '-fmodules', '-w', '-mmacosx-version-min=15.0',
                        '-I', str(sources), '-I', str(ADAPTERS), '-I', str(modules), '-x', language, '-c',
                        str(sources / name), '-o', str(obj)], check=True)
        objects.append(str(obj))
    return objects + [str(modules / 'libIsiXDICOMFile.a'), str(modules / 'libIsiXImaging.a')]


def host_objects(products, work):
    """The objects of the host services, compiled into `work` as the application
    compiles them: the ARC adapters, the dataset model and HorosDCMTKObject
    (manual retain and release), the JPEG 2000 codec, the codec registration and HorosDICOMWriter
    (Swift). Link them with link_flags()."""
    products, work = Path(products).resolve(), Path(work)
    flags, headers = reader_flags(products)
    # The dataset model and the DICOM value types (dates, tags, character
    # sets) the adapters use: IsiXDICOMDataset, over IsiXDICOMFile and IsiXImaging.
    modules = work / 'modules'
    model = model_objects(work)
    headers = [*headers, '-I', str(modules)]
    setup = work / 'horos-reader-setup.mm'
    setup.write_text(SETUP)
    objects = []
    for name in ARC_ADAPTERS:
        obj = work / ('reader-' + name + '.o')
        subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-fmodules', '-fcxx-modules', '-w',
                        '-mmacosx-version-min=15.0', *headers, '-c', str(ADAPTERS / name), '-o', str(obj)], check=True)
        objects.append(str(obj))
    for path, language, arc in ((ADAPTERS / 'HorosDCMTKObject.mm', 'objective-c++', '-fno-objc-arc'),
                                (setup, 'objective-c++', '-fno-objc-arc'),
                                (ADAPTERS / 'HorosJPEG2000Codec.cpp', 'c++', '-fno-objc-arc')):
        obj = work / ('reader-' + path.name + '.o')
        clang_modules = ['-fmodules', '-fcxx-modules'] if language == 'objective-c++' else []
        subprocess.run(['xcrun', 'clang++', '-std=c++17', arc, *clang_modules, '-w', '-mmacosx-version-min=15.0', *headers,
                        '-x', language, '-c', str(path), '-o', str(obj)], check=True)
        objects.append(str(obj))
    bridge = work / 'horos-writer-bridge.h'
    bridge.write_text(WRITER_BRIDGE)
    writer = work / 'reader-HorosDICOMWriter.o'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-name', 'HorosReaderWriter',
                    '-target', 'arm64-apple-macos15.0', '-c', '-import-objc-header', str(bridge),
                    '-F', str(products), '-Xcc', '-I' + str(ADAPTERS), '-Xcc', '-I' + str(ROOT / 'Horos/Sources'),
                    '-Xcc', '-I' + str(modules), '-I', str(modules),
                    str(ROOT / 'Horos/Sources/HorosDICOMWriter.swift'), '-o', str(writer)], check=True)
    objects.append(str(writer))
    return objects + model


def link_flags(products):
    """What host_objects need at link time, besides Foundation: the system
    frameworks the dataset model and the adapters use, OpenJPEG, the DCMTK
    archives and the Swift runtime."""
    flags, _ = reader_flags(products)
    return ['-framework', 'AppKit', '-framework', 'IOKit', '-framework', 'Accelerate',
            str(BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a'), *swift_link_flags(), *flags[2:]]


def compile_reader(products, source, output, work, extra=()):
    """Compile the Objective-C `source` file into `output`.

    `extra` is added to the compile and link command, for the flags of an
    internal module the source imports. The driver may be written against the
    former DCM.framework's names (former_names).
    """
    products, work = Path(products).resolve(), Path(work)
    _, headers = reader_flags(products)
    objects = host_objects(products, work)
    headers = [*headers, '-I', str(former_names(work / 'former-names'))]
    # The dicom.dic the application ships beside the executable.
    shipped = BUILD.parent.parent.parent / 'Products' / BUILD.name / 'DCMTK/dicom.dic'
    if shipped.is_file():
        shutil.copy(shipped, Path(output).parent / 'dicom.dic')
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-fmodules', '-fcxx-modules', '-w',
                    '-mmacosx-version-min=15.0', *headers, '-I', str(work / 'modules'),
                    '-x', 'objective-c++', str(source), '-x', 'none', *objects,
                    '-framework', 'Foundation', *link_flags(products), *extra, '-o', str(output)], check=True)
