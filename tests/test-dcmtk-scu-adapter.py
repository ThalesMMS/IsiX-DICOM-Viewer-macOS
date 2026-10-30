#!/usr/bin/env python3
"""The DCMTK adapter of the send and of the listener's C-MOVE turns DCMTK's errors and C++ exceptions into NSError.

DCMTKStoreSCU (Swift) reaches DCMTK only through Horos/Sources/Adapters/DCMTK:
IsiXDCMTKStoreSCU (the files read for a C-STORE, their copies in another
transfer syntax, the C-STORE) on the association the query nodes use, now
given its presentation contexts by the caller. The listener's C-MOVE sends
its sub-operations through IsiXDCMTKMoveContext, called by DCMTK's
DIMSE_moveProvider, which must never see a C++ exception.

The adapter's files are compiled here against the DCMTK, OpenSSL and OpenJPEG
the Debug build installed (exit 2 without that build), with a driver that:
- reads a DICOM file it wrote with DCMTK, its identity and transfer syntax,
  and writes a copy in another syntax;
- provokes DCMTK errors: a file that is not DICOM, presentation contexts the
  caller could not fit (ASC_BADPRESENTATIONCONTEXTID, naming the step), an
  association asked of a port nobody listens on, a C-STORE on it and one on
  an association not asked for; each is an NSError of IsiXDCMTKErrorDomain with the
  condition's module, code and text;
- provokes a C++ exception in the database of a C-MOVE (startMoveRequest
  throws) and receives the move's failure status instead of a terminated
  process; a destination the application does not know ends the move with
  "Move Destination unknown".
"""
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from dcmtk_build import BUILD, ROOT, dcmtk_flags

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SOURCES = [ADAPTERS / name for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKDataset.mm', 'IsiXDCMTKQueryRetrieveSCU.mm',
                                        'IsiXDCMTKStoreSCU.mm')]

# The move context is compiled without ARC, as in the application; the C++ of
# the representation helpers needs the JPEG 2000 codec of the application.
MRC_SOURCES = [ADAPTERS / 'IsiXDCMTKMoveContext.mm']
CODEC = ROOT / 'Horos/Sources/Adapters/DCMTK/HorosJPEG2000Codec.cpp'

# HorosDICOMStoreSource.h, which the move context includes, asks the
# application's Swift policy; the driver answers for it.
SWIFT_HEADER = r'''
#import <Foundation/Foundation.h>
@interface HorosDIMSEPolicy : NSObject
+ (NSInteger)rankAccepted:(NSString *)accepted original:(NSString *)original;
+ (BOOL)requiresConversionAccepted:(NSString *)accepted original:(NSString *)original;
@end
'''

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKStoreSCU.h"
#import "IsiXDCMTKMoveDestination.h"
#include "IsiXDCMTKRetrieveLoops.hpp"
#include "IsiXDCMTKMoveContext.hpp"
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmqrdb/dcmqrdba.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <dcmtk/dcmqrdb/dcmqrdbs.h>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

extern "C" BOOL HorosDIMSEAssociationPDUIsValid(const unsigned char *, ptrdiff_t) noexcept { return YES; }
OFCondition HorosDIMSEGetUser(T_ASC_Association*, T_ASC_PresentationContextID, T_DIMSE_C_GetRQ*, DcmDataset*,
    DIMSE_GetUserCallback, void*, T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_GetRSP*, DcmDataset**, DcmDataset**, IsiXDCMTKIncomingCallback, void*, id<IsiXDCMTKSCPDatabase>) { return EC_IllegalCall; }
OFCondition HorosDIMSEMoveUser(T_ASC_Association*, T_ASC_PresentationContextID, T_DIMSE_C_MoveRQ*, DcmDataset*,
    DIMSE_MoveUserCallback, void*, T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_MoveRSP*, DcmDataset**, DcmDataset**, OFBool) { return EC_IllegalCall; }

@implementation HorosDIMSEPolicy
+ (NSInteger)rankAccepted:(NSString *)accepted original:(NSString *)original { return 0; }
+ (BOOL)requiresConversionAccepted:(NSString *)accepted original:(NSString *)original { return NO; }
@end

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

static bool isCondition(NSError *error)
{
    return [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code > 0
        && error.userInfo[IsiXDCMTKConditionModuleKey] && error.userInfo[IsiXDCMTKConditionCodeKey]
        && [error.userInfo[IsiXDCMTKConditionTextKey] length] > 0;
}

// A database whose move request throws, or answers pending.
class Database : public DcmQueryRetrieveDatabaseHandle {
public:
    bool throws = false;
    OFCondition makeNewStoreFileName(const char *, const char *, char *, size_t) override { return EC_IllegalCall; }
    OFCondition storeRequest(const char *, const char *, const char *, DcmQueryRetrieveDatabaseStatus *, OFBool) override { return EC_IllegalCall; }
    OFCondition startFindRequest(const char *, DcmDataset *, DcmQueryRetrieveDatabaseStatus *) override { return EC_IllegalCall; }
    OFCondition nextFindResponse(DcmDataset **, DcmQueryRetrieveDatabaseStatus *, const DcmQueryRetrieveCharacterSetOptions &) override { return EC_IllegalCall; }
    OFCondition cancelFindRequest(DcmQueryRetrieveDatabaseStatus *) override { return EC_Normal; }
    OFCondition startMoveRequest(const char *, DcmDataset *, DcmQueryRetrieveDatabaseStatus *status) override {
        if (throws) throw std::runtime_error("the database went away");
        status->setStatus(STATUS_Pending);
        return EC_Normal;
    }
    OFCondition nextMoveResponse(char *, size_t, char *, size_t, char *, size_t, unsigned short *, DcmQueryRetrieveDatabaseStatus *status) override {
        status->setStatus(STATUS_Success);
        return EC_Normal;
    }
    OFCondition cancelMoveRequest(DcmQueryRetrieveDatabaseStatus *) override { return EC_Normal; }
    OFCondition pruneInvalidRecords() override { return EC_Normal; }
    void setIdentifierChecking(OFBool, OFBool) override {}
};

static uint16_t move(Database &database, IsiXDCMTKMoveDestinationLookup lookup)
{
    T_ASC_Parameters *parameters = NULL;
    ASC_createAssociationParameters(&parameters, ASC_DEFAULTMAXPDU);
    ASC_setAPTitles(parameters, "REQUESTER", "LISTENER", NULL);
    T_ASC_Association requester = {};
    requester.params = parameters;
    DcmQueryRetrieveOptions options;
    IsiXDCMTKMoveContext context(database, options, NULL, STATUS_Pending, &requester, 7, DIMSE_PRIORITY_MEDIUM, lookup);
    T_DIMSE_C_MoveRQ request = {};
    strcpy(request.AffectedSOPClassUID, UID_MOVEStudyRootQueryRetrieveInformationModel);
    strcpy(request.MoveDestination, "NOWHERE");
    DcmDataset identifiers;
    T_DIMSE_C_MoveRSP response = {};
    DcmDataset *detail = NULL, *answer = NULL;
    context.callbackHandler(OFFalse, &request, &identifiers, 1, &response, &detail, &answer);
    delete detail;
    delete answer;
    ASC_destroyAssociationParameters(&parameters);
    return response.DimseStatus;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[2]];
        // A file DCMTK writes, read back for a C-STORE.
        NSString *path = [folder stringByAppendingPathComponent:@"ct.dcm"];
        DcmFileFormat written;
        DcmDataset *dataset = written.getDataset();
        dataset->putAndInsertString(DCM_SOPClassUID, UID_CTImageStorage);
        dataset->putAndInsertString(DCM_SOPInstanceUID, "1.2.826.0.1.3680043.8.498.1485.1");
        dataset->putAndInsertString(DCM_PatientName, "ADAPTER^SEND");
        dataset->putAndInsertUint16(DCM_Rows, 2); dataset->putAndInsertUint16(DCM_Columns, 2);
        dataset->putAndInsertUint16(DCM_BitsAllocated, 16); dataset->putAndInsertUint16(DCM_BitsStored, 16);
        dataset->putAndInsertUint16(DCM_HighBit, 15); dataset->putAndInsertUint16(DCM_PixelRepresentation, 0);
        dataset->putAndInsertUint16(DCM_SamplesPerPixel, 1);
        dataset->putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
        const Uint16 pixels[4] = {1, 2, 3, 4};
        dataset->putAndInsertUint16Array(DCM_PixelData, pixels, 4);
        check(written.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), "a test file is written");

        NSError *error = nil;
        IsiXDCMTKStoreFile *file = [[IsiXDCMTKStoreFile alloc] initWithPath:path error:&error];
        check(file && !error, "a DICOM file is read for a C-STORE");
        check([file.sopClassUID isEqual:@UID_CTImageStorage] && [file.sopInstanceUID isEqual:@"1.2.826.0.1.3680043.8.498.1485.1"],
              "its identity is read");
        check([file.transferSyntax.uid isEqual:@UID_LittleEndianExplicitTransferSyntax] && file.transferSyntax.usesNativeFormat
              && !file.transferSyntax.pixelDataCompressed, "its transfer syntax is read");
        check([[IsiXDCMTKStoreFile storageSOPClassOfFileAtPath:path] isEqual:@UID_CTImageStorage], "its storage class is found");
        NSString *copy = [folder stringByAppendingPathComponent:@"copy.dcm"];
        check([file writeCopyToPath:copy transferSyntax:@UID_LittleEndianImplicitTransferSyntax quality:0], "a copy is written in another syntax");
        IsiXDCMTKStoreFile *copied = [[IsiXDCMTKStoreFile alloc] initWithPath:copy error:NULL];
        check([copied.transferSyntax.uid isEqual:@UID_LittleEndianImplicitTransferSyntax], "in that syntax");
        check([file.transferSyntax.uid isEqual:@UID_LittleEndianExplicitTransferSyntax], "and the file read is left as it was");
        check(![[IsiXDCMTKTransferSyntax alloc] initWithUID:@"1.2.3"].known && [[IsiXDCMTKTransferSyntax alloc] initWithDCMTKValue:EXS_JPEG2000].pixelDataCompressed,
              "transfer syntaxes are told apart by UID and by DCMTK's value");
        check([IsiXDCMTKUIDs shortStorageSOPClasses].count > 50 && [[IsiXDCMTKUIDs modalityOfSOPClass:@UID_CTImageStorage] isEqual:@"CT"],
              "DCMTK's storage classes and modalities are given");
        check([IsiXDCMTKAssociation availableCipherSuites].count > 0, "DCMTK's TLS cipher suites are listed");

        // A DCMTK error: a file that is not DICOM.
        NSString *notDICOM = [folder stringByAppendingPathComponent:@"not.dcm"];
        [@"not a DICOM file" writeToFile:notDICOM atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        error = nil;
        check([[IsiXDCMTKStoreFile alloc] initWithPath:notDICOM error:&error] == nil && isCondition(error),
              "a file that is not DICOM is a DCMTK condition in an NSError");
        check([IsiXDCMTKStoreFile storageSOPClassOfFileAtPath:notDICOM] == nil, "and has no storage class");

        // A DCMTK error: contexts the caller could not fit, at the step that adds them.
        IsiXDCMTKAssociationParameters *parameters = [[IsiXDCMTKAssociationParameters alloc] init];
        parameters.callingAETitle = @"STORESCU";
        parameters.calledAETitle = @"NOBODY";
        parameters.peerHost = @"127.0.0.1";
        parameters.peerPort = atoi(argv[1]);
        parameters.acseTimeout = parameters.dimseTimeout = 5;
        parameters.presentationContextsRefused = YES;
        error = nil;
        check([[IsiXDCMTKAssociation alloc] initWithParameters:parameters error:&error] == nil && isCondition(error)
              && [error.userInfo[IsiXDCMTKOperationKey] isEqual:@"addPresentationContext"],
              "contexts that do not fit fail with ASC_BADPRESENTATIONCONTEXTID where they are added");
        printf("  %s\n", [IsiXDCMTKError conditionDescriptionOfError:error].UTF8String);

        // A DCMTK error: an association asked of a port nobody listens on.
        parameters.presentationContextsRefused = NO;
        parameters.presentationContexts = @[[[IsiXDCMTKPresentationContext alloc] initWithIdentifier:1 abstractSyntax:@UID_CTImageStorage
                                                                                      transferSyntaxes:@[@UID_LittleEndianExplicitTransferSyntax]]];
        error = nil;
        IsiXDCMTKAssociation *association = [[IsiXDCMTKAssociation alloc] initWithParameters:parameters error:&error];
        check(association && !error, "the network and the planned contexts are made");
        NSError *requested = [association request];
        check(isCondition(requested), "a closed port is a DCMTK condition in an NSError");
        check([association acceptedPresentationContextForAbstractSyntax:@UID_CTImageStorage transferSyntax:nil] == 0,
              "it accepted no presentation context");
        IsiXDCMTKStoreResult *stored = [association storeFile:file presentationContext:1 messageID:[association nextMessageID]];
        check(isCondition(stored.condition) && !stored.accepted, "a C-STORE on an association that never came is a DCMTK condition");
        IsiXDCMTKAssociation *unrequested = [[IsiXDCMTKAssociation alloc] initWithParameters:parameters error:NULL];
        stored = [unrequested storeFile:file presentationContext:1 messageID:[unrequested nextMessageID]];
        check([IsiXDCMTKError kindOfError:stored.condition] == IsiXDCMTKConditionKindIllegalParameter && !stored.accepted,
              "a C-STORE before the association is asked for is EC_IllegalParameter");
        check([association invalidate] == nil && [association releaseAssociation] != nil, "it is destroyed at once and is unusable after");
        check([IsiXDCMTKError kindOfError:[IsiXDCMTKError errorForConditionKind:IsiXDCMTKConditionKindBadMessage]]
              == IsiXDCMTKConditionKindBadMessage, "a refused C-STORE is DIMSE_BADMESSAGE");

        // The listener's C-MOVE: a C++ exception in its database, and a destination nobody knows.
        __block NSString *asked = nil;
        IsiXDCMTKMoveDestinationLookup nowhere = ^IsiXDCMTKMoveDestination *(NSString *aeTitle) { asked = aeTitle; return nil; };
        Database throwing;
        throwing.throws = true;
        check(move(throwing, nowhere) == STATUS_MOVE_Failed_UnableToProcess,
              "a C++ exception in the move ends it with Unable to process, not a terminated process");
        Database pending;
        check(move(pending, nowhere) == STATUS_MOVE_Failed_MoveDestinationUnknown && [asked isEqual:@"NOWHERE"],
              "a destination the application does not know ends the move with Move Destination unknown");
    }
    return failures ? 1 : 0;
}
'''


def build_archives(*names):
    library = BUILD / names[0]
    return [library / name for name in names[1:]]


def closed_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


flags = dcmtk_flags('dcmnet', 'dcmtls', 'dcmqrdb', 'dcmjpls', 'dcmtkcharls', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16',
                    'dcmimage', 'dcmimgle')
archives = [BUILD / 'OpenSSL.build/Install/lib/libssl.a', BUILD / 'OpenSSL.build/Install/lib/libcrypto.a',
            BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a']
missing = [path for path in archives if not path.is_file()]
if missing:
    print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(missing[0]))
    raise SystemExit(2)
openjpeg = ['-I' + str(BUILD / 'OpenJPEG.build/Install/include'),
            *['-I' + str(path) for path in sorted((BUILD / 'OpenJPEG.build/Install/include').glob('openjpeg-*'))]]

with tempfile.TemporaryDirectory(prefix='isix-dcmtk-scu-adapter-') as temporary:
    folder = Path(temporary)
    (folder / 'Horos-Swift.h').write_text(SWIFT_HEADER)
    (folder / 'driver.mm').write_text(DRIVER)
    (folder / 'files').mkdir()
    common = ['xcrun', 'clang++', '-std=gnu++17', '-w', '-I' + str(folder), '-I' + str(ADAPTERS), *openjpeg]
    objects = []
    for source in MRC_SOURCES + [CODEC, folder / 'driver.mm']:
        language = 'c++' if source.suffix == '.cpp' else 'objective-c++'
        obj = folder / (source.stem + '.o')
        arc = ['-fno-objc-arc'] if source in MRC_SOURCES else (['-fobjc-arc'] if language != 'c++' else [])
        built = subprocess.run([*common, *arc, '-x', language, '-c', str(source), *flags[:2], '-o', str(obj)],
                               capture_output=True, text=True)
        if built.returncode:
            print(built.stderr[-4000:])
            print('FAIL: %s does not compile against the build\'s DCMTK' % source.name)
            sys.exit(1)
        objects.append(str(obj))
    strict = ['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror', '-Wno-unused-parameter',
              '-I' + str(folder), '-I' + str(ADAPTERS), *openjpeg]
    linked = subprocess.run([*strict, *map(str, SOURCES), *objects, *flags, *map(str, archives),
                             '-framework', 'Foundation', '-o', str(folder / 'check')], capture_output=True, text=True)
    if linked.returncode:
        print(linked.stderr[-4000:])
        print('FAIL: the adapter does not compile or link against the build\'s DCMTK')
        sys.exit(1)
    try:
        run = subprocess.run([str(folder / 'check'), str(closed_port()), str(folder / 'files')],
                             capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print('FAIL: the adapter driver did not end within 60 s')
        sys.exit(1)
    print(run.stdout, end='')
    if run.returncode:
        print(run.stderr[-2000:])
        print('FAIL: the adapter driver failed (exit %d)' % run.returncode)
        sys.exit(1)
print('PASS: the send\'s and the C-MOVE\'s DCMTK errors and a C++ exception reach the caller as NSError or a status')
