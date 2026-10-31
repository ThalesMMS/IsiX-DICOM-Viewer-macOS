#!/usr/bin/env python3
"""Exercise the production screen-change filter with controlled display snapshots.

-[AppController updateScreenParameters] forwards to ViewerWindowArranger, whose
updateScreenParameters() is compiled with swiftc, with ViewerTilingLayout
(IsiXImaging), over Foundation-only stand-ins for NSScreen and the browser.
An argument (a revision) reads that revision's ViewerWindowArranger.swift.
"""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
def read(path):
 return subprocess.check_output(['git','-C',str(root),'show',sys.argv[1]+':'+path]).decode('utf-8') if len(sys.argv)>1 else (root/path).read_bytes().decode('utf-8')
s=read('Horos/Sources/ViewerWindowArranger.swift')
layout=read('Modules/IsiXImaging/Sources/ViewerWorkspace/ViewerTilingLayout.swift')
a=s.index('    private struct ScreenParameters: Equatable {');method=s[a:s.index('    /// A series list panel for each screen',a)]
code=r'''
import Foundation
var snapshot:[NSScreen]=[]
var closes=0,resets=0,recoveries=0
func check(_ c:Bool,_ what:String,line:Int = #line){if !c{print("FAIL: \(what) at line \(line) (resets=\(resets) recoveries=\(recoveries) closes=\(closes))");exit(1)}}
struct NSDeviceDescriptionKey:Hashable{let rawValue:String;init(_ rawValue:String){self.rawValue=rawValue}}
final class NSScreen:NSObject{
 var frame=NSZeroRect,visibleFrame=NSZeroRect
 var deviceDescription:[NSDeviceDescriptionKey:Any]=[:]
 class var screens:[NSScreen]{return snapshot}
}
final class BrowserController:NSObject{
 static let browser=BrowserController()
 class func currentBrowser()->BrowserController?{return browser}
 func recoverWindowsAfterScreenChange(){recoveries+=1}
}
struct ProcessGraph{var currentBrowser:BrowserController?{BrowserController.currentBrowser()}}
final class ViewerWindowArranger:NSObject{
 let processGraph=ProcessGraph()
 private var previousScreenParameters: [ScreenParameters]? = nil
 private var previousScreenOrder: [UInt32]? = nil
 static let app=ViewerWindowArranger()
 class func shared()->ViewerWindowArranger?{return app}
 func resetThumbnailsLists(){resets+=1}
 func closeAllViewers(_ sender:Any!){closes+=1}
METHOD
}
func display(_ identifier:Int,_ rect:NSRect)->NSScreen{let s=NSScreen();s.frame=rect;s.visibleFrame=rect;s.deviceDescription=[NSDeviceDescriptionKey("NSScreenNumber"):NSNumber(value:identifier)];return s}
let app=ViewerWindowArranger.shared()!
let a=display(1,NSMakeRect(0,0,1440,900)),b=display(2,NSMakeRect(-1920,0,1920,1080))
snapshot=[a,b];app.updateScreenParameters();check(resets==1 && recoveries==1 && closes==0,"initial snapshot")
app.updateScreenParameters();check(resets==1 && recoveries==1,"duplicate snapshot")
for i in 0..<50{snapshot=i%2 != 0 ? [a,b]:[b,a];app.updateScreenParameters()}
check(resets==51 && recoveries==51 && closes==0,"reordered snapshots")
snapshot=[];app.updateScreenParameters();check(resets==51 && recoveries==51 && closes==0,"empty snapshot")
snapshot=[a,display(2,NSZeroRect)];app.updateScreenParameters();check(resets==51 && recoveries==51 && closes==0,"empty frame")
snapshot=[a,display(2,NSMakeRect(CGFloat.nan,0,1920,1080))];app.updateScreenParameters();check(resets==51 && recoveries==51 && closes==0,"NaN frame")
snapshot=[a,b];app.updateScreenParameters();check(resets==51 && recoveries==51 && closes==0,"same snapshot after invalid ones")
b.frame=NSMakeRect(-1920,0,1600,900);app.updateScreenParameters();check(resets==51 && recoveries==52 && closes==0,"frame change")
b.visibleFrame=NSMakeRect(-1920,24,1600,876);app.updateScreenParameters();check(resets==51 && recoveries==53 && closes==0,"visible frame change")
snapshot=[display(3,b.frame),a];app.updateScreenParameters();check(resets==52 && recoveries==54 && closes==0,"display replacement")
print("PASS: initial/duplicate/reordered/empty/invalid/geometry snapshots; real display replacement preserves viewers")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-screen-notifications-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(code);(p/'ViewerTilingLayout.swift').write_text(layout)
 subprocess.run(['xcrun','swiftc','-module-name','ScreenNotifications',str(p/'main.swift'),str(p/'ViewerTilingLayout.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
