#!/usr/bin/env python3
"""Run the actual post-panel file-handling block against a retained destination.

QuicktimeExport is Swift: the block is taken from the Swift source
(tests/sources.py) and compiled with a Trash that must never be reached."""
from pathlib import Path
import subprocess, tempfile, sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
root=Path(__file__).resolve().parents[1]
path=sources.source_path('QuicktimeExport')
source=(subprocess.check_output(['git','show',sys.argv[1]+':'+str(path.relative_to(root))]).decode('utf-8') if len(sys.argv)>1 else sources.source_text('QuicktimeExport'))
a=source.index('            fileName = panel.url?.path')+len('            fileName = panel.url?.path')
a=source.index('        }',a)+len('        }')
b=source.index('        var returned: String? = nil',a)
body=source[a:b]
code=r'''
import AppKit
extension FileManager {
 func moveItemAtPath(toTrash path: String?) { abort() }
}
func request(_ fileName: String?, _ result: Int) -> String? {
BODY
 return fileName
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
let path = CommandLine.arguments[1]
let original = "existing movie must survive cancellation".data(using: .utf8)!
try! original.write(to: URL(fileURLWithPath: path), options: .atomic)
for response in [NSApplication.ModalResponse.cancel, .abort, .stop] {
 let result = request(path, response.rawValue)
 if result != nil || (try? Data(contentsOf: URL(fileURLWithPath: path))) != original {
  fail("rejected save request modified destination or reported success")
 }
}
if request(path, NSApplication.ModalResponse.OK.rawValue) != path || FileManager.default.fileExists(atPath: path) {
 fail("accepted overwrite did not proceed")
}
print("PASS: Cancel/Abort/Stop preserve existing bytes and return nil; accepted overwrite proceeds")
'''.replace('BODY',body)
with tempfile.TemporaryDirectory(prefix='horos-movie-cancel-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'existing.mov')],check=True)
