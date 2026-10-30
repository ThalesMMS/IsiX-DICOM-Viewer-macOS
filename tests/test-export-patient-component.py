#!/usr/bin/env python3
"""Execute actual patient-path construction; empty filtered names must remain children.

The export is Swift (BrowserController+DICOMExport.swift, with the rules of
IsiXDatabase's ExportNaming): its patient-path step runs here as it is, with
the real sanitizer and patient-folder name.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a = source.index('    @objc(replaceNotAdmitted:)\n')
sanitizer = source[a:source.index('    /// The patient folder the export', a)]
a = source.index('    @objc(dicomExportPatientFolderName:addDICOMDIR:)')
helper = source[a:source.index('\n    }\n', a) + len('\n    }\n')]
a = source.index('                var tempPath', source.index('    nonisolated private func exportDICOMFiles('))
block = source[a:source.index('                // Two patients of this export', a)]
program = r'''
import Foundation
import IsiXDatabase
final class ExportFolderNaming {}
@objc(BrowserController) public class BrowserController: NSObject {}
extension BrowserController {
SANITIZER
HELPER
 nonisolated class func configuredPatientFolder(for image: Any, naming: ExportFolderNaming) -> String { fatalError("not configured") }
 static func path(_ path: String, name input: Any, dicomdir addDICOMDIR: Bool) -> String {
  let customFolderNaming: ExportFolderNaming? = nil // Exercise the unchanged default path.
  let study: NSDictionary = input is NSNull ? [:] : ["name": input]
  let curImage: NSDictionary = ["series": ["study": study]]
BLOCK
  return tempPath
 }
}
@main struct Main {
 static func main() {
  let root = CommandLine.arguments[1]
  let names: [Any] = ["", NSNull(), ":", "/", "\\", ".", "..", ".,^/\\|:*<>?#%", "--------", "Chr-P03R", "Chr_P03R", "??AB", "日本語"]
  for mode in [false, true] {
   for name in names {
    let path = BrowserController.path(root, name: name, dicomdir: mode) as NSString
    if path.deletingLastPathComponent != root || path.lastPathComponent.isEmpty {
     FileHandle.standardError.write("FAIL mode \(mode) name \(name) escaped child directory: \(path)\n".data(using: .utf8)!); exit(1)
    }
    if mode && path.lastPathComponent != path.lastPathComponent.uppercased() { FileHandle.standardError.write("FAIL lowercase DICOMDIR fallback\n".data(using: .utf8)!); exit(1) }
   }
   let empty = (BrowserController.path(root, name: ":*?", dicomdir: mode) as NSString).lastPathComponent
   if empty != (mode ? "UNNAMED" : "unnamed") { exit(1) }
  }
  print("PASS: 26 real patient-path cases remain child directories; empty names get ordinary/DICOMDIR fallback")
 }
}
'''.replace('SANITIZER', sanitizer).replace('BLOCK', block).replace('HELPER', helper)
with tempfile.TemporaryDirectory(prefix='horos-patient-component-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(program)
    flags = module_flags('IsiXDatabase', path / 'modules')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *flags, str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path / 'exports')], check=True)
