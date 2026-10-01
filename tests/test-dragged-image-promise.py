#!/usr/bin/env python3
"""A viewer drag must fulfil a JPEG file promise only after the file exists."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
code = r'''
import AppKit
import Foundation

@main struct Test {
 static func main() throws {
  _ = NSApplication.shared

  let image = NSImage(size: NSSize(width: 8, height: 8))
  image.lockFocus()
  NSColor.red.setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
  image.unlockFocus()
  guard let tiff = image.tiffRepresentation, !tiff.isEmpty else {
    preconditionFailure("need a TIFF bitmap for the promise")
  }

  let promise = DraggedImagePromise(tiffData: tiff, study: "DOE/JANE", series: "../../etc")
  precondition(promise.suggestedFileName == "DOE JANE - etc.jpg",
               "hostile DICOM text leaked into the promised name: \(promise.suggestedFileName)")
  precondition(promise.suggestedFileName.hasSuffix(".jpg"))
  precondition(DraggedImagePromise.promisedContentType == "public.jpeg")

  let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("horos-drag-promise-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }

  let dest = folder.appendingPathComponent(promise.suggestedFileName)
  try promise.writeJPEG(to: dest)
  precondition(FileManager.default.fileExists(atPath: dest.path), "destination never received a file")
  guard let written = NSImage(contentsOf: dest), written.size.width > 0 else {
    preconditionFailure("destination received a path that is not a complete image")
  }

  // An empty encode must not leave a file the drop location would treat as real.
  let empty = DraggedImagePromise(tiffData: Data(), study: "Empty", series: "Fail")
  let missing = folder.appendingPathComponent("must-not-exist.jpg")
  do {
    try empty.writeJPEG(to: missing)
    preconditionFailure("an empty TIFF must not fulfil the promise")
  } catch {
    precondition(!FileManager.default.fileExists(atPath: missing.path),
                 "failed promise left \(missing.lastPathComponent)")
  }

  let provider = NSFilePromiseProvider(fileType: DraggedImagePromise.promisedContentType, delegate: promise)
  precondition(promise.filePromiseProvider(provider, fileNameForType: "public.jpeg")
               == promise.suggestedFileName)

  let fulfilled = folder.appendingPathComponent("from-delegate.jpg")
  let lock = DispatchSemaphore(value: 0)
  var writeError: Error?
  promise.filePromiseProvider(provider, writePromiseTo: fulfilled) { error in
    writeError = error
    lock.signal()
  }
  precondition(lock.wait(timeout: .now() + 2) == .success, "file promise write never finished")
  precondition(writeError == nil, "file promise write failed: \(String(describing: writeError))")
  precondition(FileManager.default.fileExists(atPath: fulfilled.path))

  // The writer DCMView hands AppKit (#1036). -initWithFileType:delegate: sends
  // -init to the subclass on macOS 27; a missing init() override aborts here.
  let dragged = promise.filePromiseProviderForDragging()
  precondition(dragged.fileType == DraggedImagePromise.promisedContentType,
               "the drag provider promises \(dragged.fileType), not JPEG")
  precondition(dragged.delegate === promise, "the drag provider lost its delegate")
  let dragTypes = dragged.writableTypes(for: NSPasteboard.general)
  precondition(dragTypes.first == .tiff, "the bitmap must lead the drag item: \(dragTypes)")
  precondition((dragged.pasteboardPropertyList(forType: .tiff) as? Data) == tiff,
               "the drag provider lost the TIFF it was built with")
  let board = NSPasteboard.withUniqueName()
  board.clearContents()
  precondition(board.writeObjects([dragged]), "pasteboard rejected the drag provider")
  let declared = Set((board.types ?? []).map(\.rawValue))
  precondition(declared.contains(NSPasteboard.PasteboardType.tiff.rawValue),
               "drag pasteboard omitted TIFF: \(declared)")
  precondition(declared.contains(where: { $0.contains("promised-file") }),
               "drag pasteboard omitted the file promise: \(declared)")
  precondition(board.data(forType: .tiff) == tiff, "drag pasteboard TIFF differs from the source")
  board.clearContents()
  board.releaseGlobally()

  print("PASS: JPEG file promise writes a complete image and leaves no file when encode fails; the drag provider survives AppKit's -init")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-drag-promise-') as folder:
    p = Path(folder)
    (p / 'test.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'Horos/Sources/DraggedImageFile.swift'),
                    str(root / 'Horos/Sources/DraggedImagePromise.swift'),
                    str(root / 'Horos/Sources/IdentityToken.swift'),
                    str(p / 'test.swift'), '-framework', 'Foundation', '-framework', 'AppKit',
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

    # Negative control (#1036): the former provider, a designated initializer
    # chaining to -initWithFileType:delegate: without overriding init(), must
    # abort where the fixed one passes. If this AppKit no longer sends -init,
    # the control cannot fail and says so instead of passing silently.
    (p / 'control.swift').write_text(r'''
import AppKit
final class Delegate: NSObject, NSFilePromiseProviderDelegate {
  func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String { "x.jpg" }
  func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                           completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}
final class FormerProvider: NSFilePromiseProvider {
  private let tiffData: Data
  init(tiffData: Data, delegate: NSFilePromiseProviderDelegate) {
    self.tiffData = tiffData
    super.init(fileType: "public.jpeg", delegate: delegate)
  }
}
let delegate = Delegate()
_ = FormerProvider(tiffData: Data([1]), delegate: delegate)
print("CONTROL-SURVIVED")
''')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(p / 'control.swift'),
                    '-framework', 'AppKit', '-o', str(p / 'control')],
                   check=True, capture_output=True)
    control = subprocess.run([str(p / 'control')], capture_output=True, text=True)
    if control.returncode == 0 and 'CONTROL-SURVIVED' in control.stdout:
        print('NOTE: this AppKit does not send -init from -initWithFileType:delegate:; '
              'the negative control cannot fail here')
    else:
        if "unimplemented initializer 'init()'" not in control.stderr:
            raise SystemExit(f'FAIL: the control died for another reason: {control.stderr[-400:]}')
        print('PASS: control: the former provider aborts with the unimplemented init() trap')
