//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXCrashReporting

/// Which crash reports are new and this application's, and the mail and
/// issue made of one, on synthetic reports in a temporary folder. Nothing is
/// sent and nothing is opened; the window and the mail service are
/// tests/test-crash-report-window.py.
struct CrashReportTests {
    private let name = "IsiX DICOM Viewer"
    private let identifier = "thalesmms.isis.workstation"

    private func ips(name: String? = nil, bundle: String? = nil, bugType: Any = "309", body: [String: Any] = [:]) -> Data {
        var header: [String: Any] = ["app_name": name ?? self.name, "bug_type": bugType, "app_version": "6.0.0",
                                     "build_version": "600", "os_version": "macOS 27.0.1 (26A434)"]
        if let bundle { header["bundleID"] = bundle }
        var data = try! JSONSerialization.data(withJSONObject: header)
        data.append(UInt8(ascii: "\n"))
        data.append(try! JSONSerialization.data(withJSONObject: body))
        return data
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IsiXCrashReportingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, _ file: String, in folder: URL, age: TimeInterval) throws -> URL {
        let url = folder.appendingPathComponent(file)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url
    }

    @Test func fileNamesOfBothFormats() {
        #expect(CrashReportFinder.kind(ofFileName: "\(name)-2026-10-29-101500.ips", baseName: name) == .ips)
        #expect(CrashReportFinder.kind(ofFileName: "\(name)_2026-10-29-101500_Mac.ips", baseName: name) == .ips)
        #expect(CrashReportFinder.kind(ofFileName: "\(name)_2020-01-01-101500_Mac.crash", baseName: name) == .crash)
        #expect(CrashReportFinder.kind(ofFileName: "\(name)-2020-01-01.crash", baseName: name) == nil)
        #expect(CrashReportFinder.kind(ofFileName: "Other-2026-10-29-101500.ips", baseName: name) == nil)
        #expect(CrashReportFinder.kind(ofFileName: "\(name)-2026-10-29.diag", baseName: name) == nil)
    }

    @Test func onlyCrashesOfThisApplicationCount() {
        func check(_ data: Data) -> Bool {
            CrashReportFinder.isCrash(header: CrashReportFinder.parts(ofReport: data)!.header, baseName: name, bundleIdentifier: identifier)
        }
        #expect(check(ips()))
        #expect(check(ips(bundle: identifier)))
        #expect(check(ips(bugType: 109)))
        #expect(!check(ips(name: name + " Helper")))
        #expect(!check(ips(bundle: "org.example.other")))
        #expect(!check(ips(bugType: "288")))
    }

    @Test func newReportsAreFoundOnceOldestFirst() throws {
        let reports = try folder()
        defer { try? FileManager.default.removeItem(at: reports) }
        let lastCheck = Date(timeIntervalSinceNow: -3600)
        let old = try write(ips(), "\(name)-old.ips", in: reports, age: 7200)
        let newer = try write(ips(), "\(name)-newer.ips", in: reports, age: 60)
        let newest = try write(Data("Process: x\n".utf8), "\(name)_newest_Mac.crash", in: reports, age: 10)
        _ = try write(ips(name: "Other"), "\(name)-other.ips", in: reports, age: 30)
        _ = try write(ips(bugType: "288"), "\(name)-hang.ips", in: reports, age: 20)
        _ = try write(ips(), "Other-1.ips", in: reports, age: 5)
        let found = CrashReportFinder.reports(in: [reports], since: lastCheck, baseName: name, bundleIdentifier: identifier)
        #expect(found.map(\.lastPathComponent) == [newer, newest].map(\.lastPathComponent))
        // Without a date of the last look, every crash of this application.
        #expect(CrashReportFinder.reports(in: [reports], since: nil, baseName: name, bundleIdentifier: identifier).count == 3)
        // Looked at now, nothing is new: the window appears once.
        #expect(CrashReportFinder.reports(in: [reports], since: Date(), baseName: name, bundleIdentifier: identifier).isEmpty)
        #expect(!found.map(\.lastPathComponent).contains(old.lastPathComponent))
        #expect(CrashReportOffer.reportToOffer(isAppStore: false, newReports: found)?.lastPathComponent == newest.lastPathComponent)
        #expect(CrashReportOffer.reportToOffer(isAppStore: true, newReports: found) == nil)
        #expect(CrashReportOffer.reportToOffer(isAppStore: false, newReports: []) == nil)
    }

    @Test func theRealHomeIsSearchedOnlyWhenItDiffers() {
        let local = URL(fileURLWithPath: "/Library")
        let user = URL(fileURLWithPath: "/Users/u/Library")
        #expect(CrashReportFinder.directories(localLibrary: local, userLibrary: user, realHome: "/Users/u").map(\.path)
                == ["/Library/Logs/DiagnosticReports", "/Users/u/Library/Logs/DiagnosticReports"])
        let sandbox = URL(fileURLWithPath: "/Users/u/Library/Containers/x/Data/Library")
        #expect(CrashReportFinder.directories(localLibrary: local, userLibrary: sandbox, realHome: "/Users/u").count == 3)
    }

    private var crashBody: [String: Any] {
        ["cpuType": "ARM-64", "procPath": "/Users/patient-name/Downloads/IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer",
         "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "codes": "0x1"],
         "termination": ["indicator": "Segmentation fault: 11"],
         "asi": ["libsystem_c.dylib": ["/Users/patient-name/Studies/DOE^JOHN/IM0001.dcm"]],
         "faultingThread": 0,
         "usedImages": [["name": "IsiX DICOM Viewer", "path": "/Users/patient-name/Downloads/IsiX DICOM Viewer.app"],
                        ["name": "libsystem_kernel.dylib", "path": "/usr/lib/system/libsystem_kernel.dylib"]],
         "threads": [["frames": [["imageIndex": 1, "symbol": "__pthread_kill", "symbolLocation": 8],
                                 ["imageIndex": 0, "imageOffset": 1234]]]]]
    }

    @Test func theSummaryKeepsNamesAndLeavesPathsOut() {
        let summary = CrashSummary.of(report: ips(body: crashBody))
        #expect(summary.version == "6.0.0" && summary.build == "600")
        #expect(summary.architecture == "arm64")
        #expect(summary.exception == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(summary.termination == "Segmentation fault: 11")
        #expect(summary.frames == ["libsystem_kernel.dylib  __pthread_kill + 8", "IsiX DICOM Viewer  image offset 1234"])
        var translated = crashBody
        translated["cpuType"] = "X86-64"
        translated["translated"] = true
        #expect(CrashSummary.of(report: ips(body: translated)).architecture == "x86_64 (Rosetta)")
        let draft = CrashReportDraft(applicationName: name, summary: summary, report: URL(fileURLWithPath: "/tmp/\(name)-x.ips"))
        for text in [draft.mailBody, draft.issueBody(), draft.issueURL.absoluteString, draft.mailSubject, draft.issueTitle] {
            #expect(!text.contains("patient-name") && !text.contains("DOE"))
        }
    }

    @Test func aTextReportIsSummarizedToo() {
        let text = """
        Process:               IsiX DICOM Viewer [123]
        Path:                  /Users/patient-name/Downloads/IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer
        Version:               5.9 (590)
        Code Type:             X86-64 (Translated)
        OS Version:            Mac OS X 10.15.7 (19H2)
        Exception Type:        EXC_BAD_ACCESS (SIGSEGV)

        Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
        0   libsystem_kernel.dylib        0x00007fff6b8e933a __pthread_kill + 10
        1   IsiX DICOM Viewer             0x000000010a1b2c3d 0x10a000000 + 1780797

        Thread 1:
        """
        let summary = CrashSummary.of(report: Data(text.utf8))
        #expect(summary.version == "5.9" && summary.build == "590")
        #expect(summary.architecture == "x86_64 (Rosetta)")
        #expect(summary.exception == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(summary.frames.first == "libsystem_kernel.dylib  __pthread_kill + 10")
        #expect(summary.frames.count == 2)
    }

    @Test func theMailAndTheIssueAreFilledIn() throws {
        let report = URL(fileURLWithPath: "/Users/u/Library/Logs/DiagnosticReports/\(name)-2026-10-29-101500.ips")
        let draft = CrashReportDraft(applicationName: name, summary: CrashSummary.of(report: ips(body: crashBody)), report: report)
        #expect(draft.mailRecipients == ["thalesmmsradio@gmail.com"])
        #expect(draft.mailSubject == "\(name) crash report: 6.0.0 (600), arm64")
        #expect(draft.mailBody.contains("\(name)-2026-10-29-101500.ips"))
        #expect(draft.mailBody.contains("Exception: EXC_BAD_ACCESS (SIGSEGV)"))
        let url = draft.issueURL
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "github.com")
        #expect(components.path == "/ThalesMMS/IsiX-DICOM-Viewer-macOS/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["title"] == "Crash: EXC_BAD_ACCESS (SIGSEGV) in 6.0.0")
        #expect(items["body"]?.contains("- Version: 6.0.0 (600)") == true)
        #expect(items["body"]?.contains("- Architecture: arm64") == true)
        #expect(items["body"]?.contains("__pthread_kill + 8") == true)
        #expect(!url.absoluteString.contains("horos-workbench"))
    }

    @Test func aLongReportStillFitsGitHubsLimit() {
        var summary = CrashSummary(version: "6.0.0", exception: "EXC_CRASH (SIGABRT)")
        summary.frames = (0..<CrashSummary.frameLimit).map { "image\($0)  " + String(repeating: "veryLongSymbolName", count: 40) + " + \($0)" }
        let draft = CrashReportDraft(applicationName: name, summary: summary, report: URL(fileURLWithPath: "/tmp/r.ips"))
        #expect(draft.issueURL.absoluteString.count <= CrashReportDraft.maximumIssueURLLength)
        #expect(draft.issueURL.absoluteString.contains("image0"))
    }
}
