#!/usr/bin/env python3
"""Execute the actual generated print script with controlled DCMTK executables,
then the app's own sending method on it: the alert names the failed step, the
print log gets the script's output and status, and a failed job keeps only its
print.cfg and that output."""
from pathlib import Path
import os
import subprocess
import tempfile
import sys
import argparse
import json
from sources import source_text
from isix_modules import module_flags
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--real-tools',type=Path,help='Optional DCMTK resource directory for a missing-configuration failure check')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
# AYDicomPrintWindowController is Swift: the script is built by the
# app's own statements, with Bundle.main.resourcePath standing for the
# resources folder given to the test (the former test's #define NSBundle).
source=source_text('AYDicomPrintWindowController')
start=source.index('                let printScript = NSMutableString()')
prefix=source[start:source.index('                let ipp =',start)]
start=source.index('                    // i <= ([images count] - 1) / ipp')
end=source.index('                    if (try? loggerConfig.write(',start)
commands=source[start:end]
constants=source[source.index('// MARK: Tables'):source.index('// MARK: End of tables')]
# The controller keeps the sentences and the print log; the reading of the
# script's output is IsiXDICOMNetwork's DICOMPrintJobFailure, which the
# stand-in program imports as the app does.
assert '\nimport IsiXDICOMNetwork\n' in source
outcome=source[source.index('// MARK: Print job outcome'):source.index('// MARK: End of print job outcome')]
log_directory='(NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/IsiXDicomPrint")'
assert outcome.count(log_directory)==1
outcome=outcome.replace(log_directory,'CommandLine.arguments[2]')
start=source.index('    /// Runs on the thread -_createPrintjobDCMTK starts')
method=source[start:source.index('    @objc(errorMessage:)',start)]
bash='URL(fileURLWithPath: "/bin/bash")'
assert method.count(bash)==1
method=method.replace(bash,'URL(fileURLWithPath: CommandLine.arguments[3])')
# The method as the app has it, on a stand-in controller that records alerts.
sender=r'''
import AppKit
import IsiXDICOMNetwork
let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException { static func perform(_ block: () -> Void) throws { block() } }
func _N2LogExceptionImpl(_ e: NSException, _ b: Bool, _ s: String) {}
CONSTANTS
OUTCOME
class AYDicomPrintWindowController: NSObject {
    private nonisolated let printing = NSLock()
    var alerts: [[String]] = []
METHOD
    @objc(errorMessage:) func errorMessage(_ msg: NSArray!) { alerts.append(msg.map { "\($0)" }) }
}
let controller = AYDicomPrintWindowController()
controller._sendPrintjobDCMTK(CommandLine.arguments[1])
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: controller.alerts))
'''.replace('CONSTANTS',constants).replace('OUTCOME',outcome).replace('METHOD',method)
program=r'''
import Foundation
CONSTANTS
let arguments=CommandLine.arguments
let resources=arguments[1]
let printJobDir=arguments[2]
let logPath=arguments[3]
let printJobID=NSMutableString(string:"synthetic QA")
let printConfigPath=(printJobDir as NSString).appendingPathComponent("print.cfg")
let loggerConfigPath=(printJobDir as NSString).appendingPathComponent("logger.cfg")
let columns:Int32=6, rows:Int32=4, ipp:Int32=24, copies:Int32=1
let filmSize=NSMutableString(string:"14INX17IN")
let dict:AnyObject?=["magnificationTypeTag":1,"configurationInformation":"","borderDensityTag":0,"emptyImageDensityTag":0,"trimTag":0,"filmOrientationTag":0,"priorityTag":1,"filmDestinationTag":0,"mediumTag":0] as NSDictionary
let images=NSMutableArray()
for i in 0..<25 { images.add((printJobDir as NSString).appendingPathComponent("image-\(i).dcm")) }
PREFIX
COMMANDS
if (try? printScript.write(toFile:(printJobDir as NSString).appendingPathComponent("print.sh"),atomically:true,encoding:String.Encoding.utf8.rawValue))==nil { exit(1) }
'''.replace('CONSTANTS',constants).replace('PREFIX',prefix).replace('COMMANDS',commands).replace('Bundle.main.resourcePath','resources')
with tempfile.TemporaryDirectory(prefix='horos-print-status-') as directory:
    p=Path(directory);(p/'main.swift').write_text(program)
    subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'generate')],check=True)
    (p/'sender.swift').write_text(sender)
    subprocess.run(['xcrun','swiftc',*module_flags('IsiXDICOMNetwork',p/'modules'),str(p/'sender.swift'),'-o',str(p/'send')],check=True)
    binaries=p/'mock tools';binaries.mkdir()
    mock='#!'+sys.executable+r'''
import os, sys
from pathlib import Path
name=Path(__file__).name
trace=Path(os.environ['QA_TRACE'])
previous=trace.read_text().splitlines() if trace.exists() else []
with trace.open('a') as f: f.write(name+'\n')
if name=='dcmpsprt':
    count=previous.count(name)+1
    if count==int(os.environ.get('QA_FAIL_PREPARE_AT','0')):
        print('dcmpsprt: error: synthetic layout failure',file=sys.stderr)
        raise SystemExit(23)
    raise SystemExit(0)
assert sys.argv[sys.argv.index('--medium-type')+1] == 'BLUE FILM', sys.argv
assert sys.argv[-1].endswith('/database/SP_*'), sys.argv
if os.environ.get('QA_SEND_LINE'): print(os.environ['QA_SEND_LINE'],file=sys.stderr)
raise SystemExit(int(os.environ.get('QA_SEND_STATUS','0')))
'''
    for name in ['dcmpsprt','HorosStoredPrint']:
        tool=binaries/name;tool.write_text(mock);tool.chmod(0o700)
    for name,fail,send,expected,sequence in [
        ('first-page-fails',1,0,23,['dcmpsprt']),
        ('second-page-fails',2,0,23,['dcmpsprt','dcmpsprt']),
        ('printer-refuses',0,41,41,['dcmpsprt','dcmpsprt','HorosStoredPrint']),
        ('success',0,0,0,['dcmpsprt','dcmpsprt','HorosStoredPrint'])]:
        job=p/name;job.mkdir();logs=p/(name+' logs');logs.mkdir()
        subprocess.run([str(p/'generate'),str(binaries),str(job),str(logs)],check=True)
        env=os.environ.copy();env.update(QA_TRACE=str(job/'calls'),QA_FAIL_PREPARE_AT=str(fail),QA_SEND_STATUS=str(send))
        result=subprocess.run(['/bin/bash',str(job/'print.sh')],env=env,capture_output=True,text=True)
        assert result.returncode==expected,(name,result.returncode,result.stderr)
        assert (job/'calls').read_text().splitlines()==sequence,name
        text=(logs/'print.log').read_text()
        # set -e still stops at the failing command; the EXIT trap logs the step and status.
        step='layout' if sequence[-1]=='dcmpsprt' else 'send'
        assert f'End print job synthetic QA [step={step} status={expected}]' in text,(name,text)
        assert result.stdout.splitlines()[-1]==f'IsiXPrintJob: step={step} status={expected}',(name,result.stdout)
        print('PASS:',name)

    # The app's sending method on the generated script: what the user is told,
    # what the print log gets, and what a failed job leaves for the user to send.
    refused='HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=job dimse=0xC600; batch stopped, no retry'
    warning='HorosStoredPrint: warning: page=1 operation=0 cleanup=0 release=1 accepted=1; the page was printed, only the cleanup after it failed'
    for name,fail,send,line,launcher,alert in [
        ('app-layout-fails',1,0,'','/bin/bash','The film pages could not be prepared for the printer (dcmpsprt).'),
        ('app-printer-refuses',0,1,refused,'/bin/bash','The printer refused the print job (DIMSE status 0xC600).'),
        ('app-printer-unreachable',0,1,'HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=connect; batch stopped, no retry','/bin/bash','The printer could not be reached, or it refused the connection.'),
        ('app-printer-settings',0,1,'HorosStoredPrint: cannot initialize printer','/bin/bash','The print job could not be set up with the settings of this printer.'),
        ('app-send-interrupted',0,1,'HorosStoredPrint: page=2 operation=1 cleanup=0 release=0 accepted=0 stage=job; batch stopped, no retry','/bin/bash','The print job stopped while it was being sent to the printer.'),
        ('app-script-does-not-start',0,0,'',str(p/'missing shell'),'The print script could not be started.'),
        ('app-accepted-cleanup-warning',0,0,warning,'/bin/bash',None),
        ('app-success',0,0,'','/bin/bash',None)]:
        job=p/'jobs'/('dicomPrint-'+name);job.mkdir(parents=True);logs=p/(name+' logs');logs.mkdir()
        subprocess.run([str(p/'generate'),str(binaries),str(job),str(logs)],check=True)
        # print.cfg holds the printer's address and film settings; the images
        # and Stored Prints carry the patient, and must not be kept.
        (job/'print.cfg').write_text('[PRINTSCP]\nAetitle = PRINTQA\nHostname = 127.0.0.1\n')
        (job/'image-0.dcm').write_text('PatientName=QA^Identifiable')
        (job/'SP_1').write_text('PatientName=QA^Identifiable')
        env=os.environ.copy();env.update(QA_TRACE=str(p/(name+' calls')),QA_FAIL_PREPARE_AT=str(fail),QA_SEND_STATUS=str(send),QA_SEND_LINE=line)
        result=subprocess.run([str(p/'send'),str(job),str(logs),launcher],env=env,capture_output=True,text=True,timeout=120)
        assert result.returncode==0,(name,result)
        alerts=json.loads(result.stdout)
        assert not job.exists(),name
        log=(logs/'print.log').read_text()
        kept=[x for x in logs.iterdir() if x.name.startswith('Failed print job ')]
        if alert is None:
            assert alerts==[] and kept==[],(name,alerts,kept)
            assert 'Print job '+name+' ended with exit status 0' in log,(name,log)
            if line: assert line in log,(name,log)
        else:
            assert len(alerts)==1 and alerts[0][0]=='Print failed' and alerts[0][2]=='OK',(name,alerts)
            message=alerts[0][1]
            assert message.startswith(alert+' Details are in print.log in '+str(logs)),(name,message)
            assert len(kept)==1 and '“'+kept[0].name+'”' in message,(name,message,kept)
            assert sorted(x.name for x in kept[0].iterdir())==['print-job.log','print.cfg'],name
            assert (kept[0]/'print.cfg').read_text().startswith('[PRINTSCP]'),name
            job_log=(kept[0]/'print-job.log').read_text()
            assert job_log in log,(name,job_log,log)
            for artifact in kept[0].iterdir(): assert 'Identifiable' not in artifact.read_text(),(name,artifact)
            if launcher=='/bin/bash':
                status=1 if send else 23
                assert 'Print job '+name+f' ended with exit status {status}' in job_log,(name,job_log)
                assert 'IsiXPrintJob: step='+('send' if send else 'layout')+f' status={status}' in job_log,(name,job_log)
                if line: assert line in job_log,(name,job_log)
                if fail: assert 'dcmpsprt: error: synthetic layout failure' in job_log,(name,job_log)
            else:
                assert 'Print job '+name+' could not start: ' in job_log,(name,job_log)
        print('PASS:',name)

    # Older folders of failed jobs do not pile up next to the print log.
    logs=p/'pruned logs';logs.mkdir()
    for index in range(12): (logs/f'Failed print job 2026-01-01 00-00-{index:02d}').mkdir()
    job=p/'jobs'/'dicomPrint-app-pruning';job.mkdir()
    subprocess.run([str(p/'generate'),str(binaries),str(job),str(logs)],check=True)
    env=os.environ.copy();env.update(QA_TRACE=str(p/'pruning calls'),QA_FAIL_PREPARE_AT='1')
    subprocess.run([str(p/'send'),str(job),str(logs),'/bin/bash'],env=env,check=True,capture_output=True,timeout=120)
    kept=sorted(x.name for x in logs.iterdir() if x.name.startswith('Failed print job '))
    assert len(kept)==10 and 'Failed print job 2026-01-01 00-00-02' not in kept and not kept[-1].startswith('Failed print job 2026-01-01'),kept
    print('PASS: only the newest failed jobs are kept')
    if args.real_tools:
        job=p/'real-missing-config';job.mkdir();logs=p/'real-logs';logs.mkdir()
        subprocess.run([str(p/'generate'),str(args.real_tools.resolve()),str(job),str(logs)],check=True)
        result=subprocess.run(['/bin/bash',str(job/'print.sh')],capture_output=True,text=True)
        assert result.returncode != 0, 'Real dcmpsprt failure was hidden'
        assert f'[step=layout status={result.returncode}]' in (logs/'print.log').read_text()
        print('PASS: real DCMTK missing configuration propagates failure, status',result.returncode)

    # Exercise the product's Swift batch controller through its public C boundary.
    # A successful release must not erase an operation failure, which stops the
    # batch without a retry. A page the printer accepted is printed: a failed
    # cleanup or release after it is a warning, and the next page is sent.
    helper=root/'DICOMPrint/Helper'
    mock_c=p/'bridge.c'
    mock_c.write_text(r'''
#include "HorosStoredPrintBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void *HorosStoredPrintOpen(const char *c,const char *l,const char *p,unsigned int n,const char *r,const char *d,const char *m) { return (void *)1; }
HorosStoredPrintResult HorosStoredPrintSend(void *c,const char *f) {
    FILE *trace=fopen(getenv("QA_TRACE"),"a"); fprintf(trace,"%s\n",f); fclose(trace);
    HorosStoredPrintResult result={0,0,0,1};
    if (!strcmp(f,"operation-fails")) { result.operationStatus=1; result.printAccepted=0; result.failedStage=HorosStoredPrintStageJob; result.dimseStatus=0xC600; }
    if (!strcmp(f,"connect-fails")) { result.operationStatus=1; result.printAccepted=0; result.failedStage=HorosStoredPrintStageConnect; }
    if (!strcmp(f,"cleanup-fails")) result.cleanupStatus=1;
    if (!strcmp(f,"release-fails")) result.releaseStatus=1;
    return result;
}
void HorosStoredPrintClose(void *c) {
    FILE *trace=fopen(getenv("QA_TRACE"),"a"); fprintf(trace,"close\n"); fclose(trace);
}
''')
    subprocess.run(['xcrun','clang','-I',str(helper),'-c',str(mock_c),'-o',str(p/'bridge.o')],check=True)
    subprocess.run(['xcrun','swiftc','-import-objc-header',str(helper/'HorosStoredPrintBridge.h'),
                    str(helper/'main.swift'),str(p/'bridge.o'),'-o',str(p/'batch')],check=True)
    config=p/'print.cfg';config.write_text('synthetic configuration for the controlled bridge')
    for first,expected in [('operation-fails',1),('connect-fails',1),('cleanup-fails',0),('release-fails',0),('success',0)]:
        trace=p/(first+'-batch-trace')
        result=subprocess.run([str(p/'batch'),'-c',str(config),'--printer','PRINTSCP',first,'page-two'],
                              env={**os.environ,'QA_TRACE':str(trace)},capture_output=True,text=True)
        assert result.returncode==expected,(first,result)
        assert trace.read_text().splitlines()==([first,'close'] if expected else [first,'page-two','close'])
        if first=='release-fails': assert result.stderr=='HorosStoredPrint: warning: page=1 operation=0 cleanup=0 release=1 accepted=1; the page was printed, only the cleanup after it failed\n',result.stderr
        if first=='cleanup-fails': assert result.stderr.startswith('HorosStoredPrint: warning: page=1 operation=0 cleanup=1 release=0 accepted=1;'),result.stderr
        if first=='operation-fails': assert result.stderr=='HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=job dimse=0xC600; batch stopped, no retry\n',result.stderr
        if first=='connect-fails': assert result.stderr=='HorosStoredPrint: page=1 operation=1 cleanup=0 release=0 accepted=0 stage=connect; batch stopped, no retry\n',result.stderr
        if first=='success': assert result.stderr=='',result.stderr
        print('PASS: Swift batch',first)
    result=subprocess.run([str(p/'batch'),'-c',str(config),'--printer','PRINTSCP'],capture_output=True,text=True)
    assert result.returncode==2 and 'no Stored Prints' in result.stderr
    print('PASS: Swift batch rejects an empty job list')
