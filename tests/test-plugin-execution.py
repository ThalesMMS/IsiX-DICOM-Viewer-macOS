#!/usr/bin/env python3
"""Execute the database plugin dispatch method with controlled plugin failures.

The browser's -executeFilterFromString: is Swift, in
BrowserController+Plugins.swift. The method and the file's helpers (objcTry,
objcSendLong...) are compiled as they are with xcrun swiftc, inside a double
of BrowserController, with HorosObjCException, an Objective-C filter that
fails as asked, and doubles of PluginManager, HorosAlertPanel and the
exception log. `--viewer` runs the same scenario on the viewer's
-executeFilterFromString: and -executeFilterFromBundle:title:, Swift too
(ViewerController+Resampling.swift, with the helpers of
ViewerController+ImagePipelineSupport.swift), in a double of ViewerController:
the viewer refreshes its ROIs only after a filter that did not fail by its code.
`--source` reads the method from another file (the negative control).
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path  # noqa: E402
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source',type=Path)
parser.add_argument('--viewer',action='store_true')
args=parser.parse_args()
source=args.source or source_path('ViewerController+Resampling' if args.viewer else 'BrowserController+Plugins')
s=source.read_bytes().decode('latin1' if source.suffix!='.swift' else 'utf-8')

SWIFT_DOUBLES=r'''
import AppKit

var depth=0
var lastAlert: String?
let registry=NSMutableDictionary()

final class PluginManager: NSObject {
    static func plugins() -> NSMutableDictionary? { return registry }
    static func startProtectForCrash(withFilter filter: Any!) { depth+=1 }
    static func endProtectForCrash() { depth-=1 }
}

enum HorosAlertPanel {
    @discardableResult
    static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        lastAlert=message
        return 1
    }
}

func _N2LogExceptionImpl(_ e: NSException!, _ logStack: Bool, _ pf: UnsafePointer<CChar>!) {}

HELPERS

final class BrowserController: NSObject {
METHOD
}

@main
struct Main {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        let browser=BrowserController()
        browser.executeFilter(from: "Absent")
        check(depth==0 && processed==0 && lastAlert != nil, "Missing plugin must be explained")
        registry["QA"]=Filter()
        prepareCode=42; lastAlert=nil
        browser.executeFilter(from: "QA")
        check(processed==0 && depth==0, "Preparation failure must prevent processing and clear marker")
        check(lastAlert?.contains("preparation")==true && lastAlert?.contains("42")==true, "Preparation error needs phase and code")
        prepareCode=0; throwPrepare=true; lastAlert=nil
        browser.executeFilter(from: "QA")
        check(processed==0 && depth==0 && lastAlert?.contains("SyntheticPreparation")==true, "Preparation exception must be caught and marker cleared")
        throwPrepare=false; processCode=7; lastAlert=nil
        browser.executeFilter(from: "QA")
        check(processed==1 && depth==0 && lastAlert?.contains("processing")==true && lastAlert?.contains("7")==true, "Processing status must not be ignored")
        processCode=0; throwProcess=true; lastAlert=nil
        browser.executeFilter(from: "QA")
        check(processed==2 && depth==0 && lastAlert?.contains("SyntheticProcessing")==true, "Processing exception must clear marker")
        throwProcess=false; lastAlert=nil
        browser.executeFilter(from: "QA")
        check(processed==3 && depth==0 && lastAlert==nil, "Successful filter must execute normally")
        print("PASS: missing filter, prepare failure/exception, processing failure/exception, success and crash-marker cleanup")
    }
}
'''

FILTER_HEADER=r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
extern int processed, prepared;
extern long prepareCode, processCode;
extern BOOL throwPrepare, throwProcess;
@interface Filter:NSObject
- (long)prepareFilter:(id)viewer;
- (long)filterImage:(NSString*)name;
@end
'''

FILTER=r'''
#import "harness.h"
int processed, prepared;
long prepareCode, processCode;
BOOL throwPrepare, throwProcess;
@implementation Filter
- (long)prepareFilter:(id)viewer {prepared++;if(throwPrepare) [NSException raise:@"SyntheticPreparation" format:@"Missing synthetic dependency"];return prepareCode;}
- (long)filterImage:(NSString*)name {processed++;if(throwProcess) [NSException raise:@"SyntheticProcessing" format:@"Synthetic processing failure"];return processCode;}
@end
'''

VIEWER_DOUBLES=r'''
var roiSets=0
enum AppController { static func willExecutePlugin(_ filter: Any?) -> Bool { return true } }
extension Notification.Name { static let OsirixRecomputeROI = Notification.Name("OsirixRecomputeROINotification") }
final class ImageView { func stopROIEditingForce(_ force: Bool) {}; func roiSet() { roiSets+=1 } }
'''

if args.viewer:
    support=source_path('ViewerController+ImagePipelineSupport').read_text()
    helpers=VIEWER_DOUBLES+support[support.index('/// Runs `body` as an @try block'):support.index('/// -[DCMPix setArrayPix::]')]
    a=s.index('    @objc(executeFilterFromString:)')
    method=s[a:s.index('    @objc(executeFilter:)',a)]
    program=SWIFT_DOUBLES.replace('final class BrowserController: NSObject {\nMETHOD\n}',
        'final class ViewerController: NSObject {\n    let horos_imageView: ImageView? = ImageView()\n'
        '    func checkEverythingLoaded() {}\n    func computeInterval() -> Float { return 0 }\nMETHOD\n}')
    program=program.replace('let browser=BrowserController()','let browser=ViewerController()').replace(
        '        print("PASS:', '        check(roiSets==2, "The viewer refreshes its ROIs after a filter that ran, not after a failure code")\n        print("PASS: viewer:')
else:
    helpers=s[s.index('/// `@synchronized (object)'):s.index('public extension BrowserController {')]
    a=s.index('    @objc(executeFilterFromString:)')
    method=s[a:s.index('    @objc(executeFilterDB:)',a)]
    program=SWIFT_DOUBLES
with tempfile.TemporaryDirectory(prefix='horos-plugin-execution-') as directory:
    p=Path(directory)
    for name in ('HorosObjCException.h','HorosObjCException.m'):
        shutil.copy(root/'Horos/Sources'/name,p/name)
    (p/'harness.h').write_text(FILTER_HEADER)
    (p/'filter.m').write_text(FILTER)
    (p/'main.swift').write_text(program.replace('HELPERS',helpers).replace('METHOD',method))
    for name in ('HorosObjCException','filter'):
        subprocess.run(['xcrun','clang','-x','objective-c','-fobjc-arc','-fobjc-exceptions','-iquote',str(p),'-c',str(p/(name+'.m')),'-o',str(p/(name+'.o'))],check=True)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-import-objc-header',str(p/'harness.h'),'-Xcc','-iquote','-Xcc',str(p),
                    str(p/'main.swift'),str(p/'HorosObjCException.o'),str(p/'filter.o'),'-framework','AppKit','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True,timeout=30)
