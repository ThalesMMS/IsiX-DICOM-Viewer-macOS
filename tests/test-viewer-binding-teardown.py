#!/usr/bin/env python3
"""File's Owner bindings must not outlive ViewerController, nor keep it alive.

HorosDetachAutounbinder used to call AppKit's retainBindingTargetAndUnbind,
which made the NSAutounbinder proxy retain the controller. The proxy is only
released by the controller's own dealloc, so no closed viewer was ever freed,
and with it went its views, their pixel lists and the Metal frames (measured
with the ObjC probe below: 0 of 12 owners freed, 12 of 12 without the call).
The probe now requires every owner to be freed while its nib objects and the
proxy outlive it, under NSZombieEnabled, so the proxy cannot reach it dead.

    python3 tests/test-viewer-binding-teardown.py
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
expected = {
    'self.thicknessInMm',
    'KeyImageCounter',
    'injectionDateTime',
    'self.windowsStateName',
}

# File's Owner is id="-2" in Viewer.xib and in ViewerPanels.xib, the viewer's
# sheets loaded on demand with the same owner. Those inbound bindings are what
# AppKit tears down through NSAutounbinder after the controller is already gone.
found = {}
for folder in (root / 'Horos/Resources/en.lproj', root / 'Horos/Resources/ja-JP.lproj'):
    keys = set()
    for xib in (folder / 'Viewer.xib', folder / 'ViewerPanels.xib'):
        keys |= set(re.findall(
            r'<binding destination="-2" name="[^"]+" keyPath="([^"]+)"', xib.read_text()))
    found[folder.name] = keys
    assert keys == expected, f'{folder}: {sorted(keys)} != {sorted(expected)}'

source = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
start = source.index('- (void)windowWillClose:(NSNotification *)notification')
body = source[start:source.index('\n- (void)windowDidMiniaturize:', start)]
teardown = body.find('HorosViewerBindingTeardown')
detach = body.find('HorosDetachAutounbinder')
autorelease = body.find('[self autorelease]')
assert teardown != -1, 'windowWillClose must unbind File\'s Owner before the controller can die'
assert detach != -1, 'windowWillClose must drop Autounbinder\'s File\'s Owner pointer'
assert autorelease != -1, 'windowWillClose still extra-releases the controller'
assert teardown < detach < autorelease, (
    'unbind, then detach Autounbinder, then [self autorelease]')
assert 'flagListPODComparatives' in body[teardown:], (
    'the programmatic defaults binding must be torn down with the nib ones')

helper = root / 'Horos/Sources/ViewerBindingTeardown.swift'
code = r'''
import AppKit
import ObjectiveC

final class Owner: NSWindowController {
    @objc dynamic var windowsStateName = "ws"
    @objc dynamic var KeyImageCounter = 0
    @objc dynamic var injectionDateTime = Date()
    @objc dynamic var thicknessInMm = "1 mm"
    @objc dynamic var flagListPODComparatives: NSNumber = 1
    @objc var nameField: NSTextField?
    @objc var keyField: NSTextField?
    @objc var thickField: NSTextField?
    @objc var picker: NSDatePicker?
}

func autounbinder(of owner: NSObject) -> NSObject? {
    let sel = NSSelectorFromString("_autounbinder")
    guard owner.responds(to: sel) else { return nil }
    return owner.perform(sel)?.takeUnretainedValue() as? NSObject
}

func objectIvar(_ object: NSObject, _ name: String) -> Any? {
    guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return nil }
    return object_getIvar(object, ivar)
}

func boolIvar(_ object: NSObject, _ name: String) -> Bool? {
    guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return nil }
    let offset = ivar_getOffset(ivar)
    return Unmanaged.passUnretained(object).toOpaque()
        .advanced(by: offset)
        .assumingMemoryBound(to: UInt8.self)
        .pointee != 0
}

@main
struct Probe {
    static func main() {
        _ = NSApplication.shared
        precondition(Set(ViewerBindingTeardown.fileOwnerBindingKeyPaths) == [
            "self.thicknessInMm", "KeyImageCounter", "injectionDateTime", "self.windowsStateName"
        ])

        let nibURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try! Data(contentsOf: nibURL)
        let nib = NSNib(nibData: data, bundle: nil)

        // Twelve close cycles: each one loads File's Owner bindings, tears
        // them down the way windowWillClose will, then lets the owner and the
        // nib objects die in separate pools — the Autounbinder crash shape.
        for cycle in 1...12 {
            var top: NSArray?
            let owner = Owner()
            precondition(nib.instantiate(withOwner: owner, topLevelObjects: &top))
            let field = owner.nameField!
            owner.keyField = NSTextField(string: "")
            owner.thickField = NSTextField(string: "")
            owner.picker = NSDatePicker()
            owner.window?.contentView?.addSubview(owner.keyField!)
            owner.window?.contentView?.addSubview(owner.thickField!)
            owner.window?.contentView?.addSubview(owner.picker!)
            owner.keyField!.bind(.value, to: owner, withKeyPath: "KeyImageCounter", options: nil)
            owner.thickField!.bind(.value, to: owner, withKeyPath: "self.thicknessInMm", options: nil)
            owner.picker!.bind(.value, to: owner, withKeyPath: "injectionDateTime", options: nil)
            owner.bind(NSBindingName("flagListPODComparatives"),
                       to: NSUserDefaultsController.shared,
                       withKeyPath: "values.listPODComparativesIn2DViewer",
                       options: nil)
            precondition(field.infoForBinding(.value) != nil, "cycle \(cycle): nib binding missing")
            precondition(owner.keyField!.infoForBinding(.value) != nil)
            precondition(owner.thickField!.infoForBinding(.value) != nil)
            precondition(owner.picker!.infoForBinding(.value) != nil)
            precondition(owner.infoForBinding(NSBindingName("flagListPODComparatives")) != nil)

            if let unbinder = autounbinder(of: owner),
               let bindings = objectIvar(unbinder, "_bindingsToThisObject") as? NSArray {
                precondition(bindings.count >= 1, "cycle \(cycle): Autounbinder did not record the nib binding")
                precondition(boolIvar(unbinder, "_isRetainingBindingTarget") == false,
                             "cycle \(cycle): Autounbinder should not retain File's Owner yet")
            }

            ViewerBindingTeardown.unbindFileOwnerBindings(on: owner)

            precondition(field.infoForBinding(.value) == nil, "cycle \(cycle): nib value still bound")
            precondition(owner.keyField!.infoForBinding(.value) == nil, "cycle \(cycle): KeyImageCounter still bound")
            precondition(owner.thickField!.infoForBinding(.value) == nil, "cycle \(cycle): thicknessInMm still bound")
            precondition(owner.picker!.infoForBinding(.value) == nil, "cycle \(cycle): injectionDateTime still bound")
            precondition(owner.infoForBinding(NSBindingName("flagListPODComparatives")) == nil,
                         "cycle \(cycle): flagListPODComparatives still bound")
            if let unbinder = autounbinder(of: owner) {
                let bindings = objectIvar(unbinder, "_bindingsToThisObject") as? NSArray
                precondition(bindings == nil || bindings?.count == 0,
                             "cycle \(cycle): Autounbinder still holds File's Owner bindings")
            }
            _ = top
        }
        print("PASS: File's Owner bindings do not survive twelve teardown cycles")
    }
}
'''

objc_probe = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "ViewerAutounbinderDetach.h"

@interface Owner : NSWindowController
@property (copy) NSString *windowsStateName;
@property (assign) NSTextField *nameField;
@end
static int ownersFreed = 0;
@implementation Owner
- (void)dealloc { ownersFreed++; [super dealloc]; }
@end

static id ownerAutounbinder(id owner)
{
    Ivar moreSlot = class_getInstanceVariable([NSWindowController class], "_moreVars");
    id moreVars = moreSlot ? object_getIvar(owner, moreSlot) : nil;
    if (!moreVars)
        return nil;
    Ivar binderSlot = class_getInstanceVariable(object_getClass(moreVars), "autounbinder");
    return binderSlot ? object_getIvar(moreVars, binderSlot) : nil;
}

static id bindingTarget(id unbinder)
{
    Ivar target = class_getInstanceVariable(object_getClass(unbinder), "_bindingTarget");
    return target ? object_getIvar(unbinder, target) : nil;
}

static BOOL isRetainingTarget(id unbinder)
{
    Ivar flag = class_getInstanceVariable(object_getClass(unbinder), "_isRetainingBindingTarget");
    if (!flag)
        return NO;
    return ((char *)unbinder)[ivar_getOffset(flag)] != 0;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSNib *nib = [[NSNib alloc] initWithNibData:data bundle:nil];
        if (!nib)
            return 2;
        for (int cycle = 1; cycle <= 12; cycle++) {
            // The nib objects and the proxy outlive the owner, as the window
            // and a binding or a pool can after the close's extra release.
            NSArray *survivors = nil;
            id survivingUnbinder = nil;
            @autoreleasepool {
                Owner *owner = [[Owner alloc] init];
                owner.windowsStateName = @"ws";
                NSArray *top = nil;
                if (![nib instantiateWithOwner:owner topLevelObjects:&top])
                    return 3;
                id unbinder = ownerAutounbinder(owner);
                if (!unbinder) {
                    fprintf(stderr, "cycle %d: no Autounbinder after nib load\n", cycle);
                    return 4;
                }
                if (isRetainingTarget(unbinder) || bindingTarget(unbinder) != owner) {
                    fprintf(stderr, "cycle %d: Autounbinder should point at File's Owner without retaining it\n", cycle);
                    return 5;
                }
                [owner.nameField unbind:@"value"];
                HorosDetachAutounbinder(owner);
                if (ownerAutounbinder(owner) != unbinder) {
                    fprintf(stderr, "cycle %d: Autounbinder slot changed\n", cycle);
                    return 6;
                }
                if (isRetainingTarget(unbinder)) {
                    fprintf(stderr, "cycle %d: Autounbinder retains File's Owner, which then is never freed\n", cycle);
                    return 7;
                }
                if (bindingTarget(unbinder) != nil) {
                    fprintf(stderr, "cycle %d: Autounbinder still points at File's Owner\n", cycle);
                    return 8;
                }
                survivors = [top retain];
                survivingUnbinder = [unbinder retain];
                [owner release];
            }
            if (ownersFreed != cycle) {
                fprintf(stderr, "cycle %d: the closed owner was not freed (%d of %d)\n", cycle, ownersFreed, cycle);
                return 9;
            }
            @autoreleasepool {
                [survivors release];
                [survivingUnbinder release];
            }
        }
        [nib release];
        fprintf(stderr, "PASS: twelve owners freed after Autounbinder detach, proxy and nib objects outliving them\n");
    }
    return 0;
}
'''

xib = '''<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.Cocoa.XIB" version="3.0" toolsVersion="24127" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none" useAutolayout="YES">
    <objects>
        <customObject id="-2" userLabel="File's Owner" customClass="Owner">
            <connections>
                <outlet property="nameField" destination="f1" id="o1"/>
                <outlet property="window" destination="w1" id="o2"/>
            </connections>
        </customObject>
        <customObject id="-1" userLabel="First Responder" customClass="FirstResponder"/>
        <customObject id="-3" userLabel="Application" customClass="NSObject"/>
        <window title="Probe" releasedWhenClosed="NO" visibleAtLaunch="NO" id="w1">
            <windowStyleMask key="styleMask" titled="YES" closable="YES"/>
            <rect key="contentRect" x="0" y="0" width="200" height="80"/>
            <view key="contentView" id="cv">
                <rect key="frame" x="0" y="0" width="200" height="80"/>
                <subviews>
                    <textField translatesAutoresizingMaskIntoConstraints="NO" id="f1">
                        <rect key="frame" x="20" y="40" width="160" height="22"/>
                        <textFieldCell key="cell" scrollable="YES" lineBreakMode="clipping" selectable="YES" editable="YES" sendsActionOnEndEditing="YES" state="on" borderStyle="bezel" drawsBackground="YES" id="c1">
                            <font key="font" metaFont="system"/>
                            <color key="textColor" name="controlTextColor" catalog="System" colorSpace="catalog"/>
                            <color key="backgroundColor" name="textBackgroundColor" catalog="System" colorSpace="catalog"/>
                        </textFieldCell>
                        <connections>
                            <binding destination="-2" name="value" keyPath="windowsStateName" id="b1"/>
                        </connections>
                    </textField>
                </subviews>
            </view>
        </window>
    </objects>
</document>
'''

with tempfile.TemporaryDirectory(prefix='horos-viewer-bindings-') as folder:
    folder = Path(folder)
    compiled = folder / 'Owner.nib'
    source_xib = folder / 'Owner.xib'
    source_xib.write_text(xib)
    subprocess.run(['ibtool', '--compile', str(compiled), str(source_xib)], check=True)
    (folder / 'test.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
        str(helper), str(folder / 'test.swift'),
        '-framework', 'AppKit',
        '-o', str(folder / 'test'),
    ], check=True)
    env = dict(**{k: v for k, v in __import__('os').environ.items()})
    env['NSZombieEnabled'] = 'YES'
    subprocess.run([str(folder / 'test'), str(compiled)], check=True, env=env)

    # HorosDetachAutounbinder is an exported C function that reads AppKit ivars
    # under manual retain/release: it is kept in Objective-C, in
    # ViewerAutounbinderDetach+CAPI.m, and the probe compiles it from there.
    detach_m = root / 'Horos/Sources/ViewerAutounbinderDetach+CAPI.m'
    (folder / 'detach-probe.m').write_text(objc_probe)
    subprocess.run([
        'xcrun', 'clang', '-fno-objc-arc', '-fobjc-exceptions',
        '-framework', 'Cocoa',
        '-I', str(root / 'Horos/Sources'),
        str(folder / 'detach-probe.m'), str(detach_m),
        '-o', str(folder / 'detach-probe'),
    ], check=True)
    subprocess.run([str(folder / 'detach-probe'), str(compiled)], check=True, env=env)

print('PASS: Viewer.xib File\'s Owner key paths, windowWillClose order, '
      f'twelve teardown cycles ({", ".join(sorted(expected))})')
