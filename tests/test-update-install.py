#!/usr/bin/env python3
"""Exercise the update download, verification and replacement with disposable bundles.

The production Swift sources are compiled with a driver. The download runs
through an injected URL protocol, never the network; the bundles are small
ad hoc applications in a temporary folder; the previous copy is retired inside
that folder, not in the user's Trash. No administrator dialog is shown and no
installed application is modified.

A published release is signed with a Developer ID and notarized, which no
fixture made here can be. That part reads an installed release, by default
/Applications/Isis DICOM Viewer.app or the bundle named in HOROS_TEST_RELEASE_APP; without
one the other parts still run and the test exits with status 2.
"""
from pathlib import Path
import hashlib
import os
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

DRIVER = r'''
import AppKit

final class Stub: URLProtocol, @unchecked Sendable {
    // Status, body chunks, and whether the response ever ends.
    nonisolated(unsafe) static var responses: [String: (Int, [Data], Bool)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, chunks, ends) = Self.responses[request.url!.path]!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if ends { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

@MainActor final class Box {
    var download: UpdateDownload?
    var result: Result<URL, UpdateInstallError>?
    var progress = [Int64]()
}

@main struct Driver {
    @MainActor static func fetch(_ path: String, to destination: URL, size: Int64, digest: String,
                                 cancelling: Bool = false) -> Box {
        let box = Box()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let archive = UpdateRelease.Archive(url: URL(string: "https://fixture.invalid" + path)!, size: size, sha256: digest)
        let download = UpdateDownload(archive: archive, destination: destination,
            progress: { received, expected in
                precondition(Thread.isMainThread && expected == size && received <= size)
                box.progress.append(received)
                if cancelling { box.download?.cancel() }
            },
            completion: { result in
                precondition(Thread.isMainThread && box.result == nil)
                box.result = result
            })
        box.download = download
        download.start(configuration: configuration)
        let deadline = Date().addingTimeInterval(20)
        while box.result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(box.result != nil, "download did not complete: " + path)
        return box
    }

    static func check(_ condition: Bool) { precondition(condition) }

    static func failure(_ body: () throws -> Void) -> UpdateInstallError? {
        do { try body(); return nil } catch let error as UpdateInstallError { return error } catch { preconditionFailure("\(error)") }
    }

    @MainActor static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let digest = CommandLine.arguments[2]
        let installed = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
        let good = try Data(contentsOf: root.appendingPathComponent("good.zip"))
        let size = Int64(good.count)
        let third = good.count / 3
        let chunks = [good[..<third], good[third..<(2 * third)], good[(2 * third)...]].map { Data($0) }
        Stub.responses = [
            "/good": (200, chunks, true),
            "/missing": (404, [Data("not found".utf8)], true),
            "/stalled": (200, [chunks[0]], false),
        ]

        // Download: the file is kept only with the published size and digest.
        let file = root.appendingPathComponent("downloaded.zip")
        let complete = fetch("/good", to: file, size: size, digest: digest)
        precondition(complete.result == .success(file))
        check(try Data(contentsOf: file) == good)
        precondition(complete.progress.last == size && complete.progress == complete.progress.sorted())
        let other = root.appendingPathComponent("other.zip")
        precondition(fetch("/good", to: other, size: size, digest: String(repeating: "0", count: 64)).result == .failure(.archiveMismatch))
        precondition(fetch("/good", to: other, size: size + 1, digest: digest).result == .failure(.archiveMismatch))
        precondition(fetch("/good", to: other, size: size - 1, digest: digest).result == .failure(.archiveMismatch))
        guard case .failure(.download(let reason)) = fetch("/missing", to: other, size: size, digest: digest).result,
              reason.contains("404") else { preconditionFailure("HTTP status accepted") }
        let cancelled = fetch("/stalled", to: other, size: size, digest: digest, cancelling: true)
        precondition(cancelled.result == .failure(.cancelled) && !cancelled.progress.isEmpty)
        precondition(!manager.fileExists(atPath: other.path))
        check(try UpdateDownload.sha256(of: file) == digest)
        print("PASS: download progress on the main queue, size and SHA-256 acceptance, HTTP failure, cancellation, no file kept on failure")

        // Extraction: exactly one application at the top of the archive.
        let application = try UpdateBundle.extract(file, into: root.appendingPathComponent("extracted"))
        precondition(application.lastPathComponent == "Isis DICOM Viewer.app")
        for name in ["two", "none", "corrupt"] {
            precondition(failure { _ = try UpdateBundle.extract(root.appendingPathComponent(name + ".zip"),
                into: root.appendingPathComponent("extracted-" + name)) } == .extraction)
        }

        // Verification: identity and build first, then the signature of one team.
        func release(_ build: String) -> UpdateRelease { UpdateRelease(feed: ["Horos": build])! }
        let identifier = "org.horosproject.disposable.update"
        func verify(_ app: URL, build: String = "2026100200", identifier: String = identifier,
                    installed: String? = "20220801", team: String = "AAAAAAAAAA") -> UpdateInstallError? {
            failure { try UpdateBundle.verify(app, release: release(build), identifier: identifier, installedBuild: installed, team: team) }
        }
        precondition(verify(application) == .signature)
        precondition(verify(application, build: "2026100201") == .wrongApplication)
        precondition(verify(application, identifier: "org.horosproject.other") == .wrongApplication)
        precondition(verify(application, installed: "2026100200") == .wrongApplication)
        precondition(verify(application, installed: "2026100300") == .wrongApplication)
        precondition(verify(application, team: "A\" or anchor apple or \"") == .signature)
        precondition(verify(root.appendingPathComponent("future/Isis DICOM Viewer.app")) == .unsupportedSystem)
        precondition(UpdateBundle.developerIDTeam(of: application) == nil)
        precondition(UpdateBundle.requirement(identifier: identifier, team: "AAAAAAAAAA") != nil)
        precondition(UpdateBundle.requirement(identifier: identifier, team: "A\"B") == nil)
        print("PASS: single-application extraction, build and identifier checks, system requirement, ad hoc bundle refused, requirement text not injectable")

        if let installed {
            let information = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")) as! [String: Any]
            let build = information["CFBundleVersion"] as! String
            let name = information["CFBundleIdentifier"] as! String
            guard let team = UpdateBundle.developerIDTeam(of: installed) else {
                preconditionFailure("the installed release is not a notarized Developer ID copy")
            }
            precondition(verify(installed, build: build, identifier: name, installed: "1", team: team) == nil)
            precondition(verify(installed, build: build, identifier: name, installed: "1", team: "AAAAAAAAAA") == .signature)
            print("PASS: installed Developer ID release accepted for its own team and refused for another")
        }

        // Replacement: the previous copy is moved aside, restored on failure, retired on success.
        let destination = root.appendingPathComponent("Applications/Isis DICOM Viewer.app")
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: destination.appendingPathComponent("marker"))
        precondition(UpdateBundle.location(of: destination) == .replaceable(authorization: false))
        precondition(UpdateBundle.location(of: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Isis DICOM Viewer.app")) == .translocated)
        var retired = [URL]()
        let retire: (URL) throws -> Void = { retired.append($0); try manager.removeItem(at: $0) }
        let absent = root.appendingPathComponent("absent.app")
        guard case .replacement = failure({ try UpdateBundle.replace(destination, with: absent, authorization: false, retire: retire) }) else {
            preconditionFailure("missing staged application accepted")
        }
        check(try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8) == "previous" && retired.isEmpty)
        check(try manager.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Isis DICOM Viewer.app"])
        try UpdateBundle.replace(destination, with: application, authorization: false, retire: retire)
        precondition(retired.count == 1 && retired[0].lastPathComponent.hasPrefix(".horos-previous-"))
        precondition(!manager.fileExists(atPath: application.path))
        precondition(!manager.fileExists(atPath: destination.appendingPathComponent("marker").path))
        precondition(manager.fileExists(atPath: destination.appendingPathComponent("Contents/MacOS/fixture").path))
        check(try manager.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Isis DICOM Viewer.app"])
        let link = root.appendingPathComponent("Applications/Link.app")
        try manager.createSymbolicLink(at: link, withDestinationURL: destination)
        guard case .replacement = failure({ try UpdateBundle.replace(link, with: absent, authorization: false, retire: retire) }) else {
            preconditionFailure("symbolic link destination followed")
        }
        print("PASS: replacement in place, rollback when the new copy cannot be moved, previous copy retired once, symbolic link refused")
    }
}
'''


def bundle(folder, minimum='11.0', name='Isis DICOM Viewer.app'):
    app = folder / name
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.disposable.update', 'CFBundleExecutable': 'fixture',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '2026100200', 'CFBundleShortVersionString': '4.0.0',
        'LSMinimumSystemVersion': minimum}))
    subprocess.run(['xcrun', 'clang', str(folder.parent / 'fixture.c'), '-o', str(macos / 'fixture')], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    return app


with tempfile.TemporaryDirectory(prefix='horos-update-install-') as folder:
    folder = Path(folder).resolve()
    (folder / 'fixture.c').write_text('int main(void) { return 0; }\n')
    for name in ('payload', 'future', 'two', 'none'):
        (folder / name).mkdir()
    app = bundle(folder / 'payload')
    bundle(folder / 'future', minimum='99.0')
    bundle(folder / 'two')
    bundle(folder / 'two', name='Other.app')
    (folder / 'none/readme.txt').write_text('no application here\n')
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(folder / 'good.zip')], check=True)
    for name in ('two', 'none'):
        subprocess.run(['/usr/bin/ditto', '-c', '-k', str(folder / name), str(folder / (name + '.zip'))], check=True)
    (folder / 'corrupt.zip').write_bytes(b'not a zip archive')
    digest = hashlib.sha256((folder / 'good.zip').read_bytes()).hexdigest()

    bridge = folder / 'Bridge.h'
    bridge.write_text('#import "HorosBoundedTask.h"\nBOOL PFAddInstalledApplicationToDock(NSString *path);\n')
    stub = folder / 'stub.m'
    stub.write_text('#import <Foundation/Foundation.h>\nBOOL PFAddInstalledApplicationToDock(NSString *path) { abort(); }\n')
    subprocess.run(['xcrun', 'clang', '-c', '-I', str(ROOT / 'Horos/Sources'), str(stub), '-o', str(folder / 'stub.o')], check=True)
    (folder / 'Driver.swift').write_text(DRIVER)
    sources = [ROOT / 'Horos/Sources' / name for name in
               ('UpdateFeedClient.swift', 'UpdateArchive.swift', 'HorosApplicationInstaller.swift')]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-import-objc-header', str(bridge),
                    '-I', str(ROOT / 'Horos/Sources'), *map(str, sources), str(folder / 'Driver.swift'), str(folder / 'stub.o'),
                    '-module-name', 'Horos', '-framework', 'AppKit', '-framework', 'Security',
                    '-o', str(folder / 'driver')], check=True)
    release = Path(os.environ.get('HOROS_TEST_RELEASE_APP', '/Applications/Isis DICOM Viewer.app'))
    arguments = [str(folder / 'driver'), str(folder), digest]
    if release.is_dir():
        arguments.append(str(release))
    subprocess.run(arguments, check=True, timeout=180)
    if not release.is_dir():
        print('skipped: no installed Developer ID release at %s (set HOROS_TEST_RELEASE_APP)' % release)
        sys.exit(2)
