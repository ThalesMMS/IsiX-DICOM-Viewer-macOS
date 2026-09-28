#!/usr/bin/env python3
"""Execute the actual generated print script with controlled DCMTK executables."""
from pathlib import Path
import os
import subprocess
import tempfile
import sys
import argparse
from sources import source_text
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--real-tools',type=Path,help='Optional DCMTK resource directory for a missing-configuration failure check')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
# AYDicomPrintWindowController is Swift since #717: the script is built by the
# app's own statements, with Bundle.main.resourcePath standing for the
# resources folder given to the test (the former test's #define NSBundle).
source=source_text('AYDicomPrintWindowController')
start=source.index('                let printScript = NSMutableString()')
prefix=source[start:source.index('                let ipp =',start)]
start=source.index('                    // i <= ([images count] - 1) / ipp')
end=source.index('                    if (try? loggerConfig.write(',start)
commands=source[start:end]
constants=source[source.index('// MARK: Tables'):source.index('// MARK: End of tables')]
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
    raise SystemExit(23 if count==int(os.environ.get('QA_FAIL_PREPARE_AT','0')) else 0)
assert sys.argv[sys.argv.index('--medium-type')+1] == 'BLUE FILM', sys.argv
assert sys.argv[-1].endswith('/database/SP_*'), sys.argv
raise SystemExit(int(os.environ.get('QA_SEND_STATUS','0')))
'''
    for name in ['dcmpsprt','dcmprscu']:
        tool=binaries/name;tool.write_text(mock);tool.chmod(0o700)
    for name,fail,send,expected,sequence in [
        ('first-page-fails',1,0,23,['dcmpsprt']),
        ('second-page-fails',2,0,23,['dcmpsprt','dcmpsprt']),
        ('printer-refuses',0,41,41,['dcmpsprt','dcmpsprt','dcmprscu']),
        ('success',0,0,0,['dcmpsprt','dcmpsprt','dcmprscu'])]:
        job=p/name;job.mkdir();logs=p/(name+' logs');logs.mkdir()
        subprocess.run([str(p/'generate'),str(binaries),str(job),str(logs)],check=True)
        env=os.environ.copy();env.update(QA_TRACE=str(job/'calls'),QA_FAIL_PREPARE_AT=str(fail),QA_SEND_STATUS=str(send))
        result=subprocess.run(['/bin/bash',str(job/'print.sh')],env=env,capture_output=True,text=True)
        assert result.returncode==expected,(name,result.returncode,result.stderr)
        assert (job/'calls').read_text().splitlines()==sequence,name
        text=(logs/'print.log').read_text()
        assert ('End print job' in text)==(expected==0),name
        print('PASS:',name)
    if args.real_tools:
        job=p/'real-missing-config';job.mkdir();logs=p/'real-logs';logs.mkdir()
        subprocess.run([str(p/'generate'),str(args.real_tools.resolve()),str(job),str(logs)],check=True)
        result=subprocess.run(['/bin/bash',str(job/'print.sh')],capture_output=True,text=True)
        assert result.returncode != 0, 'Real dcmpsprt failure was hidden'
        assert 'End print job' not in (logs/'print.log').read_text()
        print('PASS: real DCMTK missing configuration propagates failure, status',result.returncode)
