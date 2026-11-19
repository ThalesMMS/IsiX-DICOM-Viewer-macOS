#!/usr/bin/env python3
"""Run an association's loop and its end: what reaches the host, with what message, and what stays in the log.

The DCMTK adapter's association ends as before (release acknowledged, abort
noted, anything else closes the transport) and hands each failure to the
listener's host with a message that names both AE titles, the peer's address,
where the association was (reading a command, serving a request, ending) and
the time the listener waits for the peer. A peer that stops sending in the
middle of a message leaves DIMSE_NODATAAVAILABLE, and the message says what
never came: the rest of a command, the identifier of a query or the data set
of a C-STORE. An association closed for being idle between commands is no
failure: it stays in the log, with the seconds it was given and without the
phase of the command it served before, and never reaches the host.

The host, in ListenerHost.swift, turns the error's kind into an end condition
and asks ListenerAssociationEndRules (IsiXDICOMNetwork, tested there) whether
it opens a notice: a peer abort and a message cut by a silent peer stay in the
log, any other failure opens one.

The loop, the message and the names of the requests are compiled here from the
adapter's source, with stand-ins for DCMTK and a scripted peer.
"""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
adapters = root / 'Horos/Sources/Adapters/DCMTK'
source = (adapters / 'IsiXDCMTKQueryRetrieveSCP.mm').read_text()
a = source.index('IsiXDCMTKListenerCommand CommandOf(')
b = source.index('class QueryRetrieveAssociation', a)
helpers = source[a:b]
a = source.index('    void notifyDIMSEError(')
b = source.index('    void notifyAssociationRequest(', a)
report = source[a:b].replace(' override', '')
a = source.index('    void handleAssociation()')
b = source.index('    OFCondition handleIncomingCommand(', a)
handle = source[a:b].replace(' override', '')
code = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKQueryRetrieveSCP.h"
#include <cassert>
#include <chrono>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <unistd.h>
#include <vector>
struct OFCondition {
 int value; bool good()const{return value==0;} bool bad()const{return value!=0;} int module()const{return 6;} int code()const{return value;}
 const char*text()const{return value==0?"Normal":value==1?"Peer release":value==2?"Peer abort":value==3?"Invalid PDU":
  value==5?"No valid presentation context":"DIMSE No data available (timeout in non-blocking mode)";}
 bool operator==(OFCondition rhs)const{return value==rhs.value;}
 bool operator!=(OFCondition rhs)const{return value!=rhs.value;}
};
const OFCondition EC_Normal{0},DUL_PEERREQUESTEDRELEASE{1},DUL_PEERABORTEDASSOCIATION{2},InvalidPDU{3},
 DIMSE_NOVALIDPRESENTATIONCONTEXTID{5},DIMSE_NODATAAVAILABLE{0x207};
enum {DIMSE_C_STORE_RQ=0x0001,DIMSE_C_GET_RQ=0x0010,DIMSE_C_FIND_RQ=0x0020,DIMSE_C_MOVE_RQ=0x0021,DIMSE_C_ECHO_RQ=0x0030,
 DIMSE_N_GET_RQ=0x0110};
struct T_DIMSE_Message {unsigned short CommandField;};
typedef unsigned char T_ASC_PresentationContextID;
struct DcmPresentationContextInfo {};
struct Parameters {struct {char callingAPTitle[65]="SENDER",calledAPTitle[65]="RECEIVER",callingPresentationAddress[64]="192.0.2.10";} DULparams;};
struct T_ASC_Association {Parameters*params;};
static struct {int value=1;int get()const{return value;}} dcmConnectionTimeout;
static OFCondition cleanup{0};static int closes=0,releases=0,aborts=0,incomplete=0;
static NSString *message=nil;static NSError *reported=nil;
NSError *IsiXDCMTKErrorFromCondition(const OFCondition& condition)
{ return [NSError errorWithDomain:@"test" code:condition.value userInfo:nil]; }
@interface Host : NSObject
-(void)associationEndedWithError:(NSError*)error message:(NSString*)value;
-(void)associationEndedIncomplete;
@end
@implementation Host
-(void)associationEndedWithError:(NSError*)error message:(NSString*)value{reported=error;message=value;}
-(void)associationEndedIncomplete{incomplete++;}
@end
struct Options {int dimse_timeout_;};
struct Listener {Host*host;Options options;};
struct DatabaseHandle {Host*host;Host*database(){return host;}};
OFCondition ASC_acknowledgeRelease(T_ASC_Association*){releases++;return cleanup;}
void ASC_closeTransportConnection(T_ASC_Association*){closes++;}
struct DcmSCP {void notifyDIMSEError(const OFCondition&){};};
namespace {
HELPERS
}
// What the scripted peer does with each message: what the receive of its
// command gives, the command, and what serving it gives.
struct Step {OFCondition receive;unsigned short command;OFCondition serve;};
struct Worker:DcmSCP {
 T_ASC_Association*association_;Listener listener_{[Host new],{40}};
 std::vector<Step> steps;size_t next=0;bool cancel=false,cancelWhenIdle=false,validContext=true;
 std::unique_ptr<DatabaseHandle> database_;
 AssociationPhase phase_={AssociationPhase::Waiting,IsiXDCMTKListenerCommandEcho,NULL,0};
 std::vector<AssociationPhase> receiving,serving;
 bool cancelled()const{return cancel;}
 void notifyReleaseRequest(){}void notifyAbortRequest(){aborts++;}
 bool ASC_dataWaiting(T_ASC_Association*,int){
  if(next<steps.size())return true;
  if(cancelWhenIdle)cancel=true;
  usleep(2000);return false;}
 OFCondition receiveDIMSECommand(T_ASC_PresentationContextID*,T_DIMSE_Message*received,void*){
  receiving.push_back(phase_);received->CommandField=steps[next].command;
  const OFCondition result=steps[next].receive;if(result.bad())next++;return result;}
 bool getPresentationContextInfo(T_ASC_Association*,T_ASC_PresentationContextID,DcmPresentationContextInfo&){return validContext;}
 OFCondition handleIncomingCommand(T_DIMSE_Message*,const DcmPresentationContextInfo&){
  serving.push_back(phase_);database_.reset(new DatabaseHandle{listener_.host});return steps[next++].serve;}
 REPORT
 HANDLE
};
static Parameters parameters;static T_ASC_Association association{&parameters};
static void reset(){cleanup=EC_Normal;closes=releases=aborts=incomplete=0;message=nil;reported=nil;}
// Runs an association against the scripted peer and gives the message the host got, nil when it got none.
static NSString*run(Worker&worker,std::initializer_list<Step> steps){
 worker.association_=&association;worker.steps=steps;worker.handleAssociation();assert(!worker.database_);return message;}
#define START @"DICOM association from SENDER (192.0.2.10) to RECEIVER ended: "
#define STARVED START @"0006:0207 DIMSE No data available (timeout in non-blocking mode)"
int main(){@autoreleasepool{
 const OFCondition ok=EC_Normal,starved=DIMSE_NODATAAVAILABLE;
 // The first command fails to arrive: a peer abort, a PDU that is not valid, a peer that stopped in the middle of it.
 for(int failure:{2,3,0x207})for(int cleanupFailure:{0,3}){
  reset();cleanup={cleanupFailure};Worker worker;NSString*said=run(worker,{{{failure},DIMSE_C_ECHO_RQ,ok}});
  assert(reported.code==failure);assert(closes==(failure==2?0:1));assert(aborts==(failure==2?1:0));assert(releases==0);
  assert(worker.receiving.size()==1&&worker.receiving[0].kind==AssociationPhase::Command&&worker.serving.empty());
  assert(incomplete==0);
  NSString*expected=failure==2?START @"0006:0002 Peer abort while ending the association (DIMSE timeout 40 s)"
   :failure==3?START @"0006:0003 Invalid PDU while reading a command (DIMSE timeout 40 s)"
   :STARVED @": nothing received for 40 s while reading the rest of a command";
  if(![said isEqual:expected]){fprintf(stderr,"%s\n",said.UTF8String);return 1;}
 }
 // The peer sends a command and nothing of what follows it: each request names what never came.
 struct {unsigned short command;IsiXDCMTKListenerCommand kind;NSString*missing;} cut[]={
  {DIMSE_C_FIND_RQ,IsiXDCMTKListenerCommandFind,@"reading the identifier of a C-FIND-RQ"},
  {DIMSE_C_MOVE_RQ,IsiXDCMTKListenerCommandMove,@"reading the identifier of a C-MOVE-RQ"},
  {DIMSE_C_GET_RQ,IsiXDCMTKListenerCommandGet,@"reading the identifier of a C-GET-RQ"},
  {DIMSE_C_STORE_RQ,IsiXDCMTKListenerCommandStore,@"reading the data set of a C-STORE-RQ"},
  {DIMSE_C_ECHO_RQ,IsiXDCMTKListenerCommandEcho,@"serving a C-ECHO-RQ"}};
 for(const auto&request:cut){
  reset();Worker worker;NSString*said=run(worker,{{ok,request.command,starved}});
  NSString*expected=[NSString stringWithFormat:@"%@: nothing received for 40 s while %@",STARVED,request.missing];
  if(![said isEqual:expected]){fprintf(stderr,"%s\n",said.UTF8String);return 1;}
  assert(reported.code==0x207&&closes==1&&aborts==0&&incomplete==1);
  assert(worker.serving.size()==1&&worker.serving[0].kind==AssociationPhase::Service&&worker.serving[0].command==request.kind);
 }
 // Any other failure of a request names the request and the timeout.
 reset();{Worker worker;NSString*said=run(worker,{{ok,DIMSE_C_FIND_RQ,InvalidPDU}});
  assert([said isEqual:START @"0006:0003 Invalid PDU while serving a C-FIND-RQ (DIMSE timeout 40 s)"]);assert(closes==1&&incomplete==1);}
 reset();{Worker worker;NSString*said=run(worker,{{ok,DIMSE_N_GET_RQ,InvalidPDU}});
  assert([said isEqual:START @"0006:0003 Invalid PDU while serving a command the listener does not serve (DIMSE timeout 40 s)"]);}
 reset();{Worker worker;worker.validContext=false;NSString*said=run(worker,{{ok,DIMSE_C_STORE_RQ,ok}});
  assert([said isEqual:START @"0006:0005 No valid presentation context while serving a C-STORE-RQ (DIMSE timeout 40 s)"]);
  assert(worker.serving.empty()&&incomplete==0);}
 // A message cut after another was served says its own phase, not the one before.
 reset();{Worker worker;NSString*said=run(worker,{{ok,DIMSE_C_FIND_RQ,ok},{starved,DIMSE_C_ECHO_RQ,ok}});
  assert([said isEqual:STARVED @": nothing received for 40 s while reading the rest of a command"]);
  assert(worker.receiving.size()==2&&worker.receiving[1].kind==AssociationPhase::Command&&incomplete==1);}
 reset();{Worker worker;NSString*said=run(worker,{{ok,DIMSE_C_FIND_RQ,ok},{ok,DIMSE_C_STORE_RQ,starved}});
  assert([said isEqual:STARVED @": nothing received for 40 s while reading the data set of a C-STORE-RQ"]);}
 // A peer abort in the middle of a request stays a peer abort.
 reset();{Worker worker;run(worker,{{ok,DIMSE_C_MOVE_RQ,DUL_PEERABORTEDASSOCIATION}});
  assert(reported.code==2&&aborts==1&&closes==0&&incomplete==1);
  assert([message isEqual:START @"0006:0002 Peer abort while ending the association (DIMSE timeout 40 s)"]);}
 // A release is acknowledged and is no failure; one that cannot be acknowledged is.
 reset();{Worker worker;assert(run(worker,{{ok,DIMSE_C_FIND_RQ,ok},{DUL_PEERREQUESTEDRELEASE,0,ok}})==nil);
  assert(reported==nil&&releases==1&&closes==0&&aborts==0&&incomplete==0);}
 reset();cleanup=InvalidPDU;{Worker worker;NSString*said=run(worker,{{DUL_PEERREQUESTEDRELEASE,0,ok}});
  assert(reported.code==3&&releases==1&&closes==0);
  assert([said isEqual:START @"0006:0003 Invalid PDU while ending the association (DIMSE timeout 40 s)"]);}
 // Cancelled here, before a command or between two: nothing reaches the host.
 reset();{Worker worker;worker.cancel=true;assert(run(worker,{})==nil);assert(reported==nil&&closes==1);}
 reset();{Worker worker;worker.cancelWhenIdle=true;assert(run(worker,{{ok,DIMSE_C_FIND_RQ,ok}})==nil);
  assert(reported==nil&&closes==1&&incomplete==1);}
 // Idle before the first command, for the connection timeout; idle after a
 // command, for the DIMSE timeout. Neither reaches the host: both are in the log.
 reset();{Worker worker;assert(run(worker,{})==nil);assert(reported==nil&&closes==1&&aborts==0&&incomplete==0);}
 reset();{Worker worker;worker.listener_.options.dimse_timeout_=2;assert(run(worker,{{ok,DIMSE_C_FIND_RQ,ok}})==nil);
  assert(reported==nil&&closes==1&&aborts==0&&incomplete==1);}
 puts("PASS: each failure reaches the host naming both AEs, the peer's address, the phase and the timeout; "
      "a message a silent peer cut says what never came; release, cancellation and idling retain their semantics");
}}
'''.replace('HELPERS', helpers).replace('REPORT', report).replace('HANDLE', handle)
with tempfile.TemporaryDirectory(prefix='horos-listener-result-') as folder:
    folder = Path(folder)
    (folder / 'test.mm').write_text(code)
    subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror', '-I' + str(adapters),
                    '-framework', 'Foundation', str(folder / 'test.mm'), '-o', str(folder / 'test')], check=True)
    result = subprocess.run([str(folder / 'test')], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise SystemExit(result.stderr)
    # The two idle associations, in the log: the seconds each was given, and
    # nothing of the C-FIND the second one served before.
    start = 'DICOM association from SENDER (192.0.2.10) to RECEIVER ended: 0006:0207 DIMSE No data available (timeout in non-blocking mode)'
    idle = [line[line.index('DICOM association'):] for line in result.stderr.splitlines() if 'closed as idle' in line]
    assert idle == [start + ': after 1 s without a command - closed as idle',
                    start + ': after 2 s without a command - closed as idle'], result.stderr
    assert 'C-FIND' not in result.stderr and 'while' not in result.stderr, result.stderr
    print(result.stdout, end='')
print('PASS: an association closed as idle stays in the log, with the seconds it waited and no phase of the command before')

# Only the idle branch of the loop calls the association idle: a timeout that
# comes back from the receive, inside a message, reaches the host. Each turn
# of the loop starts between commands, and the phase follows the exchange.
loop = source[source.index('void handleAssociation()'):source.index('// An association its sender did not release')]
assert loop.count('closedForIdling = true') == 1
assert re.search(r'>= idleTimeout\) \{\s*result = DIMSE_NODATAAVAILABLE;\s*closedForIdling = true;\s*\}', loop), loop
assert re.search(r'while \(result\.good\(\) && !cancelled\(\)\) \{\s*(?://[^\n]*\s*)*'
                 r'phase_ = \{AssociationPhase::Waiting, IsiXDCMTKListenerCommandEcho, NULL, idleTimeout\};\s*'
                 r'if \(!ASC_dataWaiting\(association_, 1\)\)', loop), loop
assert re.search(r'phase_\.kind = AssociationPhase::Command;\s*result = receiveDIMSECommand\(&id, &message, NULL\);\s*'
                 r'if \(result\.good\(\)\) \{\s*'
                 r'phase_ = \{AssociationPhase::Service, CommandOf\(&message\), RequestNameOf\(&message\), 0\};', loop), loop
print('PASS: only the wait between commands closes an association as idle, and each turn of the loop starts without a phase')

# The adapter gives the condition of a silent peer a kind of its own.
header = (adapters / 'IsiXDCMTKError.h').read_text()
kinds = re.findall(r'^\s*(IsiXDCMTKConditionKind\w+)\b', header[header.index('typedef NS_ENUM(NSInteger, IsiXDCMTKConditionKind)'):
                                                                header.index('};', header.index('typedef NS_ENUM(NSInteger, IsiXDCMTKConditionKind)'))],
                   re.M)
assert kinds[0] == 'IsiXDCMTKConditionKindOther' and kinds[-1] == 'IsiXDCMTKConditionKindNoDataAvailable', kinds
assert kinds[:9] == ['IsiXDCMTKConditionKindOther', 'IsiXDCMTKConditionKindAssociationRejected',
                     'IsiXDCMTKConditionKindPeerRequestedRelease', 'IsiXDCMTKConditionKindPeerAbortedAssociation',
                     'IsiXDCMTKConditionKindNetworkClosed', 'IsiXDCMTKConditionKindIllegalParameter',
                     'IsiXDCMTKConditionKindNoPresentationContext', 'IsiXDCMTKConditionKindException',
                     'IsiXDCMTKConditionKindBadMessage'], kinds
errors = (adapters / 'IsiXDCMTKError.mm').read_text()
assert 'if (condition == DIMSE_NODATAAVAILABLE) return IsiXDCMTKConditionKindNoDataAvailable;' in errors
assert 'case IsiXDCMTKConditionKindNoDataAvailable: return IsiXDCMTKErrorFromCondition(DIMSE_NODATAAVAILABLE);' in errors
print('PASS: DIMSE_NODATAAVAILABLE has a condition kind of its own, after the kinds there were')

# The host: the rule of the module decides, from the kind of the error, whether
# the end opens a notice; what it keeps from the panel goes to the log.
host = (root / 'Horos/Sources/ListenerHost.swift').read_text()
ended = host[host.index('func associationEndedWithError('):]
ended = ended[:ended.index('\n    }\n')]
assert re.search(r'guard ListenerAssociationEndRules\.showsNotice\(Self\.endCondition\(of: error\), command: nil\) else \{'
                 r'\s*NSLog\("%@", message\)\s*return\s*\}\s*DCMTKQueryRetrieveSCP\.displayListenerError\(message\)', ended), ended
condition = host[host.index('private static func endCondition(of error: any Error) -> ListenerEndCondition {'):]
condition = condition[:condition.index('\n    }\n')]
assert re.search(r'switch IsiXDCMTKError\.kind\(ofError: error\) \{\s*case \.peerAbortedAssociation: return \.peerAbort'
                 r'\s*case \.noDataAvailable: return \.noDataAvailable\s*default: return \.other\s*\}', condition), condition
print('PASS: the host asks the rule of the module, with a peer abort and a silent peer told from the other failures')

# The mode that forked a process per association is retired: its child
# opened the index with a confined context, and a context with a queue cannot
# run after fork().
for path in ('Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.mm', 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKSCPDatabase.mm',
             'Horos/Sources/SCPDatabaseSession.swift', 'Horos/Sources/DCMTKQueryRetrieveSCP.swift'):
    text = '\n'.join(line.split('//')[0] for line in (root / path).read_text().splitlines())
    assert not re.search(r'\bfork\s*\(', text), path
    assert 'NSConfinementConcurrencyType' not in text and 'confinementConcurrencyType' not in text, path
    assert 'forkedProcess' not in text and 'staticContext' not in text, path
assert 'options.singleProcess_ = OFTrue;' in source
print('PASS: the listener serves each association on a thread of its own; nothing forks')
