#!/usr/bin/env python3
"""Compile real selection methods with controlled AppKit window-order snapshots
(the Objective-C of ViewerController.m, or the Swift of
ViewerController+ViewerRegistry.swift that replaced it)."""
from pathlib import Path
import subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
def read(path):
    return (subprocess.check_output(['git','show',sys.argv[1]+':'+path]) if len(sys.argv)>1 else ((root/path).read_bytes() if (root/path).exists() else b''))
s=read('Horos/Sources/ViewerController.m').decode('latin1')
SWIFT='+ (ViewerController*) frontMostDisplayed2DViewerForScreen:' not in s
if SWIFT:
 # The selection is Swift: the process's ViewerRegistry (ViewerRegistry.swift)
 # chooses, and the class methods of ViewerController+ViewerRegistry.swift ask
 # it; the same checks run on both, over stand-ins of the same names.
 # Each method is taken by its own declaration, up to the brace that closes
 # its body, so the members declared next to it stay out of the stand-ins.
 def member(text,declaration):
  a=text.index(declaration);i=text.index('{',a);depth=0
  while True:
   depth+={'{':1,'}':-1}.get(text[i],0);i+=1
   if depth==0: return text[a:i]+'\n'
 r=read('Horos/Sources/ViewerController+ViewerRegistry.swift').decode()
 g=read('Horos/Sources/ViewerRegistry.swift').decode()
 selection=''.join(member(r,'    @objc('+selector+')\n') for selector in ('frontMostDisplayed2DViewerForScreen:','frontMostDisplayed2DViewer','isFrontMost2DViewer:'))
 chosen=member(g,'    @MainActor func frontMostDisplayedViewer(on screen: NSScreen?)')
 methods=selection+'}\nfinal class ViewerRegistry {\n'+chosen.replace('@MainActor func','func')+'}\nextension ViewerController {\n    nonisolated(unsafe) static let viewerRegistry = ViewerRegistry()\n'
else:
 a=s.index('+ (ViewerController*) frontMostDisplayed2DViewerForScreen:');b=s.index('+ (NSMutableArray*) get2DViewers',a)
 methods=s[a:b].replace('static ViewerController *cachedFrontMostDisplayed2DViewer = nil;','')
code=r'''
#import <Foundation/Foundation.h>
#define check(x) do{if(!(x)){NSLog(@"FAIL: %s",#x);exit(1);}}while(0)
@interface NSScreen:NSObject @end
@implementation NSScreen @end
@interface NSWindow:NSObject
@property id windowController;
@property id screen;
@property(getter=isVisible) BOOL visible;
@end
@implementation NSWindow @end
@interface TestApp:NSObject
@property NSArray *orderedWindows;
@property NSWindow *keyWindow;
@property NSWindow *mainWindow;
@end
@implementation TestApp @end
static TestApp *NSApp;
@interface ViewerController:NSObject
@property NSWindow *window;
@property BOOL windowWillClose;
+ (ViewerController*)frontMostDisplayed2DViewerForScreen:(NSScreen*)screen;
+ (ViewerController*)frontMostDisplayed2DViewer;
+ (BOOL)isFrontMost2DViewer:(NSWindow*)window;
@end
static NSMutableDictionary *cachedFrontMostDisplayed2DViewerForScreen;
static ViewerController *cachedFrontMostDisplayed2DViewer;
@implementation ViewerController
METHODS
@end
static ViewerController *make(id screen) { ViewerController *v=[ViewerController new];v.window=[NSWindow new];v.window.screen=screen;v.window.visible=YES;v.window.windowController=v;return v; }
int main(){@autoreleasepool{
 NSApp=[TestApp new];id a=[NSScreen new],b=[NSScreen new];
 ViewerController *first=make(a),*second=make(a),*third=make(b);
 NSWindow *panel=[NSWindow new];panel.visible=YES;panel.windowController=[NSObject new];
 NSApp.orderedWindows=@[panel,first.window,second.window,third.window];
 check([ViewerController frontMostDisplayed2DViewer]==first);
 check([ViewerController frontMostDisplayed2DViewerForScreen:a]==first);
 check([ViewerController frontMostDisplayed2DViewerForScreen:b]==third);
 NSApp.mainWindow=second.window;
 check([ViewerController frontMostDisplayed2DViewer]==second);
 NSApp.keyWindow=first.window;
 check([ViewerController frontMostDisplayed2DViewer]==first);
 NSApp.keyWindow=panel;
 check([ViewerController frontMostDisplayed2DViewer]==second);
 check([ViewerController frontMostDisplayed2DViewerForScreen:b]==third);
 NSApp.keyWindow=nil;NSApp.mainWindow=nil;
 // Reordering alone need not change the application's main window.
 NSApp.orderedWindows=@[panel,second.window,first.window,third.window];
 check([ViewerController frontMostDisplayed2DViewer]==second);
 check([ViewerController frontMostDisplayed2DViewerForScreen:a]==second);
 check(![ViewerController isFrontMost2DViewer:first.window]);
 check([ViewerController isFrontMost2DViewer:second.window]);
 second.window.visible=NO;
 check([ViewerController frontMostDisplayed2DViewer]==first);
 first.windowWillClose=YES;
 check([ViewerController frontMostDisplayed2DViewer]==third);
 check([ViewerController frontMostDisplayed2DViewerForScreen:a]==nil);
 first.windowWillClose=NO;first.window.screen=b;
 check([ViewerController frontMostDisplayed2DViewerForScreen:a]==nil);
 check([ViewerController frontMostDisplayed2DViewerForScreen:b]==first);
 NSApp.orderedWindows=@[panel];
 check([ViewerController frontMostDisplayed2DViewer]==nil);
 check(![ViewerController isFrontMost2DViewer:nil]);
 NSLog(@"PASS: live ordering, auxiliary windows, visibility, closing, moved screen, empty list and nil window");
}}
'''.replace('METHODS',methods)
swift_code=r'''
import Foundation
func check(_ x: Bool, _ line: Int = #line) { if !x { print("FAIL: line \(line)"); exit(1) } }
class NSScreen: NSObject {}
class NSWindow: NSObject {
    var windowController: AnyObject?
    var screen: NSScreen?
    var isVisible = false
}
final class TestApp {
    var orderedWindows: [NSWindow] = []
    var keyWindow: NSWindow?
    var mainWindow: NSWindow?
}
nonisolated(unsafe) let NSApp = TestApp()
class ViewerController: NSObject {
    var window: NSWindow?
    var closing = false
    func windowWillClose() -> Bool { closing }
}
extension ViewerController {
METHODS
}
func make(_ screen: NSScreen) -> ViewerController { let v = ViewerController(); v.window = NSWindow(); v.window!.screen = screen; v.window!.isVisible = true; v.window!.windowController = v; return v }
let a = NSScreen(), b = NSScreen()
let first = make(a), second = make(a), third = make(b)
let panel = NSWindow(); panel.isVisible = true; panel.windowController = NSObject()
NSApp.orderedWindows = [panel, first.window!, second.window!, third.window!]
check(ViewerController.frontMostDisplayed2DViewer() === first)
check(ViewerController.frontMostDisplayed2DViewer(for: a) === first)
check(ViewerController.frontMostDisplayed2DViewer(for: b) === third)
NSApp.mainWindow = second.window
check(ViewerController.frontMostDisplayed2DViewer() === second)
NSApp.keyWindow = first.window
check(ViewerController.frontMostDisplayed2DViewer() === first)
NSApp.keyWindow = panel
check(ViewerController.frontMostDisplayed2DViewer() === second)
check(ViewerController.frontMostDisplayed2DViewer(for: b) === third)
NSApp.keyWindow = nil; NSApp.mainWindow = nil
// Reordering alone need not change the application's main window.
NSApp.orderedWindows = [panel, second.window!, first.window!, third.window!]
check(ViewerController.frontMostDisplayed2DViewer() === second)
check(ViewerController.frontMostDisplayed2DViewer(for: a) === second)
check(!ViewerController.isFrontMost2DViewer(first.window))
check(ViewerController.isFrontMost2DViewer(second.window))
second.window!.isVisible = false
check(ViewerController.frontMostDisplayed2DViewer() === first)
first.closing = true
check(ViewerController.frontMostDisplayed2DViewer() === third)
check(ViewerController.frontMostDisplayed2DViewer(for: a) == nil)
first.closing = false; first.window!.screen = b
check(ViewerController.frontMostDisplayed2DViewer(for: a) == nil)
check(ViewerController.frontMostDisplayed2DViewer(for: b) === first)
NSApp.orderedWindows = [panel]
check(ViewerController.frontMostDisplayed2DViewer() == nil)
check(!ViewerController.isFrontMost2DViewer(nil))
print("PASS: live ordering, auxiliary windows, visibility, closing, moved screen, empty list and nil window")
'''.replace('METHODS',methods)
with tempfile.TemporaryDirectory(prefix='horos-front-viewer-') as d:
 p=Path(d)
 if SWIFT:
  (p/'main.swift').write_text(swift_code)
  subprocess.run(['xcrun','swiftc','-swift-version','6',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 else:
  (p/'test.m').write_text(code)
  subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
