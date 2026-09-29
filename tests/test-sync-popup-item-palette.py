#!/usr/bin/env python3
"""#936: the orthogonal MPR's Sync item shows its icon in the Customize Toolbar palette.

With `<git revision>` as an optional argument, the item is compiled from that
revision, for the negative control (run against 62e5aa8da, before the fix, it
must fail).

The Sync item of the orthogonal MPR and of the PET-CT orthogonal viewer is a
KBPopUpToolbarItem, whose view is a borderless button. Its image setter kept
the artwork at its authoring size (Sync.pdf is a 593-point page) until
-validate put the 32-point copy in the button, and a button made in code draws
its image unscaled. The palette does not validate its items, so it showed a
crop of the middle of the page: a grey band, in the list of items and in the
default set. The item is built here as initSyncSeriesToolbarItem builds it,
with no toolbar and no validation, as the palette gets it, and drawn in a
dark and a light window: the icon must fit the button and its blue arrows
must show. The pop-up arrow of the item must also stand out from a dark
toolbar.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
ITEM = 'Nitrogen/Sources/KBPopUpToolbarItem.swift'
IMAGE = 'Horos/Sources/ToolbarImage.swift'
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


def read(path):
    if len(sys.argv) > 1:
        result = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        if result.returncode != 0:
            print('FAIL: ' + path + ' not found at ' + sys.argv[1])
            sys.exit(1)
        return result.stdout.decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


# Both orthogonal viewers make the Sync item a KBPopUpToolbarItem set up by
# the shared initSyncSeriesToolbarItem, which gives it Sync.pdf or SyncLock.pdf.
ortho = sources.source_text('OrthogonalMPRViewer')
petct = sources.source_text('OrthogonalMPRPETCTViewer')
for name, text in (('OrthogonalMPRViewer', ortho), ('OrthogonalMPRPETCTViewer', petct)):
    require('toolbarItem = KBPopUpToolbarItem(itemIdentifier: itemIdent)' in text,
            name + ' no longer makes the Sync item a KBPopUpToolbarItem')
    require('OrthogonalMPRViewer.initSyncSeriesToolbarItem(self, ' in text,
            name + ' no longer sets the Sync item up through initSyncSeriesToolbarItem')
require('private let SyncSeriesImageName = "Sync.pdf"' in ortho
        and 'NSImage(named: SyncLockSeriesImageName) : NSImage(named: SyncSeriesImageName)' in ortho,
        'the Sync item no longer shows Sync.pdf or SyncLock.pdf')

code = r'''
import AppKit

// The button of the item drawn in a window of the given appearance, over a
// toolbar-like background.
func draw(_ button: NSButton, _ appearance: NSAppearance.Name) -> NSBitmapImageRep {
 let dark = appearance == .darkAqua
 let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                       styleMask: [.borderless], backing: .buffered, defer: false)
 window.appearance = NSAppearance(named: appearance)
 let content = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
 content.wantsLayer = true
 content.layer?.backgroundColor = NSColor(deviceWhite: dark ? 0.16 : 0.93, alpha: 1).cgColor
 window.contentView = content
 button.removeFromSuperview()
 button.setFrameOrigin(NSPoint(x: 11, y: 16))
 content.addSubview(button)
 content.needsDisplay = true
 content.displayIfNeeded()
 let rep = content.bitmapImageRepForCachingDisplay(in: button.frame)!
 content.cacheDisplay(in: button.frame, to: rep)
 return rep
}

func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
 let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
 return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
}

func lum(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

// Pixels of the blue arrows of Sync.pdf.
func blue(_ rep: NSBitmapImageRep) -> Int {
 var count = 0
 for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
  let c = rgb(rep, x, y)
  if c.b - c.r > 0.25 { count += 1 }
 } }
 return count
}

@main struct Test {
 static func main() {
  setvbuf(stdout, nil, _IONBF, 0)
  _ = NSApplication.shared
  let artwork = NSImage(contentsOfFile: CommandLine.arguments[1])!
  precondition(max(artwork.size.width, artwork.size.height) > 64, "Sync.pdf is page-sized artwork (\(artwork.size))")

  // As initSyncSeriesToolbarItem: menu, then image; no toolbar, no -validate.
  func item(menu: Bool) -> KBPopUpToolbarItem {
   let item = KBPopUpToolbarItem(itemIdentifier: .init("Sync"))
   item.label = "Sync"
   item.paletteLabel = "Sync"
   if menu {
    item.menu = NSMenu(title: "")
    item.menu?.addItem(withTitle: "All", action: nil, keyEquivalent: "")
   }
   item.image = artwork
   return item
  }
  let sync = item(menu: true)
  let button = sync.view as! NSButton
  let shown = button.image!
  var failed = false
  func check(_ condition: Bool, _ message: String) {
   if !condition { print("FAIL: " + message); failed = true }
  }
  check(max(shown.size.width, shown.size.height) <= ToolbarImage.defaultSize,
        "the palette item shows the artwork at \(shown.size), larger than the \(Int(button.frame.width))x\(Int(button.frame.height)) button")
  check(artwork.size == NSSize(width: 593, height: 593), "the artwork given to the item was resized")

  let plain = item(menu: false).view as! NSButton
  var blues: [String] = []
  for appearance in [NSAppearance.Name.darkAqua, .aqua] {
   let withMenu = draw(button, appearance)
   let found = blue(withMenu)
   blues.append("\(found)")
   check(found > 120, "\(appearance.rawValue): the palette item draws \(found) pixels of the blue Sync arrows, not the icon")

   // The pop-up arrow: what the item with a menu draws over the one without.
   let withoutMenu = draw(plain, appearance)
   var arrow = 0, contrasted = 0
   for y in 0..<withMenu.pixelsHigh { for x in 0..<withMenu.pixelsWide {
    let a = lum(rgb(withMenu, x, y)), b = lum(rgb(withoutMenu, x, y))
    guard abs(a - b) > 0.05 else { continue }
    arrow += 1
    if appearance == .darkAqua ? a > 0.6 : a < 0.35 { contrasted += 1 }
   } }
   check(arrow > 10, "\(appearance.rawValue): no pop-up arrow drawn (\(arrow) pixels)")
   check(contrasted * 2 > arrow, "\(appearance.rawValue): the pop-up arrow does not stand out (\(contrasted) of \(arrow) pixels)")
  }
  if failed { exit(1) }
  print("PASS: the palette Sync item shows the \(Int(shown.size.width))-point icon with its blue arrows (dark, light: \(blues.joined(separator: ", ")) pixels) and a legible pop-up arrow")
 }
}
'''

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)

with tempfile.TemporaryDirectory(prefix='horos-sync-popup-item-') as folder:
    p = Path(folder)
    (p / 'KBPopUpToolbarItem.swift').write_text(read(ITEM), encoding='utf-8')
    (p / 'ToolbarImage.swift').write_text(read(IMAGE), encoding='utf-8')
    (p / 'test.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-suppress-warnings',
                    str(p / 'KBPopUpToolbarItem.swift'), str(p / 'ToolbarImage.swift'), str(p / 'test.swift'),
                    '-framework', 'AppKit', '-o', str(p / 'test')], check=True)
    result = subprocess.run([str(p / 'test'), str(root / 'Horos/Resources/Icons/Sync.pdf')])
    sys.exit(result.returncode)
