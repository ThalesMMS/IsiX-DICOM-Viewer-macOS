#!/usr/bin/env python3
"""Each package carries one slice; plugins and helpers must carry the running process's.

The product is published as two packages, arm64 and x86_64. The auditor takes
the slice of the process that runs it: in an arm64 package nothing changes, and
in an x86_64 package a plugin or helper that only has arm64 is refused with a
message naming both architectures. The x86_64 behaviour is exercised through
the same functions with the process slice given explicitly, and the auditor is
also compiled as x86_64; that build runs only where this Mac can run it.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]


def compile_binary(destination, architectures):
    source = destination.with_suffix('.c')
    source.write_text('int main(void) { return 0; }\n')
    command = ['xcrun', 'clang']
    for architecture in architectures:
        command += ['-arch', architecture]
    subprocess.run(command + [str(source), '-o', str(destination)], check=True)


code = r'''
import Foundation

func expect(_ ok: Bool, _ message: String) {
    precondition(ok, message)
}

func packedPlugin(at folder: URL, name: String, executable: String) -> String {
    let bundle = folder.appendingPathComponent(name + ".horosplugin")
    try? FileManager.default.removeItem(at: bundle)  // the other slice's run made it already
    let macos = bundle.appendingPathComponent("Contents/MacOS")
    try! FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try! FileManager.default.copyItem(atPath: executable, toPath: macos.appendingPathComponent(name).path)
    let info: [String: Any] = [
        "CFBundleExecutable": name,
        "CFBundleIdentifier": "org.horosproject.qa." + name,
        "NSPrincipalClass": name
    ]
    (info as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
    return bundle.path
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let arm = folder.appendingPathComponent("Horos").path
let intelProduct = folder.appendingPathComponent("HorosIntel").path
let universal = folder.appendingPathComponent("HorosUniversal").path
let intelHelper = folder.appendingPathComponent("dciodvfy").path
let armHelper = folder.appendingPathComponent("dciodvfy-arm").path
let pluginIntel = packedPlugin(at: folder, name: "QAIntel",
                                executable: folder.appendingPathComponent("plugin-intel").path)
let pluginArm = packedPlugin(at: folder, name: "QAArm",
                             executable: folder.appendingPathComponent("plugin-arm").path)
let pluginUniversal = packedPlugin(at: folder, name: "QAUniversal",
                                   executable: folder.appendingPathComponent("plugin-universal").path)

// The process slice is the one this binary was compiled for.
#if arch(arm64)
expect(HorosArchitectureAudit.productArchitecture == "arm64", "arm64 process reports arm64")
#elseif arch(x86_64)
expect(HorosArchitectureAudit.productArchitecture == "x86_64", "x86_64 process reports x86_64")
#endif
expect(HorosArchitectureAudit.supportedArchitectures == ["arm64", "x86_64"], "two published slices")

// arm64 package: unchanged.
let productOK = HorosArchitectureAudit.productDiagnosis(at: arm, process: "arm64")
expect(productOK.accepted && productOK.architectures == ["arm64"] && productOK.diagnosis == "arm64-only",
       "arm64 product is accepted: \(productOK.diagnosis)")
let productUniversal = HorosArchitectureAudit.productDiagnosis(at: universal, process: "arm64")
expect(!productUniversal.accepted && productUniversal.diagnosis.contains("also contains x86_64")
       && productUniversal.diagnosis.contains("universal"),
       "universal product is not a publication path: \(productUniversal.diagnosis)")
let productIntelInArm = HorosArchitectureAudit.productDiagnosis(at: intelProduct, process: "arm64")
expect(!productIntelInArm.accepted && productIntelInArm.diagnosis.contains("has no arm64 slice"),
       "x86_64 product refused in arm64: \(productIntelInArm.diagnosis)")
expect(HorosArchitectureAudit.pluginDiagnosis(at: pluginIntel, process: "arm64") ==
       "This plugin is Intel-only (x86_64) and cannot load in this arm64 IsiX DICOM Viewer process. Obtain an arm64 plugin from its author.",
       "Intel-only plugin keeps its arm64 message")
expect(HorosArchitectureAudit.pluginDiagnosis(at: pluginArm, process: "arm64") == nil, "arm64 plugin loads in arm64")
expect(HorosArchitectureAudit.pluginDiagnosis(at: pluginUniversal, process: "arm64") == nil,
       "universal plugin that includes arm64 still loads")
let helperInArm = HorosArchitectureAudit.helperDiagnosis(at: intelHelper, process: "arm64")
expect(helperInArm == "dciodvfy is Intel-only (x86_64) and is not launched under Rosetta in this arm64 IsiX DICOM Viewer process. Rebuild the helper for arm64; the command remains in the bundle.",
       "Intel helper keeps its arm64 message: \(helperInArm ?? "nil")")
expect(HorosArchitectureAudit.helperDiagnosis(at: armHelper, process: "arm64") == nil, "arm64 helper runs in arm64")
expect(HorosArchitectureAudit.helperDiagnosis(at: folder.appendingPathComponent("missing").path, process: "arm64") == nil,
       "missing helper is not an architecture diagnosis")

// x86_64 package: its own slice is required, arm64-only code is refused and named.
let intelOK = HorosArchitectureAudit.productDiagnosis(at: intelProduct, process: "x86_64")
expect(intelOK.accepted && intelOK.architectures == ["x86_64"] && intelOK.diagnosis == "x86_64-only",
       "x86_64 product is accepted in its package: \(intelOK.diagnosis)")
let armInIntel = HorosArchitectureAudit.productDiagnosis(at: arm, process: "x86_64")
expect(!armInIntel.accepted && armInIntel.diagnosis.contains("has no x86_64 slice"), "arm64 product refused in x86_64")
let universalInIntel = HorosArchitectureAudit.productDiagnosis(at: universal, process: "x86_64")
expect(!universalInIntel.accepted && universalInIntel.diagnosis.contains("also contains arm64"),
       "universal product refused in x86_64: \(universalInIntel.diagnosis)")
expect(HorosArchitectureAudit.pluginDiagnosis(at: pluginArm, process: "x86_64") ==
       "This plugin is Apple Silicon-only (arm64) and cannot load in this x86_64 IsiX DICOM Viewer process. Obtain an x86_64 plugin from its author.",
       "arm64-only plugin named in x86_64")
expect(HorosArchitectureAudit.pluginDiagnosis(at: pluginIntel, process: "x86_64") == nil, "x86_64 plugin loads in x86_64")
expect(HorosArchitectureAudit.pluginDiagnosis(at: pluginUniversal, process: "x86_64") == nil,
       "universal plugin that includes x86_64 loads in x86_64")
let helperInIntel = HorosArchitectureAudit.helperDiagnosis(at: armHelper, process: "x86_64")
expect(helperInIntel == "dciodvfy-arm is Apple Silicon-only (arm64) and is not launched by this x86_64 IsiX DICOM Viewer process. Rebuild the helper for x86_64; the command remains in the bundle.",
       "arm64 helper named in x86_64: \(helperInIntel ?? "nil")")
expect(HorosArchitectureAudit.helperDiagnosis(at: intelHelper, process: "x86_64") == nil, "x86_64 helper runs in x86_64")

// The public entry points use the running process's slice.
let process = HorosArchitectureAudit.productArchitecture
expect(HorosArchitectureAudit.productDiagnosis(at: process == "arm64" ? arm : intelProduct).accepted,
       "the running slice's product is accepted")
expect(HorosArchitectureAudit.pluginDiagnosis(at: process == "arm64" ? pluginArm : pluginIntel) == nil,
       "the running slice's plugin loads")
expect(HorosArchitectureAudit.pluginDiagnosis(at: process == "arm64" ? pluginIntel : pluginArm) != nil,
       "the other slice's plugin is refused")

print("PASS (\(process) process): arm64 and x86_64 packages each require their own slice; universal products refused; foreign-only plugins and helpers named")
'''

with tempfile.TemporaryDirectory(prefix='horos-arch-dist-') as directory:
    folder = Path(directory)
    compile_binary(folder / 'Horos', ['arm64'])
    compile_binary(folder / 'HorosIntel', ['x86_64'])
    compile_binary(folder / 'HorosUniversal', ['arm64', 'x86_64'])
    compile_binary(folder / 'dciodvfy', ['x86_64'])
    compile_binary(folder / 'dciodvfy-arm', ['arm64'])
    compile_binary(folder / 'plugin-intel', ['x86_64'])
    compile_binary(folder / 'plugin-arm', ['arm64'])
    compile_binary(folder / 'plugin-universal', ['arm64', 'x86_64'])
    main = folder / 'main.swift'
    main.write_text(code)
    audit = str(root / 'Horos/Sources/HorosArchitectureAudit.swift')
    for architecture in ('arm64', 'x86_64'):
        subprocess.run(['xcrun', 'swiftc', '-target', architecture + '-apple-macos26.0', audit, str(main),
                        '-o', str(folder / ('test-' + architecture))], check=True)
    subprocess.run([str(folder / 'test-arm64'), str(folder)], check=True)
    # The x86_64 build of the auditor runs only where this Mac runs x86_64 code.
    rosetta = subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0
    if rosetta:
        subprocess.run([str(folder / 'test-x86_64'), str(folder)], check=True)
    else:
        print('note: the x86_64 build of the auditor compiled; this Mac cannot run x86_64 code, so it was not run')
