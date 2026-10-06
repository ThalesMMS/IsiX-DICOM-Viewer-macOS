#!/usr/bin/env python3
"""Execute the production pane-loading preflight against failing resources.

PreferencesWindowController is Swift. The preflight of its
-setCurrentContext: is cut from the Swift source and compiled into a probe
controller; the pane, the context and the alert are Objective-C fixtures, so a
pane initializer or nib that raises raises an NSException, as in the app, and
the preflight has to catch it through HorosObjCException.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources  # noqa: E402

s = sources.source_text('PreferencesWindowController')
a = s.index('if currentContextStorage == nil || ', s.index('func setCurrentContext(_ context: PreferencesWindowContext?)'))
a = s.index('{', a) + 1; b = s.index('// remove old view', a)
body = s[a:b]
assert 'NSAlert' in body and 'HorosObjCException.perform' in body, 'the preflight no longer reports through NSAlert inside HorosObjCException'
body = body.replace('NSAlert', 'ProbeAlert')

fixtures_h = r'''
#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>
#import "HorosObjCException.h"
int ProbeAlertCount(void);
@interface ProbeAlert:NSObject
@property(copy) NSString *messageText,*informativeText;
- (void)addButtonWithTitle:(NSString*)title;
- (void)beginSheetModalForWindow:(NSWindow*)window completionHandler:(id)handler;
@end
@interface TestPane:NSPreferencePane
@property int mode;
@end
@interface PreferencesWindowContext:NSObject
@property(nonatomic,retain) NSPreferencePane *pane;
@property(copy) NSString *title,*resourceName;
@property BOOL failInitializer;
@end
'''
fixtures_m = r'''
#import "fixtures.h"
static int alerts;
int ProbeAlertCount(void) { return alerts; }
@implementation ProbeAlert
- (void)addButtonWithTitle:(NSString*)title {}
- (void)beginSheetModalForWindow:(NSWindow*)window completionHandler:(id)handler { alerts++; NSCAssert(self.messageText.length && self.informativeText.length,@"visible diagnosis"); }
@end
@implementation TestPane
- (NSView*)loadMainView {
 if(self.mode==1)[NSException raise:@"MissingNib" format:@"fixture"];
 if(self.mode==2)return nil;
 self.mainView=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,100,100)] autorelease];return self.mainView;
}
@end
@implementation PreferencesWindowContext
@synthesize pane=_pane;
- (NSPreferencePane*)pane { if(self.failInitializer)[NSException raise:@"ConstructorFailure" format:@"fixture"]; return _pane; }
@end
'''
header = r'''
import AppKit
import PreferencePanes

final class TestController: NSObject {
 var window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
 var commits = 0
 func setCurrentContext(_ context: PreferencesWindowContext?) {
'''
footer = r'''
  commits += 1
  didChangeValue(forKey: "currentContext")
 }
}
_ = NSApplication.shared
let c = TestController()
for mode in 1...4 {
 let x = PreferencesWindowContext(); x.title = "fixture"; x.resourceName = "missing"
 let p = TestPane(bundle: Bundle.main); p.mode = Int32(mode); x.pane = mode == 4 ? nil : p; x.failInitializer = mode == 3
 c.setCurrentContext(x); precondition(c.commits == 0 && ProbeAlertCount() == mode, "failed pane must report and preserve current context")
}
let valid = PreferencesWindowContext(); valid.pane = TestPane(bundle: Bundle.main)
c.setCurrentContext(valid); precondition(c.commits == 1 && ProbeAlertCount() == 4, "valid pane switches")
c.setCurrentContext(nil); precondition(c.commits == 2 && ProbeAlertCount() == 4, "Show All remains available")
print("ok: initializer exception, missing nib, nil view and nil pane preserve prior content and report errors")
'''
with tempfile.TemporaryDirectory() as d:
 p = Path(d)
 (p/'fixtures.h').write_text(fixtures_h); (p/'fixtures.m').write_text(fixtures_m)
 (p/'main.swift').write_text(header + body + footer)
 for source, obj, arc in ((p/'fixtures.m', p/'fixtures.o', '-fno-objc-arc'),
                          (root/'Horos/Sources/HorosObjCException.m', p/'HorosObjCException.o', '-fno-objc-arc')):
  subprocess.run(['xcrun', 'clang', '-c', arc, '-Wno-objc-property-implementation', '-I', str(root/'Horos/Sources'),
                  str(source), '-o', str(obj)], check=True)
 subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(p/'fixtures.h'), '-I', str(root/'Horos/Sources'),
                 str(p/'main.swift'), str(p/'fixtures.o'), str(p/'HorosObjCException.o'),
                 '-framework', 'Cocoa', '-framework', 'PreferencePanes', '-o', str(p/'test')], check=True)
 subprocess.run([str(p/'test')], check=True)
