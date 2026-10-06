#!/usr/bin/env python3
"""Runtime pasteboard types for a viewer image drag, and the DCMView wiring."""
from pathlib import Path
import re, subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

# The drag source of DCMView is Swift, in DCMView+DragAndDrop.swift.
view = source_text('DCMView+DragAndDrop')

def require(condition, message):
    if not condition:
        raise SystemExit(f'FAIL: {message}')

def swift_method(signature):
    """A Swift method, from its @objc name to the brace that closes its body."""
    start = view.find(signature)
    require(start >= 0, f'{signature} is gone')
    depth = 0
    for end in range(view.index('{', start), len(view)):
        if view[end] == '{':
            depth += 1
        elif view[end] == '}':
            depth -= 1
            if depth == 0:
                return view[start:end + 1]
    return view[start:]

start = view.index('    @objc(startDrag:)')
ended = view.index('    @objc(deleteMouseDownTimer)', start)
block = view[start:ended]
require('DraggedImagePromise(tiffData:' in swift_method('    @objc(startDrag:)'),
        'startDrag must hand the destination an NSFilePromiseProvider-backed item')
require('kUTTypeImage' not in block and not re.search(r'UTType\.image\b|"public\.image"', block),
        'an abstract image UTI does not tell Finder or a browser to expect JPEG')
require('NSPasteboardTypeString' not in block and not re.search(r'\.string\b', block),
        'do not advertise a string type the provider never fulfils')
require('horos__dragInProgress = false' not in block.split('} catch')[0],
        'clearing _dragInProgress before the session ends lets WW/WL run during export')

timer = swift_method('    @objc(deleteMouseDownTimer)')
require('horos__dragInProgress = false' not in timer,
        'deleteMouseDownTimer must not end an export session already in progress')
require('horos__dragInProgress = false' in swift_method('    @objc(draggingSession:endedAtPoint:operation:)'),
        'the export session must end in draggingSession:endedAtPoint:')
require('ViewerImageDrag.sourceOperationMask(outsideApplication:' in
        swift_method('    @objc(draggingSession:sourceOperationMaskForDraggingContext:)'),
        'external drops must use the Copy mask Finder and browsers accept')
require('DraggedImagePromise.swift' in
        (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8'),
        'the file-promise type must be compiled into Horos')

code = r'''
import AppKit
import Foundation

@main struct Test {
 static func main() {
  _ = NSApplication.shared
  let image = NSImage(size: NSSize(width: 4, height: 4))
  image.lockFocus()
  NSColor.blue.setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
  image.unlockFocus()
  let tiff = image.tiffRepresentation!
  let promise = DraggedImagePromise(tiffData: tiff, study: "QA", series: "Axial")

  let needed = [
    NSPasteboard.PasteboardType.tiff.rawValue,
    "com.apple.pasteboard.promised-file-url",
    "com.apple.pasteboard.promised-file-content-type",
    DraggedImagePromise.promisedContentType,
  ]
  for type in needed {
    precondition(DraggedImagePromise.advertisedTypeIdentifiers.contains(type),
                 "missing advertised type \(type)")
  }

  let types = Set(promise.writableTypes(for: NSPasteboard.general).map(\.rawValue))
  precondition(types.contains(NSPasteboard.PasteboardType.tiff.rawValue),
               "browser destinations need a bitmap: \(types)")
  precondition(types.contains(where: { $0.contains("promised-file") }),
               "Finder needs a file promise: \(types)")

  let board = NSPasteboard.withUniqueName()
  board.clearContents()
  precondition(board.writeObjects([promise]), "pasteboard rejected the drag item")
  let declared = Set((board.types ?? []).map(\.rawValue))
  precondition(declared.contains(NSPasteboard.PasteboardType.tiff.rawValue),
               "runtime pasteboard omitted TIFF: \(declared)")
  precondition(declared.contains(where: { $0.contains("promised-file") }),
               "runtime pasteboard omitted the file promise: \(declared)")
  let bitmap = board.data(forType: .tiff)
  precondition((bitmap?.count ?? 0) > 0, "TIFF promise was empty")
  precondition(NSImage(data: bitmap!)?.size.width ?? 0 > 0, "TIFF was not a complete image")

  print("PASS: runtime pasteboard carries TIFF plus a JPEG file promise; DCMView keeps the session")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-drag-pasteboard-') as folder:
    p = Path(folder)
    (p / 'test.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'Horos/Sources/DraggedImageFile.swift'),
                    str(root / 'Horos/Sources/DraggedImagePromise.swift'),
                    str(root / 'Horos/Sources/IdentityToken.swift'),
                    str(p / 'test.swift'), '-framework', 'Foundation', '-framework', 'AppKit',
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
