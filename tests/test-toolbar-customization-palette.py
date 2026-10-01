#!/usr/bin/env python3
"""Toolbar items keep no capsule in the customization palette (#886), and the
palettes offer AppKit's own Space (#894).

The palette snapshots the items the delegate returns with
`willBeInsertedIntoToolbar: NO`; no insertion notification reaches them, and
AppKit draws the glass capsule from `isBordered`, which an item whose view is
an `NSPopUpButton` or `NSSegmentedControl` answers YES for whatever was set.
After `ToolbarPolicy.prepare` every plain item answers NO, and so do its copies.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'Horos/Sources/ToolbarPolicy.swift',
    root / 'Horos/Sources/ToolbarImage.swift',
    root / 'Horos/Sources/ToolbarMenuBridge.swift',
]
for source in sources:
    assert source.is_file(), f'missing {source}'

# A plain item's class name changes; the one class-name test on a toolbar sender
# must accept it.
vr = source_text('VRController')
assert 'isEqualToString:@"NSToolbarItem"' not in vr, 'VRController compares the sender class name with NSToolbarItem'
assert '[sender isKindOfClass: [NSToolbarItem class]]' in vr

code = r'''
import AppKit
import ObjectiveC

@MainActor func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

typealias GetInteger = @convention(c) (AnyObject, Selector) -> Int
/// AppKit's own answer to "does this item get a glass background": 0 is none.
@MainActor func glassBehavior(_ item: NSToolbarItem) -> Int? {
    let selector = NSSelectorFromString("glassBehavior")
    guard let method = class_getInstanceMethod(object_getClass(item), selector) else { return nil }
    return unsafeBitCast(method_getImplementation(method), to: GetInteger.self)(item, selector)
}

// The code under test is the main actor's (#961).
MainActor.assumeIsolated {
_ = NSApplication.shared

// #886: every kind of view, prepared as a palette item would be.
let views: [(String, NSView)] = [
    ("popup", NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 25))),
    ("segmented", NSSegmentedControl(frame: NSRect(x: 0, y: 0, width: 80, height: 25))),
    ("container", NSView(frame: NSRect(x: 0, y: 0, width: 74, height: 49))),
]
for (name, view) in views {
    let item = NSToolbarItem(itemIdentifier: .init(name))
    item.view = view
    ToolbarPolicy.prepare(item)
    check(!item.isBordered, "\(name): prepare must leave the item unbordered")
    item.isBordered = true
    check(!item.isBordered, "\(name): AppKit turning bordered back on must not stick")
    if let glass = glassBehavior(item) {
        check(glass == 0, "\(name): AppKit still gives the item a glass background (\(glass))")
    }
    let copy = item.copy() as! NSToolbarItem
    check(!copy.isBordered, "\(name): the copy AppKit makes must stay unbordered")
}
@MainActor final class PluginItem: NSToolbarItem {}
let plugin = PluginItem(itemIdentifier: .init("plugin"))
plugin.image = NSImage(named: NSImage.folderName)
plugin.isBordered = true
ToolbarPolicy.prepare(plugin)
check(type(of: plugin) == PluginItem.self && !plugin.isBordered, "a plugin subclass keeps its class and is flattened")

// #894: the palette's Space is AppKit's.
check(ToolbarPolicy.spaceItemIdentifier == NSToolbarItem.Identifier.space.rawValue, "the palettes must offer AppKit's Space")

print("PASS: palette items stay unbordered, AppKit Space")
}
'''

with tempfile.TemporaryDirectory(prefix='horos-toolbar-palette-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5',
        *[str(s) for s in sources], str(folder / 'main.swift'),
        '-framework', 'AppKit',
        '-o', str(folder / 'test'),
    ], check=True)
    subprocess.run([str(folder / 'test')], check=True)

print('PASS: toolbar customization palette items keep no capsule')
