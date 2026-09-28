#!/usr/bin/env python3
"""Exercise actual movie finalization with delayed and failing writer peers.

QuicktimeExport is Swift since #717: the finalization block is taken from the
Swift source (tests/sources.py) and compiled with Swift peers of the same shape."""
from pathlib import Path
import subprocess, tempfile, sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
root=Path(__file__).resolve().parents[1]
path=sources.source_path('QuicktimeExport')
s=(subprocess.check_output(['git','show',sys.argv[1]+':'+str(path.relative_to(root))]).decode('utf-8') if len(sys.argv)>1 else sources.source_text('QuicktimeExport'))
a=s.index('                if writer.status == .writing {\n                    writerInput?.markAsFinished()')
b=s.index('                _ = (object as AnyObject?)?.perform(',a)
body=s[a:b]
code=r'''
import Foundation
import AVFoundation
final class Writer {
 var status: AVAssetWriter.Status
 var fail = false, called = false
 var error: Error?
 init(_ status: AVAssetWriter.Status) { self.status = status }
 func finishWriting(completionHandler: @escaping () -> Void) {
  called = true
  DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
   self.status = self.fail ? .failed : .completed
   if self.fail { self.error = NSError(domain: "WriterTest", code: 17, userInfo: nil) }
   completionHandler()
  }
 }
 func cancelWriting() { status = .cancelled }
}
final class Input {
 func markAsFinished() {}
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
for scenario in 0..<5 {
 let writer = Writer(scenario == 3 ? .failed : .writing); writer.fail = scenario == 1
 let writerInput: Input? = Input()
 var completed = false, failed = scenario == 4, aborted = scenario == 2; var error: NSError? = nil
 _ = (failed, aborted)
BODY
 if scenario == 0 && (!completed || writer.status != .completed) { fail("returned before writer finished") }
 if scenario == 1 && (completed || error?.code != 17) { fail("failed finalization reported success or lost error") }
 if (scenario == 2 || scenario == 4) && (completed || writer.called || writer.status != .cancelled) { fail("cancelled writer finalized") }
 if scenario == 3 && (completed || writer.called) { fail("failed writer finalized again") }
}
print("PASS: waits for delayed completion; preserves failure error; cancels without finalizing; rejects failed writer")
'''.replace('BODY',body)
with tempfile.TemporaryDirectory(prefix='horos-movie-finalization-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
