#!/usr/bin/env python3
"""The DCMTK adapter of the query nodes turns DCMTK's errors and C++ exceptions into NSError.

Horos/Sources/Adapters/DCMTK holds the only Objective-C++ that the query nodes
(DCMTKQueryNode and its levels, now Swift) reach DCMTK through: a dataset
(IsiXDCMTKDataset) and an association (IsiXDCMTKAssociation) whose headers
carry no C++ type. Swift cannot catch a C++ exception, so every call into
DCMTK runs inside a guard that turns one into an NSError, and every DCMTK
condition other than EC_Normal comes back as an NSError too.

The adapter's files are compiled here against the DCMTK and OpenSSL the Debug
build installed (exit 2 without that build), with a driver that:
- writes and reads a dataset through the adapter, values as bytes;
- provokes DCMTK errors: a file that is not DICOM, a peer address DCMTK
  refuses, an association asked of a port nobody listens on, and a C-FIND on
  an association that never came; each is an NSError of IsiXDCMTKErrorDomain
  with the condition's module, code and text;
- provokes a C++ exception (std::vector::at out of range) inside an adapter
  call that walks a DCMTK dataset, and receives it as an NSError of
  IsiXDCMTKErrorCodeException instead of a terminated process;
- reads DCMTK's data dictionary through IsiXDCMTKDictionary: the keyword of a
  tag, the public attributes in tag order without private or group 0 entries,
  an exception thrown from the block that comes back as an NSError and leaves
  the dictionary unlocked, and the error when no dictionary is loaded.

The C-MOVE and C-GET loops (IsiXDCMTKMoveUser.mm, IsiXDCMTKGetUser.mm) are the
application's own and are not exercised here; the driver stubs them. The
send's part of the adapter has its own test, test-dcmtk-scu-adapter.py. The
Swift check of the association PDU is stubbed to accept.
"""
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from dcmtk_build import BUILD, ROOT, dcmtk_flags

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SOURCES = [ADAPTERS / name for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKDataset.mm', 'IsiXDCMTKQueryRetrieveSCU.mm',
                                              'IsiXDCMTKDictionary.mm')]

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKDataset.h"
#import "IsiXDCMTKQueryRetrieveSCU.h"
#import "IsiXDCMTKDictionary.h"
#include "IsiXDCMTKRetrieveLoops.hpp"
#include <dcmtk/dcmdata/dcdict.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" BOOL HorosDIMSEAssociationPDUIsValid(const unsigned char *, ptrdiff_t) noexcept { return YES; }
OFCondition HorosDIMSEGetUser(T_ASC_Association*, T_ASC_PresentationContextID, T_DIMSE_C_GetRQ*, DcmDataset*,
    DIMSE_GetUserCallback, void*, T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_GetRSP*, DcmDataset**, DcmDataset**, IsiXDCMTKIncomingCallback, void*, id<IsiXDCMTKSCPDatabase>) { return EC_IllegalCall; }
OFCondition HorosDIMSEMoveUser(T_ASC_Association*, T_ASC_PresentationContextID, T_DIMSE_C_MoveRQ*, DcmDataset*,
    DIMSE_MoveUserCallback, void*, T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_MoveRSP*, DcmDataset**, DcmDataset**, OFBool) { return EC_IllegalCall; }

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

static NSData *bytes(const char *text) { return [NSData dataWithBytes:text length:strlen(text)]; }

int main(int argc, char **argv)
{
    @autoreleasepool {
        const uint32_t patientName = 0x00100010, studyUID = 0x0020000D, level = 0x00080052, sopUID = 0x00080018;
        // Values go in and out as bytes; an empty element asks for the attribute.
        IsiXDCMTKDataset *dataset = [[IsiXDCMTKDataset alloc] init];
        NSError *error = nil;
        check([dataset putValue:bytes("DOE^JOHN ") forTag:patientName error:&error] && !error, "a value goes in");
        check([dataset putValue:bytes("STUDY") forTag:level error:&error], "the level goes in");
        check([dataset insertEmptyElementWithTag:studyUID error:&error], "an empty element goes in");
        NSData *raw = [dataset rawValueForTag:patientName];
        check(raw.length >= 8 && memcmp(raw.bytes, "DOE^JOHN", 8) == 0, "the raw value comes back as DCMTK holds it");
        check([[dataset stringValueForTag:patientName] isEqual:bytes("DOE^JOHN")], "the read value is normalized as DCMTK reads it");
        check([dataset rawValueForTag:studyUID] == nil && [[dataset stringValueForTag:studyUID] length] == 0, "an empty element reads empty");
        check([dataset rawValueForTag:sopUID] == nil && [dataset stringValueForTag:sopUID] == nil, "an absent element reads nil");
        NSMutableArray *order = [NSMutableArray array];
        check([dataset enumerateElementsUsingBlock:^(uint32_t tag, NSData *value) { [order addObject:@(tag)]; } error:&error],
              "the elements are walked");
        check([order isEqual:(@[@(level), @(patientName), @(studyUID)])], "in tag order");
        IsiXDCMTKDataset *copy = [dataset copy];
        [copy putValue:bytes("SERIES") forTag:level error:NULL];
        check([[dataset stringValueForTag:level] isEqual:bytes("STUDY")], "a copy is a dataset of its own");

        // A DCMTK error: a file that is not DICOM.
        NSString *notDICOM = [NSTemporaryDirectory() stringByAppendingPathComponent:@"isix-adapter-not-dicom.txt"];
        [@"not a DICOM file" writeToFile:notDICOM atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        error = nil;
        IsiXDCMTKDataset *read = [IsiXDCMTKDataset datasetOfFileAtPath:notDICOM transferSyntax:NULL error:&error];
        check(read == nil && isCondition(error), "a file that is not DICOM is a DCMTK condition in an NSError");
        printf("  %s\n", [IsiXDCMTKError conditionDescriptionOfError:error].UTF8String);
        [[NSFileManager defaultManager] removeItemAtPath:notDICOM error:NULL];

        // A DCMTK error: a peer address DCMTK refuses.
        IsiXDCMTKAssociationParameters *parameters = [[IsiXDCMTKAssociationParameters alloc] init];
        parameters.callingAETitle = @"ADAPTERTEST";
        parameters.calledAETitle = @"NOBODY";
        parameters.peerHost = @"127.0.0.1";
        parameters.peerPort = 0;
        parameters.abstractSyntax = @"1.2.840.10008.5.1.4.1.2.2.1";
        parameters.acseTimeout = parameters.dimseTimeout = 5;
        error = nil;
        IsiXDCMTKAssociation *refused = [[IsiXDCMTKAssociation alloc] initWithParameters:parameters error:&error];
        check(refused == nil && isCondition(error) && [error.userInfo[IsiXDCMTKPeerAddressKey] boolValue],
              "port 0 is refused as a peer address, with its condition");

        // A DCMTK error: an association asked of a port nobody listens on.
        parameters.peerPort = atoi(argv[1]);
        error = nil;
        IsiXDCMTKAssociation *association = [[IsiXDCMTKAssociation alloc] initWithParameters:parameters error:&error];
        check(association != nil && error == nil, "the network and parameters are made");
        NSError *requested = [association request];
        check(isCondition(requested), "a closed port is a DCMTK condition in an NSError");
        printf("  %s\n", [IsiXDCMTKError conditionDescriptionOfError:requested].UTF8String);
        IsiXDCMTKFindResult *refusedFind = [association findWithIdentifier:dataset response:^(IsiXDCMTKDataset *match) {}];
        check(association.acceptedPresentationContextCount == 0 &&
              [IsiXDCMTKError kindOfError:refusedFind.condition] == IsiXDCMTKConditionKindNoPresentationContext,
              "a C-FIND on it finds no accepted presentation context");
        IsiXDCMTKAssociation *unrequested = [[IsiXDCMTKAssociation alloc] initWithParameters:parameters error:NULL];
        IsiXDCMTKFindResult *found = [unrequested findWithIdentifier:dataset response:^(IsiXDCMTKDataset *match) {}];
        check([IsiXDCMTKError kindOfError:found.condition] == IsiXDCMTKConditionKindIllegalParameter,
              "a C-FIND before the association is asked for is EC_IllegalParameter");
        check([IsiXDCMTKError kindOfError:[IsiXDCMTKError errorForConditionKind:IsiXDCMTKConditionKindNetworkClosed]]
              == IsiXDCMTKConditionKindNetworkClosed, "a given-up association is DUL_NETWORKCLOSED");

        // A C++ exception thrown inside an adapter call that walks the dataset.
        error = nil;
        __block int visited = 0;
        BOOL walked = [dataset enumerateElementsUsingBlock:^(uint32_t tag, NSData *value) {
            visited++;
            std::vector<int> none;
            (void)none.at(1);
        } error:&error];
        check(!walked && visited == 1, "the walk stops at the exception");
        check([error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code == IsiXDCMTKErrorCodeException
              && [IsiXDCMTKError kindOfError:error] == IsiXDCMTKConditionKindException
              && [error.localizedDescription containsString:@"DcmItem::getElement"],
              "the C++ exception comes back as an NSError, not a terminated process");
        printf("  %s\n", error.localizedDescription.UTF8String);
        check([[dataset stringValueForTag:level] isEqual:bytes("STUDY")], "the dataset is intact after it");
        check([IsiXDCMTKAssociation storageSOPClassesOfferedByGet].count > 100, "a C-GET offers DCMTK's storage classes");

        // The data dictionary, as the Query window's custom field reads it.
        error = nil;
        check([[IsiXDCMTKDictionary keywordForTag:0x00080080 error:&error] isEqualToString:@"InstitutionName"] && !error,
              "the keyword of a tag");
        check([[IsiXDCMTKDictionary keywordForTag:0x00091001 error:&error] isEqualToString:@"Unknown Tag & Data"],
              "an unknown tag reads as DCMTK names it");
        NSMutableArray<NSNumber *> *tags = [NSMutableArray array];
        NSMutableDictionary<NSNumber *, NSString *> *names = [NSMutableDictionary dictionary];
        BOOL listed = [IsiXDCMTKDictionary enumeratePublicAttributesUsingBlock:^(uint32_t tag, NSString *keyword) {
            [tags addObject:@(tag)];
            names[@(tag)] = keyword;
        } error:&error];
        check(listed && !error && tags.count > 1000, "the public attributes are listed");
        BOOL ordered = YES, publicOnly = YES;
        for (NSUInteger index = 0; index < tags.count; index++) {
            uint32_t tag = tags[index].unsignedIntValue;
            if (index && tags[index - 1].unsignedIntValue > tag) ordered = NO;
            if ((tag >> 16) == 0 || ((tag >> 16) & 1)) publicOnly = NO;
        }
        check(ordered, "in tag order");
        check(publicOnly, "without private or group 0 entries");
        check([names[@(0x00100010)] isEqualToString:@"PatientName"] && [names[@(0x0020000D)] isEqualToString:@"StudyInstanceUID"],
              "each with its keyword");
        error = nil;
        __block int given = 0;
        BOOL thrown = [IsiXDCMTKDictionary enumeratePublicAttributesUsingBlock:^(uint32_t tag, NSString *keyword) {
            given++;
            std::vector<int> none;
            (void)none.at(1);
        } error:&error];
        check(!thrown && given == 1 && error.code == IsiXDCMTKErrorCodeException
              && [error.localizedDescription containsString:@"DcmDataDictionary::normalBegin"],
              "an exception from the block comes back as an NSError");
        __block NSUInteger again = 0;
        check([IsiXDCMTKDictionary enumeratePublicAttributesUsingBlock:^(uint32_t tag, NSString *keyword) { again++; } error:NULL]
              && again == tags.count, "and leaves the dictionary unlocked");
        dcmDataDict.clear();
        error = nil;
        __block int unloaded = 0;
        check(![IsiXDCMTKDictionary enumeratePublicAttributesUsingBlock:^(uint32_t tag, NSString *keyword) { unloaded++; } error:&error]
              && unloaded == 0 && error.code == IsiXDCMTKErrorCodeFailure, "no dictionary loaded is an error");
    }
    return failures ? 1 : 0;
}
'''


def openssl_flags():
    library = BUILD / 'OpenSSL.build/Install/lib'
    archives = [library / 'libssl.a', library / 'libcrypto.a']
    missing = [path for path in archives if not path.is_file()]
    if missing:
        print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(missing[0]))
        raise SystemExit(2)
    return [str(path) for path in archives]


def closed_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


flags = dcmtk_flags('dcmnet', 'dcmtls')
flags += openssl_flags()
with tempfile.TemporaryDirectory(prefix='isix-dcmtk-adapter-') as temporary:
    folder = Path(temporary)
    (folder / 'driver.mm').write_text(DRIVER)
    compile_command = ['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror', '-Wno-unused-parameter',
                       '-I' + str(ADAPTERS), *map(str, SOURCES), str(folder / 'driver.mm'), *flags,
                       '-framework', 'Foundation', '-o', str(folder / 'check')]
    built = subprocess.run(compile_command, capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the adapter does not compile against the build\'s DCMTK')
        sys.exit(1)
    try:
        run = subprocess.run([str(folder / 'check'), str(closed_port())], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print('FAIL: the adapter driver did not end within 60 s')
        sys.exit(1)
    print(run.stdout, end='')
    if run.returncode:
        print(run.stderr[-2000:])
        print('FAIL: the adapter driver failed (exit %d)' % run.returncode)
        sys.exit(1)
print('PASS: DCMTK conditions and a C++ exception reach the caller as NSError; the data dictionary is read through the adapter')
