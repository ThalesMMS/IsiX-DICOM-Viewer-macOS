#!/usr/bin/env python3
"""Run host finalization: peer aborts log quietly; other failures show notices.

The DCMTK adapter's association ends as before (release acknowledged, abort
noted, anything else closes the transport) and hands each failure, with a
message that names both AE titles, to the listener's host; the host, in
ListenerHost.swift, keeps a peer abort in the log and shows a notice for the
rest.
"""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.mm').read_text()
a = source.index('        if (result == DUL_PEERREQUESTEDRELEASE) {', source.index('void handleAssociation()'))
b = source.index('        database_.reset();', a)
finalize = source[a:b]
a = source.index('    void notifyDIMSEError(')
b = source.index('    void notifyAssociationRequest(', a)
report = source[a:b].replace(' override', '')
code = r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <cstring>
#include <initializer_list>
struct OFCondition {
 int value; bool bad()const{return value!=0;} int module()const{return 6;} int code()const{return value;}
 const char*text()const{return value==0?"Normal":value==1?"Peer release":value==2?"Peer abort":value==3?"Invalid PDU":"Timeout";}
 bool operator==(OFCondition rhs)const{return value==rhs.value;}
 bool operator!=(OFCondition rhs)const{return value!=rhs.value;}
};
const OFCondition EC_Normal{0},DUL_PEERREQUESTEDRELEASE{1},DUL_PEERABORTEDASSOCIATION{2};
struct Parameters {struct {char callingAPTitle[65]="SENDER",calledAPTitle[65]="RECEIVER";} DULparams;};
struct T_ASC_Association {Parameters*params;};
static OFCondition cleanup{0};static int closes=0,releases=0,aborts=0;
static NSString *message=nil;static NSError *reported=nil;
NSError *IsiXDCMTKErrorFromCondition(const OFCondition& condition)
{ return [NSError errorWithDomain:@"test" code:condition.value userInfo:nil]; }
@interface Host : NSObject
-(void)associationEndedWithError:(NSError*)error message:(NSString*)value;
@end
@implementation Host
-(void)associationEndedWithError:(NSError*)error message:(NSString*)value{reported=error;message=value;}
@end
struct Listener {Host*host;};
OFCondition ASC_acknowledgeRelease(T_ASC_Association*){releases++;return cleanup;}
void ASC_closeTransportConnection(T_ASC_Association*){closes++;}
struct DcmSCP {void notifyDIMSEError(const OFCondition&){};};
struct Worker:DcmSCP {
 T_ASC_Association*association_;Listener listener_{[Host new]};bool cancel=false;
 bool cancelled()const{return cancel;}
 void notifyReleaseRequest(){}void notifyAbortRequest(){aborts++;}
 REPORT
 OFCondition finish(OFCondition result){FINALIZE return result;}
};
int main(){@autoreleasepool{
 Parameters parameters;T_ASC_Association association{&parameters};
 for(int failure:{2,3,4})for(int cleanupFailure:{0,4}){
  Worker worker;worker.association_=&association;cleanup={cleanupFailure};closes=aborts=releases=0;message=nil;reported=nil;
  assert(worker.finish({failure}).value==failure);assert(reported.code==failure);
  assert([message containsString:@"SENDER"] && [message containsString:@"RECEIVER"]);
  assert([message containsString:[NSString stringWithUTF8String:OFCondition{failure}.text()]]);
  assert(![message containsString:@"Normal"]);assert(closes==(failure==2?0:1));assert(aborts==(failure==2?1:0));
  if(failure==2)fprintf(stderr,"%s\n",message.UTF8String);
 }
 Worker worker;worker.association_=&association;message=nil;cleanup=EC_Normal;releases=closes=0;
 assert(worker.finish(DUL_PEERREQUESTEDRELEASE).value==0);assert(message==nil);assert(releases==1&&closes==0);
 cleanup={4};message=nil;assert(worker.finish(DUL_PEERREQUESTEDRELEASE).value==4);assert(reported.code==4&&message!=nil);
 worker.cancel=true;message=nil;assert(worker.finish(EC_Normal).value==0);assert(message==nil);assert(closes==1);
 puts("PASS: each DIMSE failure reaches the host naming both AEs; release and cancellation retain their semantics");
}}
'''.replace('REPORT', report).replace('FINALIZE', finalize)
with tempfile.TemporaryDirectory(prefix='horos-listener-result-') as folder:
    folder = Path(folder)
    (folder / 'test.mm').write_text(code)
    subprocess.run(['xcrun', 'clang++', '-std=c++11', '-fobjc-arc', '-framework', 'Foundation', str(folder / 'test.mm'),
                    '-o', str(folder / 'test')], check=True)
    result = subprocess.run([str(folder / 'test')], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr)
    assert 'DICOM association from SENDER to RECEIVER ended: 0006:0002 Peer abort' in result.stderr
    print(result.stdout, end='')

# The host: a peer abort stays in the log, without a notice on the receiving
# Mac; any other failure opens one.
host = (root / 'Horos/Sources/ListenerHost.swift').read_text()
ended = host[host.index('func associationEndedWithError('):]
ended = ended[:ended.index('\n    }\n')]
assert re.search(r'if IsiXDCMTKError\.kind\(ofError: error\) == \.peerAbortedAssociation \{\s*NSLog\("%@", message\)\s*return\s*\}'
                 r'\s*DCMTKQueryRetrieveSCP\.displayListenerError\(message\)', ended), ended
print('PASS: the host keeps a peer abort in the log and shows a notice for other failures')

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
