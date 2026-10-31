#!/usr/bin/env python3
"""Execute actual patient-path construction; empty filtered names must remain children.

The export is Swift (DICOMFolderExport.swift, with the rules of IsiXDatabase's
ExportNaming): its patient-path step runs here as it is, with the real
sanitizer and patient-folder name.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DICOMFolderExport.swift').read_text()
a = source.index('                var tempPath', source.index('    private func export('))
block = source[a:source.index('                // Two patients of this export', a)]
program = r'''
import Foundation
import IsiXDatabase
final class ExportFolderNaming {}
struct Study { var name: String? }
enum DICOMFolderExport {
 static func configuredPatientFolder(of study: Study?, naming: ExportFolderNaming) -> String { fatalError("not configured") }
 static func path(_ location: String, name input: Any, dicomdir addDICOMDIR: Bool) -> String {
  let customFolderNaming: ExportFolderNaming? = nil // Exercise the unchanged default path.
  let study: Study? = Study(name: input as? String)
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
    let path = DICOMFolderExport.path(root, name: name, dicomdir: mode) as NSString
    if path.deletingLastPathComponent != root || path.lastPathComponent.isEmpty {
     FileHandle.standardError.write("FAIL mode \(mode) name \(name) escaped child directory: \(path)\n".data(using: .utf8)!); exit(1)
    }
    if mode && path.lastPathComponent != path.lastPathComponent.uppercased() { FileHandle.standardError.write("FAIL lowercase DICOMDIR fallback\n".data(using: .utf8)!); exit(1) }
   }
   let empty = (DICOMFolderExport.path(root, name: ":*?", dicomdir: mode) as NSString).lastPathComponent
   if empty != (mode ? "UNNAMED" : "unnamed") { exit(1) }
  }
  print("PASS: 26 real patient-path cases remain child directories; empty names get ordinary/DICOMDIR fallback")
 }
}
'''.replace('BLOCK', block)
with tempfile.TemporaryDirectory(prefix='horos-patient-component-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(program)
    flags = module_flags('IsiXDatabase', path / 'modules')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *flags, str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path / 'exports')], check=True)
