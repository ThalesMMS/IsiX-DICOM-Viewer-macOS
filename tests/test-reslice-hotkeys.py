#!/usr/bin/env python3
"""Execute the real preference loading/saving and reslice dispatch with controlled focus/events.

The Hot Keys pane is Swift since #711: OSIHotKeysPref.swift (with the
HotKeyArrayController its outlet names) is compiled into a library, and the
harness drives the pane's own -mainViewDidLoad, -setKey: and -shouldUnselect
on an instance made without its nib, with preferences held in memory.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
sys.path.insert(0, str(root / 'tools'))
from sources import source_path  # noqa: E402
import object_probe  # noqa: E402

read = lambda p: (root / p).read_text()
header = read('Horos/Sources/DefaultsOsiriX.h')
enum = header[header.index('enum HotKeyActions'):header.index(';', header.index('enum HotKeyActions')) + 1]
view = read('Horos/Sources/DCMView.m')
defaults = read('Horos/Sources/DefaultsOsiriX.m')


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]


dispatch = between(view, '                case ResliceAxialHotKeyAction:', '                case SetKeyImageAction:')
default_keys = between(defaults, '\t//hot key prefs', '\n\tNSArray *compressionSettings')

code = r'''
#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>
ENUM
static id application;
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
#undef NSApp
#define NSApp application
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
@interface Window : NSObject
@property BOOL isKeyWindow;
@property(assign) id firstResponder;
@end
@implementation Window
@end
@interface Application : NSObject
@property(retain) NSEvent *currentEvent;
@end
@implementation Application
@end
@interface Controller : NSObject
@property NSInteger calls, requestedOrientation;
-(BOOL)setOrientation:(NSInteger)value;
@end
@implementation Controller
-(BOOL)setOrientation:(NSInteger)value { self.calls++; self.requestedOrientation=value; return YES; }
@end
@interface View : NSObject
@property BOOL is2DViewer;
@property(retain) Window *window;
@property(retain) Controller *windowController;
-(BOOL)dispatch:(int)key;
@end
@implementation View
-(BOOL)dispatch:(int)key {
    switch(key) {
DISPATCH
        default: return NO;
    }
    return YES;
}
@end
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
    View *v=[View new]; v.is2DViewer=YES; v.window=[Window new];
    v.window.isKeyWindow=YES; v.window.firstResponder=v; v.windowController=[Controller new];
    application=[Application new]; [application setCurrentEvent:event(0)];
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
for key, value in [('ENUM', enum), ('DISPATCH', dispatch), ('DEFAULTS', default_keys)]:
    code = code.replace(key, value)
with tempfile.TemporaryDirectory(prefix='horos-reslice-hotkeys-') as folder:
    p = Path(folder)
    pane = source_path('OSIHotKeysPref')
    bridging = p / 'bridging.h'
    bridging.write_text('#import <Cocoa/Cocoa.h>\n')
    library = object_probe.swift_dylib([pane, pane.parent / 'HotKeyArrayController.swift'], [], p / 'libHotKeysPane.dylib',
                                       bridging_header=bridging, frameworks=('Cocoa', 'PreferencePanes'))
    (p/'test.m').write_text(code)
    object_probe.link_probe(p / 'test.m', [library], p / 'test', frameworks=('Cocoa', 'PreferencePanes'),
                            optimization='-O0')
    subprocess.run([str(p/'test')], check=True)
