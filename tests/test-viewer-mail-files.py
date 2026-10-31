#!/usr/bin/env python3
"""Exercise viewer's actual write guard and AppleEvent attachment loop.

The image export of the 2D viewer is ViewerImageExporter.swift: the write
guard of the Mail/Photos branch and the attachment list of the Mail branch are
copied out of its endImageSheet and compiled with xcrun swiftc, as they were
with clang. HorosMailDraftComposer is MailDraftComposer in Swift.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import subprocess,tempfile
import sources
root=Path(__file__).resolve().parents[1]
s=sources.source_text('ViewerImageExporter')
m=s.index('    func endImageSheet(');e=s.index('\n    }\n',m)
method=s[m:e]
a=method.index('if !((bitmapData as NSData?)?.write(toFile: jpegFile, atomically: true) ?? false) {')
b=method.index('\n\n                JPEGExif.addExif(',a)
write=method[a:b]
a=method.index('// The attachments in the order the images were written.')
b=method.index('MailDraftComposer.compose(subject:',a)
loop=method[a:b]
code=r'''
import Foundation
let root = CommandLine.arguments[1]
let sharedExportRoot = root
for scenario in 0..<3 {
    var mailExportFiles: [String] = []
    var sharedImageExportFailed = false
    // Intentionally non-lexical order: the attachment list must retain generation order.
    let names = ["0003.jpg", "0001.jpg", "0002.jpg"]
    for i in 0..<3 {
        var jpegFile = (root as NSString).appendingPathComponent(names[i])
        var bitmapData: Data? = "synthetic image output".data(using: .utf8)
        if scenario == 1 && i == 1 { jpegFile = (root as NSString).appendingPathComponent("missing/0001.jpg") }
        if scenario == 2 && i == 0 { bitmapData = nil }
        WRITE
    }
    if sharedImageExportFailed != (scenario != 0) { exit(1) }
    if mailExportFiles.count != (scenario == 0 ? 3 : scenario == 1 ? 1 : 0) { exit(2) }
    if sharedImageExportFailed || mailExportFiles.count == 0 { continue }
    LOOP
    if mailFilePaths.count != 3 { exit(3) }
    for i in 0..<3 { if (mailFilePaths[i] as NSString).lastPathComponent != names[i] { exit(4) } }
}
print("PASS: attachment path order; failed and nil writes stop collection; empty/partial handoff suppressed")
'''.replace('WRITE',write).replace('LOOP',loop)
assert 'formatTag == ViewerImageFormat.mail.rawValue && !sharedImageExportFailed && !mailExportFiles.isEmpty' in s
assert 'MailDraftComposer.compose(' in s
assert 'defaultaddress@mac.com' not in s
assert 'defaultaddress@mac.com' not in (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
with tempfile.TemporaryDirectory(prefix='horos-mail-files-') as d:
 p=Path(d);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),d],check=True)
