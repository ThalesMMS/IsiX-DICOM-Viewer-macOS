#!/usr/bin/env python3
"""Exercise the production screen-change filter with controlled display snapshots.

AppController is Swift since #830: -updateScreenParameters is compiled with
swiftc over Foundation-only stand-ins for NSScreen and BrowserController.
"""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
from sources import source_path  # noqa: E402
path=str(source_path('AppController').relative_to(root))
s=(subprocess.check_output(['git','-C',str(root),'show',sys.argv[1]+':'+path]).decode('utf-8') if len(sys.argv)>1 else (root/path).read_bytes().decode('utf-8'))
a=s.index('    @objc public func updateScreenParameters() {');method=s[a:s.index('    @objc class func resetThumbnailsList()',a)]
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
@objc(AppController) final class AppController:NSObject{
 enum State{static var previousScreenParameters:NSArray?=nil,previousOrderedIdentifiers:NSArray?=nil}
 static let app=AppController()
 class func shared()->AppController?{return app}
 class func resetThumbnailsList(){resets+=1}
 func closeAllViewers(_ sender:Any!){closes+=1}
METHOD
}
func display(_ identifier:Int,_ rect:NSRect)->NSScreen{let s=NSScreen();s.frame=rect;s.visibleFrame=rect;s.deviceDescription=[NSDeviceDescriptionKey("NSScreenNumber"):NSNumber(value:identifier)];return s}
let app=AppController.shared()!
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
 p=Path(tmp);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-module-name','ScreenNotifications',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
