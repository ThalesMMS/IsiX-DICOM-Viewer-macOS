#!/usr/bin/env python3
"""A listener prints the identifier a peer asks it with only when the user default DICOMDatasetDump asks.

The identifier of a C-FIND or a C-MOVE holds the values of the keys asked: a
patient's name, ID or birth date, an accession number. The listener printed
the one of every C-MOVE a peer sent to the standard output, from its own move
context, and DCMTK's find context the one of every C-FIND to the standard
error, through DCMTK's own log - both for as long as that log was at INFO,
which is the level DCMTK starts it at. Only the set-up of the first send
lowered it, so a listener that had sent nothing yet printed them all, on
screen or in a transcript when the application is started from a terminal or
by a script.

The listener's DCMTK adapter is compiled here, as test-dcmtk-scp-adapter.py
compiles it, against the DCMTK, OpenSSL and OpenJPEG the Debug build installed
(exit 2 without that build), with a host and a database written for the test,
and a DCMTK SCU asks it a C-FIND and a C-MOVE for a patient that is a canary,
over the loopback, with nothing sent first. Twice:

- with the switch off, as it is unless set: DCMTK's log, put at INFO as DCMTK
  starts it, is at WARN once the listener is made, before its port opens, and
  neither output has the canary nor the heading of an identifier;
- with the switch on: the log is at INFO, never DEBUG, and the identifier of
  the C-FIND is on the standard error and that of the C-MOVE on the standard
  output, each under its heading - which is also what shows that this test
  would see them if they were printed;
- with the switch off and the log raised to INFO by hand once the listener is
  made, as anything that raised it later would: the move context prints its
  progress, which follows the level, and still no identifier, which waits for
  the switch and not for the level. (DCMTK's find context has the level alone,
  which is why one function sets it and nothing else may.)

Both runs first check the premise, that DCMTK starts its log at INFO, and
that IsiXDCMTKLog, which the application calls as it starts, sets the level
from the switch.
"""
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dcmtk_scp_adapter  # noqa: E402

PATIENT_ID = 'LEAKID-7731'
PATIENT_NAME = 'CANARY^LEAK'

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKQueryRetrieveSCP.h"
#import "IsiXDCMTKError.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmnet/scu.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmqrdb/dcmqrcnf.h>
#include <dcmtk/oflog/oflog.h>
#include <atomic>
#include <cstring>
#include <unistd.h>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    fflush(stdout);
    if (!condition) failures++;
}

static std::atomic<int> finds{0}, retrieves{0}, endedAssociations{0};

// A database that matches nothing: what is asked is all this test reads.
@interface Database : NSObject <IsiXDCMTKSCPDatabase>
@end
@implementation Database
- (IsiXDCMTKSCPRequestStart)startFindWithSOPClass:(NSString *)sopClass identifier:(IsiXDCMTKDataset *)identifier
{
    finds++;
    return IsiXDCMTKSCPRequestStartNoMatch;
}
- (BOOL)nextFindResponse:(IsiXDCMTKDataset *)response { return NO; }
- (IsiXDCMTKSCPRequestStart)startRetrieveWithSOPClass:(NSString *)sopClass identifier:(IsiXDCMTKDataset *)identifier
                                     moveDestination:(NSData *)moveDestination
{
    retrieves++;
    return IsiXDCMTKSCPRequestStartNoMatch;
}
- (NSInteger)retrieveCount { return 0; }
- (NSString *)nextRetrievePath { return nil; }
- (void)cancelRetrieve {}
- (NSString *)receivingDirectory { return NSTemporaryDirectory(); }
- (NSString *)publishReceivedFileAtPath:(NSString *)path { return nil; }
- (BOOL)namesSenderInReceivedFiles { return NO; }
- (BOOL)namesCalledTitleInReceivedFiles { return NO; }
- (void)didStoreInstanceWithAttributes:(NSDictionary<NSNumber *, NSData *> *)attributes {}
- (void)didEndStoreOfInstance:(NSString *)sopInstanceUID study:(NSString *)studyInstanceUID
                       series:(NSString *)seriesInstanceUID status:(uint16_t)status {}
- (void)associationEndedIncomplete {}
- (void)close {}
@end

@interface Host : NSObject <IsiXDCMTKListenerHost>
@end
@implementation Host
- (id<IsiXDCMTKSCPDatabase>)databaseForCallingAETitle:(NSString *)callingAETitle { return [Database new]; }
- (IsiXDCMTKMoveDestination *)moveDestinationForAETitle:(NSString *)aeTitle { return nil; }
- (BOOL)answersCommand:(IsiXDCMTKListenerCommand)command { return YES; }
- (NSUInteger)maximumConcurrentAssociations { return 4; }
- (BOOL)isListenerAETitle:(NSData *)calledAETitle { return YES; }
- (uint16_t)finalStatusOfGet:(uint16_t)proposed completed:(NSUInteger)completed failed:(NSUInteger)failed
                    warnings:(NSUInteger)warnings { return proposed; }
- (void)associationEndedWithError:(NSError *)error message:(NSString *)message {}
- (void)startAssociationThread:(NSThread *)thread peer:(NSString *)peer { [thread start]; }
- (void)association:(NSString *)peer willServe:(IsiXDCMTKListenerCommand)command secure:(BOOL)secure {}
- (void)associationDidEnd { endedAssociations++; }
@end

static bool logIs(bool dumps)
{
    // WARN always, INFO for the switch alone, DEBUG never, in the log of
    // DCMTK's Query/Retrieve classes and in that of its network.
    for (OFLogger *logger : {&DCM_dcmqrdbLogger, &DCM_dcmnetLogger})
        if (!logger->isEnabledFor(OFLogger::WARN_LOG_LEVEL) || logger->isEnabledFor(OFLogger::INFO_LOG_LEVEL) != dumps
            || logger->isEnabledFor(OFLogger::DEBUG_LOG_LEVEL))
            return false;
    return true;
}

static void identify(DcmDataset &keys)
{
    keys.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");
    keys.putAndInsertString(DCM_PatientID, "LEAKID-7731");
    keys.putAndInsertString(DCM_PatientName, "CANARY^LEAK");
    keys.putAndInsertString(DCM_StudyInstanceUID, "");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const int port = atoi(argv[1]);
        const bool dumps = strcmp(argv[2], "on") == 0;
        // The switch off, and the log raised by hand once the listener is made.
        const bool raised = strcmp(argv[2], "raised") == 0;

        check(DCM_dcmqrdbLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL) && DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL),
              "DCMTK starts its log at INFO, where its find context prints the identifier of a C-FIND");
        // As the application starts.
        [IsiXDCMTKLog configureDumpingDatasets:dumps ? YES : NO];
        check(logIs(dumps), dumps ? "the application's start leaves the log at INFO for the switch, not at DEBUG"
                                  : "the application's start puts the log at WARN");
        // A listener does not count on that: the log is put where the switch
        // does not put it, then the listener is made.
        OFLog::configure(dumps ? OFLogger::WARN_LOG_LEVEL : OFLogger::INFO_LOG_LEVEL);
        check(!logIs(dumps), "the log is put elsewhere by hand");

        IsiXDCMTKListenerSettings *settings = [IsiXDCMTKListenerSettings new];
        check(!settings.dumpsDatasets, "the settings of a listener start with the dump switch off");
        settings.port = port;
        settings.aeTitle = @"DUMPSCP";
        settings.preferredTransferSyntax = EXS_LittleEndianExplicit;
        settings.timeout = 10;
        settings.connectionTimeout = 5;
        settings.maxAssociations = 8;
        if (dumps) settings.dumpsDatasets = YES;
        IsiXDCMTKListener *listener = [[IsiXDCMTKListener alloc] initWithSettings:settings host:[Host new]];
        check(listener && logIs(dumps), dumps ? "made with the switch, a listener leaves the log at INFO, before its port opens"
                                              : "made, a listener puts the log at WARN, before its port opens");
        NSError *error = nil;
        check([listener openNetwork:&error] && [listener configure:&error] && !error, "the listener opens its port");
        if (raised) {
            OFLog::configure(OFLogger::INFO_LOG_LEVEL);
            check(DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL), "the log is raised to INFO by hand, the switch still off");
        }

        static std::atomic<bool> stop{false}, stopped{false};
        [NSThread detachNewThreadWithBlock:^{
            [listener serveUntil:^BOOL { return stop.load(); }];
            [listener close];
            stopped = true;
        }];

        {
            // The first thing this process does on the network: nothing was sent before.
            DcmSCU scu;
            scu.setAETitle("DUMPSCU");
            scu.setPeerHostName("127.0.0.1");
            scu.setPeerPort(port);
            scu.setPeerAETitle("DUMPSCP");
            scu.setACSETimeout(10);
            scu.setDIMSETimeout(10);
            scu.setDIMSEBlockingMode(DIMSE_BLOCKING);
            OFList<OFString> syntaxes;
            syntaxes.push_back(UID_LittleEndianExplicitTransferSyntax);
            syntaxes.push_back(UID_LittleEndianImplicitTransferSyntax);
            for (const char *model : {UID_FINDStudyRootQueryRetrieveInformationModel, UID_MOVEStudyRootQueryRetrieveInformationModel})
                scu.addPresentationContext(model, syntaxes);
            check(scu.initNetwork().good() && scu.negotiateAssociation().good(), "a peer's association is accepted");

            OFCondition result = EC_Normal;
            if (!raised) {
                DcmDataset asked;
                identify(asked);
                OFList<QRResponse *> found;
                result = scu.sendFINDRequest(scu.findAnyPresentationContextID(UID_FINDStudyRootQueryRetrieveInformationModel, ""),
                                             &asked, &found);
                check(result.good() && !found.empty() && found.back()->m_status == STATUS_Success && finds == 1,
                      "the peer's C-FIND for a patient is answered");
                for (QRResponse *response : found) delete response;
            }

            DcmDataset wanted;
            identify(wanted);
            OFList<RetrieveResponse *> moved;
            result = scu.sendMOVERequest(scu.findAnyPresentationContextID(UID_MOVEStudyRootQueryRetrieveInformationModel, ""),
                                         "NOWHERE", &wanted, &moved);
            check(result.good() && !moved.empty() && moved.back()->m_status == STATUS_Success && retrieves == 1,
                  "the peer's C-MOVE for a patient is answered");
            for (RetrieveResponse *response : moved) delete response;
            check(scu.releaseAssociation().good(), "and the association is released");
        }
        for (int i = 0; i < 200 && endedAssociations.load() < 1; i++) usleep(25000);
        if (!raised) check(logIs(dumps), "the log is where the listener put it after what it served");

        stop = true;
        for (int i = 0; i < 400 && !stopped; i++) usleep(25000);
        check(stopped, "the listener stops");
        fflush(stdout);
    }
    return failures ? 1 : 0;
}
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


FIND_DUMP = re.compile(r'Find SCP Request Identifiers:(?:\n.*){0,8}' + re.escape(PATIENT_ID))
MOVE_DUMP = re.compile(r'Move SCP Request Identifiers:(?:\n.*){0,8}' + re.escape(PATIENT_ID))
failures = []
with tempfile.TemporaryDirectory(prefix='isix-listener-dump-switch-') as temporary:
    executable = dcmtk_scp_adapter.build(temporary, DRIVER)
    runs = {}
    for mode in ('off', 'on', 'raised'):
        try:
            runs[mode] = subprocess.run([str(executable), str(free_port()), mode], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            print('FAIL: the listener driver did not end within 120 s with the switch %s' % mode)
            sys.exit(1)
        run = runs[mode]
        print('--- with the switch %s' % {'raised': 'off and the log raised by hand'}.get(mode, mode))
        print('\n'.join(line for line in run.stdout.splitlines() if line.startswith(('PASS: ', 'FAIL: '))))
        if run.returncode:
            print(run.stderr[-3000:])
            failures.append('the listener driver failed with the switch %s (exit %d)' % (mode, run.returncode))

    off, on = runs['off'], runs['on']
    for name, output in (('standard output', off.stdout), ('standard error', off.stderr)):
        for text in (PATIENT_ID, PATIENT_NAME, 'Request Identifiers'):
            if text in output:
                failures.append('with the switch off, the %s of a listener has %r of what a peer asked it' % (name, text))
    # With the switch, each identifier is where it was printed: this is also
    # what shows the check above would see them.
    if not FIND_DUMP.search(on.stderr):
        failures.append('with the switch on, the standard error has no identifier of the peer\'s C-FIND: %r' % on.stderr[-600:])
    if not MOVE_DUMP.search(on.stdout):
        failures.append('with the switch on, the standard output has no identifier of the peer\'s C-MOVE: %r' % on.stdout[-600:])
    if PATIENT_NAME not in on.stderr or PATIENT_NAME not in on.stdout:
        failures.append('with the switch on, an identifier is printed without the patient\'s name it asked for')
    # The move context's identifiers wait for the switch, not for the level:
    # at INFO without the switch it prints its progress and nothing else.
    raised = runs['raised']
    if 'Move SCP Response 1 [status: ' not in raised.stdout:
        failures.append('with the log raised by hand, the C-MOVE the listener served printed no progress: the log was not at INFO, '
                        'and the run shows nothing: %r' % raised.stdout[-600:])
    for name, output in (('standard output', raised.stdout), ('standard error', raised.stderr)):
        for text in (PATIENT_ID, PATIENT_NAME, 'Request Identifiers'):
            if text in output:
                failures.append('with the switch off and the log at INFO, the %s of a listener has %r of the C-MOVE a peer asked it'
                                % (name, text))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: a listener that has sent nothing prints no identifier a peer asks it with unless the dump switch is on, '
      'and DCMTK\'s log is at WARN from the moment it is made')
