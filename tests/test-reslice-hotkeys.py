#!/usr/bin/env python3
"""Execute the real preference loading/saving and reslice dispatch with controlled focus/events.

The Hot Keys pane is Swift since #711: OSIHotKeysPref.swift (with the
HotKeyArrayController its outlet names) is compiled into a library, and the
harness drives the pane's own -mainViewDidLoad, -setKey: and -shouldUnselect
on an instance made without its nib, with preferences held in memory.

The reslice dispatch of -[DCMView actionForHotKey:] is Swift since #834
(DCMView+HotKeys.swift): its case is extracted and compiled with swiftc into a
stand-in view that has the members it uses (NSApp's current event, the window,
the window controller), and driven from the same checks.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
sys.path.insert(0, str(root / 'tools'))
from sources import source_path, source_text  # noqa: E402
import object_probe  # noqa: E402

read = lambda p: (root / p).read_text()
header = read('Horos/Sources/DefaultsOsiriX.h')
enum = header[header.index('enum HotKeyActions'):header.index(';', header.index('enum HotKeyActions')) + 1]
view = source_text('DCMView+HotKeys')
defaults = read('Horos/Sources/DefaultsOsiriX.m')


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


actionForHotKey = between(view, '    @objc(actionForHotKey:)', '    @objc(')
# The case reads the window controller the switch declares for every case.
if '                let windowController = self.windowController() as AnyObject?\n' not in actionForHotKey:
    raise SystemExit('FAIL: actionForHotKey: no longer sends the reslice to its window controller')
dispatch = between(actionForHotKey, '                case ResliceAxialHotKeyAction.rawValue,',
                   '                case SetKeyImageAction.rawValue:')
default_keys = between(defaults, '\t//hot key prefs', '\n\tNSArray *compressionSettings')

code = r'''
#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>
ENUM
@class Application;
static Application *application;
// Preferences in memory: the pane reads and writes NSUserDefaults.standardUserDefaults.
@interface ProbeDefaults : NSUserDefaults
@property (retain) NSMutableDictionary *stored;
@end
@implementation ProbeDefaults
- (id)objectForKey:(NSString *)key { return _stored[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { if (value) _stored[key] = value; else [_stored removeObjectForKey:key]; }
- (void)removeObjectForKey:(NSString *)key { [_stored removeObjectForKey:key]; }
- (BOOL)synchronize { return YES; }
@end
static ProbeDefaults *defaults;
static id standardDefaults(id self, SEL _cmd) { return defaults; }
// The Swift pane's selectors.
@protocol HotKeysPane
-(void)mainViewDidLoad;
-(NSArray *)actions;
-(void)setKey:(NSString *)key;
-(NSInteger)shouldUnselect;
@end
typedef NSObject<HotKeysPane> Pane;
// Without -initWithBundle:, which loads the pane's nib: the methods driven here
// use only the pane's own properties, nil in a new instance.
static Pane *newPane(void) { return class_createInstance(objc_getClass("OSIHotKeysPref"), 0); }
// The Swift stand-ins of dispatch.swift, reached by name.
@interface Window : NSObject
@property BOOL isKeyWindow;
@property(assign) id firstResponder;
@end
@interface Application : NSObject
+(instancetype)shared;
@property(retain) NSEvent *currentEvent;
@end
@interface Controller : NSObject
@property NSInteger calls, requestedOrientation;
@end
@interface View : NSObject
@property BOOL is2DViewer;
@property(retain) Window *window;
@property(retain) Controller *windowController;
-(BOOL)dispatch:(int)key;
@end
static id instance(const char *name) { return [[objc_getClass(name) alloc] init]; }
static NSEvent *event(NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
        timestamp:0 windowNumber:0 context:nil characters:@"f" charactersIgnoringModifiers:@"f"
        isARepeat:NO keyCode:3];
}
#define check(...) do { if(!(__VA_ARGS__)) { NSLog(@"FAIL %s",#__VA_ARGS__); return 1; } } while(0)
int main() { @autoreleasepool {
    defaults=[ProbeDefaults new]; defaults.stored=[NSMutableDictionary dictionary];
    method_setImplementation(class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults)), (IMP)standardDefaults);
    check(objc_getClass("OSIHotKeysPref") != nil);
    NSMutableDictionary *storage=defaults.stored;
    // The production methods need defaults' objectForKey:/setObject:forKey: only.
    NSMutableDictionary *defaultValues=[NSMutableDictionary dictionary];
DEFAULTS
    check(SetKeyImageAction==52 && ResliceAxialHotKeyAction==53 && ResliceSagittalHotKeyAction==55);
    check(![[defaultValues objectForKey:@"HOTKEYS"] objectForKey:@""]);
    check([[[defaultValues objectForKey:@"HOTKEYS"] objectForKey:@"l"] intValue]==LengthHotKeyAction);
    [storage addEntriesFromDictionary:defaultValues];
    Pane *p=newPane(); [p mainViewDidLoad];
    check([p actions].count==56);
    for(int i=53;i<56;i++) check(![[p actions][i] objectForKey:@"key"]);
    check([[[p actions][53] objectForKey:@"action"] isEqual:@"Reslice Axial"]);
    NSArrayController *controller=[[objc_getClass("HotKeyArrayController") alloc] initWithContent:[p actions]];
    [p setValue:controller forKey:@"arrayController"];
    NSArray *keys=@[@"f",@"g",@"j"];
    for(int i=0;i<3;i++) { [controller setSelectionIndex:53+i]; [p setKey:keys[i]]; }
    [p shouldUnselect];
    Pane *reloaded=newPane(); [reloaded mainViewDidLoad];
    for(int i=0;i<3;i++) check([[[reloaded actions][53+i] objectForKey:@"key"] isEqual:keys[i]]);
    // Existing assignments remain intact; conflicts and removal use the real pane.
    check([[[storage objectForKey:@"HOTKEYS"] objectForKey:@"l"] intValue]==LengthHotKeyAction);
    [controller setSelectionIndex:53]; [p setKey:@"l"]; [p shouldUnselect];
    check([[[storage objectForKey:@"HOTKEYS"] objectForKey:@"l"] intValue]==53);
    check([[[p actions][LengthHotKeyAction] objectForKey:@"key"] length]==0);
    [p setKey:@""]; [p shouldUnselect]; check(![[storage objectForKey:@"HOTKEYS"] objectForKey:@"l"]);
    View *v=instance("View"); v.is2DViewer=YES; v.window=instance("Window");
    v.window.isKeyWindow=YES; v.window.firstResponder=v; v.windowController=instance("Controller");
    application=[objc_getClass("Application") shared]; [application setCurrentEvent:event(0)];
    for(int i=0;i<3;i++) { check([v dispatch:53+i]); check(v.windowController.requestedOrientation==i); }
    NSInteger calls=v.windowController.calls;
    for(NSNumber *flag in @[@(NSEventModifierFlagCommand),@(NSEventModifierFlagControl),
                            @(NSEventModifierFlagOption),@(NSEventModifierFlagShift)]) {
        [application setCurrentEvent:event(flag.unsignedIntegerValue)]; check(![v dispatch:53]);
    }
    [application setCurrentEvent:nil]; check(![v dispatch:53]);
    [application setCurrentEvent:event(0)]; v.window.firstResponder=[NSObject new]; check(![v dispatch:53]);
    v.window.firstResponder=v; v.window.isKeyWindow=NO; check(![v dispatch:53]);
    v.window.isKeyWindow=YES; v.is2DViewer=NO; check(![v dispatch:53]);
    check(v.windowController.calls==calls);
    NSLog(@"PASS: persisted IDs, default keys, pane assignment/conflict/removal/reload, three planes and focus/modifier guards");
}}
'''
STANDINS = r'''
import Cocoa

// What the extracted case of -actionForHotKey: reaches, and nothing more: NSApp's
// current event, the view's window (key or not, and its first responder) and
// the window controller it asks for the orientation.
@objc(Application) final class ProbeApplication: NSObject {
    @objc static let shared = ProbeApplication()
    @objc var currentEvent: NSEvent?
}
// The case asks NSApp; here it is the stand-in above.
let NSApp = ProbeApplication.shared

@objc(Window) final class ProbeWindow: NSObject {
    @objc var isKeyWindow = false
    @objc var firstResponder: AnyObject?
}

@objc(Controller) final class ProbeController: NSObject {
    @objc var calls = 0, requestedOrientation = 0
    @objc func setOrientation(_ value: Int32) -> Bool { calls += 1; requestedOrientation = Int(value); return true }
}

@objc(View) final class ProbeView: NSObject {
    private var twoD = false
    @objc(setIs2DViewer:) func setIs2DViewer(_ value: Bool) { twoD = value }
    @objc func is2DViewer() -> Bool { twoD }
    @objc var window: ProbeWindow?
    @objc(windowController) var controller: ProbeController?

    @objc(dispatch:) func dispatch(_ value: Int32) -> Bool {
        let key = unichar(truncatingIfNeeded: value)
        let windowController = self.controller as AnyObject?
        switch UInt32(key) {
DISPATCH
        default: return false
        }
        return true
    }
}
'''

for key, value in [('ENUM', enum), ('DEFAULTS', default_keys)]:
    code = code.replace(key, value)
with tempfile.TemporaryDirectory(prefix='horos-reslice-hotkeys-') as folder:
    p = Path(folder)
    pane = source_path('OSIHotKeysPref')
    bridging = p / 'bridging.h'
    bridging.write_text('#import <Cocoa/Cocoa.h>\n' + enum + '\n')
    (p / 'dispatch.swift').write_text(STANDINS.replace('DISPATCH', dispatch))
    # The pane's main-actor callbacks (#961).
    library = object_probe.swift_dylib([pane, pane.parent / 'HotKeyArrayController.swift', p / 'dispatch.swift',
                                        source_path('MainActorCallbacks')], [],
                                       p / 'libHotKeysPane.dylib',
                                       bridging_header=bridging, frameworks=('Cocoa', 'PreferencePanes'))
    (p/'test.m').write_text(code)
    object_probe.link_probe(p / 'test.m', [library], p / 'test', frameworks=('Cocoa', 'PreferencePanes'),
                            optimization='-O0')
    subprocess.run([str(p/'test')], check=True)
