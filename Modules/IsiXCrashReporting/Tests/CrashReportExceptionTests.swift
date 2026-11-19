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

/// The report of an Objective-C exception nobody caught, raised while a view
/// drew: the crashed thread only has the frameworks ending the application,
/// and the draft must carry the exception's name, reason and backtrace. The
/// reports are synthetic.
struct CrashReportExceptionTests {
    private let name = "IsiX DICOM Viewer"

    private func ips(body: [String: Any]) -> Data {
        let header: [String: Any] = ["app_name": name, "bug_type": "309", "app_version": "6.0.0", "build_version": "600",
                                     "os_version": "macOS 27.0.1 (26A434)"]
        var data = try! JSONSerialization.data(withJSONObject: header)
        data.append(UInt8(ascii: "\n"))
        data.append(try! JSONSerialization.data(withJSONObject: body))
        return data
    }

    private func frame(_ image: Int, _ symbol: String, _ location: Int) -> [String: Any] {
        ["imageIndex": image, "symbol": symbol, "symbolLocation": location, "imageOffset": 4096 + location]
    }

    /// The crashed thread and the images of every report here.
    private var drawBody: [String: Any] {
        ["cpuType": "ARM-64",
         "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "codes": "0x1"],
         "termination": ["indicator": "Trace/BPT trap: 5"],
         "faultingThread": 0,
         "usedImages": [["name": "IsiX DICOM Viewer"], ["name": "AppKit"], ["name": "CoreFoundation"],
                        ["name": "libobjc.A.dylib"], ["name": "QuartzCore"]],
         "threads": [["frames": [frame(1, "+[NSApplication _crashOnException:]", 256),
                                 frame(1, "_NSViewDrawRect", 164),
                                 frame(1, "-[NSViewBackingLayer display]", 1284),
                                 frame(4, "CA::Transaction::commit()", 3188)]]]]
    }

    private var exceptionBacktrace: [[String: Any]] {
        [frame(2, "__exceptionPreprocess", 164),
         frame(3, "objc_exception_throw", 88),
         frame(2, "+[NSException raise:format:]", 124),
         frame(1, "-[NSBezierPath lineToPoint:]", 96),
         frame(0, "ExampleChart.draw(_:)", 1420),
         frame(0, "@objc ExampleChart.draw(_:)", 52),
         frame(1, "_NSViewDrawRect", 136),
         frame(1, "-[NSViewBackingLayer display]", 1284)]
    }

    private var exceptionBody: [String: Any] {
        var body = drawBody
        body["lastExceptionBacktrace"] = exceptionBacktrace
        body["asi"] = ["CoreFoundation": ["*** Terminating app due to uncaught exception 'NSGenericException', "
                                          + "reason: 'No current point for line'"],
                       "libc++abi.dylib": ["terminating due to uncaught exception of type NSException"]]
        return body
    }

    private func draft(_ summary: CrashSummary) -> CrashReportDraft {
        CrashReportDraft(applicationName: name, summary: summary, report: URL(fileURLWithPath: "/tmp/\(name)-x.ips"))
    }

    @Test func theExceptionOfAReportIsSummarizedBeforeTheCrashedThread() throws {
        let summary = CrashSummary.of(report: ips(body: exceptionBody))
        #expect(summary.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(summary.exceptionName == "NSGenericException")
        #expect(summary.exceptionReason == "No current point for line")
        #expect(summary.exceptionFrames.count == 8)
        #expect(summary.exceptionFrames[3] == "AppKit  -[NSBezierPath lineToPoint:] + 96")
        #expect(summary.exceptionFrames[4] == "IsiX DICOM Viewer  ExampleChart.draw(_:) + 1420")
        #expect(summary.frames.first == "AppKit  +[NSApplication _crashOnException:] + 256")
        let issue = draft(summary).issueBody()
        #expect(issue.contains("""
        Uncaught exception:

        ```
        NSGenericException: No current point for line
        CoreFoundation  __exceptionPreprocess + 164
        libobjc.A.dylib  objc_exception_throw + 88
        CoreFoundation  +[NSException raise:format:] + 124
        AppKit  -[NSBezierPath lineToPoint:] + 96
        IsiX DICOM Viewer  ExampleChart.draw(_:) + 1420
        IsiX DICOM Viewer  @objc ExampleChart.draw(_:) + 52
        AppKit  _NSViewDrawRect + 136
        AppKit  -[NSViewBackingLayer display] + 1284
        ```

        Crashed thread:

        ```
        AppKit  +[NSApplication _crashOnException:] + 256
        """))
        let mail = draft(summary).mailBody
        let exception = try #require(mail.range(of: "Uncaught exception:\nNSGenericException: No current point for line\n"))
        let thread = try #require(mail.range(of: "Crashed thread:\n"))
        #expect(exception.lowerBound < thread.lowerBound)
        let items = URLComponents(url: draft(summary).issueURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "body" }?.value == issue)
    }

    @Test func theNameAndTheReasonComeFromTheFieldsOfTheirOwnToo() {
        var body = drawBody
        body["lastExceptionBacktrace"] = exceptionBacktrace
        body["exceptionReason"] = ["name": "NSRangeException", "class": "NSException", "type": "objc-exception",
                                   "composed_message": "*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds [0 .. 2]",
                                   "format_string": "%@", "arguments": ["x"]]
        var summary = CrashSummary.of(report: ips(body: body))
        #expect(summary.exceptionName == "NSRangeException")
        #expect(summary.exceptionReason == "*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds [0 .. 2]")
        // The line the application framework leaves when it ends the
        // application on an exception: a reason without a name.
        body["exceptionReason"] = nil
        body["asi"] = ["AppKit": ["Crashing on exception: No current point for line"]]
        summary = CrashSummary.of(report: ips(body: body))
        #expect(summary.exceptionName == nil)
        #expect(summary.exceptionLines().first == "No current point for line")
        // A backtrace alone is still shown.
        body["asi"] = nil
        summary = CrashSummary.of(report: ips(body: body))
        #expect(summary.exceptionReason == nil)
        #expect(summary.exceptionLines().first == "CoreFoundation  __exceptionPreprocess + 164")
    }

    @Test func anExceptionRaisedWhileDrawingLeavesOnlyBacktracesAsText() {
        var body = drawBody
        let lines = ["0   CoreFoundation                      0x0000000180000001 __exceptionPreprocess + 176",
                     "1   libobjc.A.dylib                     0x0000000180000002 objc_exception_throw + 88",
                     "2   AppKit                              0x0000000180000003 -[NSBezierPath lineToPoint:] + 96",
                     "3   IsiX DICOM Viewer                   0x0000000100000004 ExampleChart.draw(_:) + 1420",
                     "4   IsiX DICOM Viewer \t0x0000000100000005 @objc ExampleChart.draw(_:) + 52",
                     "5   AppKit                              0x0000000180000006 _NSViewDrawRect + 136"]
            + (6..<43).map { "\($0)   AppKit                              0x0000000180000007 function\($0) + \($0)" }
        body["asiBacktraces"] = [lines.joined(separator: "\n"), "0   Other   0x0000000180000008 other + 1"]
        let summary = CrashSummary.of(report: ips(body: body))
        #expect(summary.exceptionName == nil && summary.exceptionReason == nil)
        #expect(summary.exceptionFrames.count == CrashSummary.frameLimit)
        #expect(summary.exceptionFrames.prefix(6) == ["CoreFoundation  __exceptionPreprocess + 176",
                                                      "libobjc.A.dylib  objc_exception_throw + 88",
                                                      "AppKit  -[NSBezierPath lineToPoint:] + 96",
                                                      "IsiX DICOM Viewer  ExampleChart.draw(_:) + 1420",
                                                      "IsiX DICOM Viewer  @objc ExampleChart.draw(_:) + 52",
                                                      "AppKit  _NSViewDrawRect + 136"])
        // The block has no line of name and reason, and comes first, in the
        // issue, the mail and the text the window shows.
        #expect(draft(summary).issueBody().contains("Uncaught exception:\n\n```\nCoreFoundation  __exceptionPreprocess + 176\n"))
        let text = summary.text
        #expect(text.contains("Termination: Trace/BPT trap: 5\n\nUncaught exception:\nCoreFoundation  __exceptionPreprocess + 176\n"))
        #expect(text.contains("function14 + 14\n\nCrashed thread:\nAppKit  +[NSApplication _crashOnException:] + 256\n"))
        #expect(draft(summary).mailBody.contains(text))
        // The backtrace of the report's own is preferred.
        body["lastExceptionBacktrace"] = exceptionBacktrace
        #expect(CrashSummary.of(report: ips(body: body)).exceptionFrames.count == 8)
    }

    @Test func aFrameOfATextReportIsSplitAtItsAddress() {
        #expect(CrashSummary.frameLine(ofTextLine: "2   IsiX DICOM Viewer \t0x0000000100000004 -[ExampleView drawRect:] + 212")
                == "IsiX DICOM Viewer  -[ExampleView drawRect:] + 212")
        #expect(CrashSummary.frameLine(ofTextLine: "2\tIsiX DICOM Viewer\t0x0000000100000004\t0x100000000 + 4")
                == "IsiX DICOM Viewer  0x100000000 + 4")
        #expect(CrashSummary.frameLine(ofTextLine: "3   AppKit   0x0000000180000006 _NSViewDrawRect + 136") == "AppKit  _NSViewDrawRect + 136")
        #expect(CrashSummary.frameLine(ofTextLine: "not a frame") == nil)
    }

    @Test func aReportWithoutAnExceptionReadsAsBefore() {
        var body = drawBody
        // Information that is not an exception's is still left out.
        body["asi"] = ["libsystem_c.dylib": ["abort() called", "/Users/someone/Studies/DOE^JANE/IM0001.dcm"]]
        let summary = CrashSummary.of(report: ips(body: body))
        #expect(summary.exceptionName == nil && summary.exceptionReason == nil && summary.exceptionFrames.isEmpty)
        #expect(summary.exceptionLines().isEmpty)
        let frames = """
        AppKit  +[NSApplication _crashOnException:] + 256
        AppKit  _NSViewDrawRect + 164
        AppKit  -[NSViewBackingLayer display] + 1284
        QuartzCore  CA::Transaction::commit() + 3188
        """
        #expect(draft(summary).issueBody() == """
        **What happened**

        \(name) quit unexpectedly.

        **What I was doing**



        **Crash summary**

        - Version: 6.0.0 (600)
        - Architecture: arm64
        - macOS: macOS 27.0.1 (26A434)
        - Exception: EXC_BREAKPOINT (SIGTRAP)
        - Termination: Trace/BPT trap: 5

        Crashed thread:

        ```
        \(frames)
        ```

        **Crash report**

        The full report is \(name)-x.ips, in ~/Library/Logs/DiagnosticReports. \
        It can hold names of files and folders: check it before attaching it here.
        """)
        #expect(draft(summary).mailBody == """
        \(name) quit unexpectedly. The crash report is attached: \(name)-x.ips.

        Version: 6.0.0 (600)
        Architecture: arm64
        macOS: macOS 27.0.1 (26A434)
        Exception: EXC_BREAKPOINT (SIGTRAP)
        Termination: Trace/BPT trap: 5

        Crashed thread:
        \(frames)

        What was I doing when it happened:


        """)
    }

    @Test func aTextReportGivesItsExceptionToo() {
        let text = """
        Process:               IsiX DICOM Viewer [123]
        Version:               5.9 (590)
        Code Type:             X86-64 (Native)
        Exception Type:        EXC_CRASH (SIGABRT)

        Application Specific Information:
        *** Terminating app due to uncaught exception 'NSGenericException', reason: 'No current point
        for line'
        terminating with uncaught exception of type NSException
        abort() called

        Application Specific Backtrace 1:
        0   CoreFoundation                      0x00007fff00000001 __exceptionPreprocess + 250
        1   libobjc.A.dylib                     0x00007fff00000002 objc_exception_throw + 48
        2   AppKit                              0x00007fff00000003 -[NSBezierPath lineToPoint:] + 96
        3   IsiX DICOM Viewer                   0x0000000100000004 ExampleChart.draw(_:) + 1420
        4   AppKit                              0x00007fff00000005 _NSViewDrawRect + 136

        Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
        0   libsystem_kernel.dylib        0x00007fff00000006 __pthread_kill + 10
        1   IsiX DICOM Viewer             0x0000000100000007 0x100000000 + 7

        Thread 1:
        0   libsystem_kernel.dylib        0x00007fff00000008 __workq_kernreturn + 10
        """
        let summary = CrashSummary.of(report: Data(text.utf8))
        #expect(summary.exceptionName == "NSGenericException")
        #expect(summary.exceptionReason == "No current point for line")
        #expect(summary.exceptionFrames == ["CoreFoundation  __exceptionPreprocess + 250",
                                            "libobjc.A.dylib  objc_exception_throw + 48",
                                            "AppKit  -[NSBezierPath lineToPoint:] + 96",
                                            "IsiX DICOM Viewer  ExampleChart.draw(_:) + 1420",
                                            "AppKit  _NSViewDrawRect + 136"])
        #expect(summary.frames == ["libsystem_kernel.dylib  __pthread_kill + 10", "IsiX DICOM Viewer  0x100000000 + 7"])
        let issue = draft(summary).issueBody()
        #expect(issue.contains("Uncaught exception:\n\n```\nNSGenericException: No current point for line\nCoreFoundation  __exc"))
        // The same backtrace under the title newer text reports give it.
        let newer = text.replacingOccurrences(of: "Application Specific Backtrace 1:", with: "Last Exception Backtrace:")
        #expect(CrashSummary.of(report: Data(newer.utf8)).exceptionFrames == summary.exceptionFrames)
    }

    @Test func aReasonLosesPathsFileNamesAndUserNames() {
        let users = ["jsmith", "Jane Smith"]
        func clean(_ text: String) -> String? { CrashReportText.cleaned(text, userNames: users) }
        #expect(clean("Could not read /Users/jsmith/Studies/DOE^JANE/IM0001.dcm: no such file") == "Could not read <path>")
        #expect(clean("Could not read ~/Studies/Folder With Spaces/IM0001.dcm today") == "Could not read <path>")
        #expect(clean("Could not open file:///Volumes/Disk/Jane/IM0001.dcm") == "Could not open <path>")
        #expect(clean("The file “DOE^JANE.dcm” couldn’t be opened because it isn’t there.")
                == "The file “<removed>” couldn’t be opened because it isn’t there.")
        #expect(clean("No series named 'Chest of Jane' in \"/Users/jsmith/x y/z\" (2 tried)")
                == "No series named '<removed>' in \"<removed>\" (2 tried)")
        #expect(clean("Bad file IM0001.dcm, bad folder Studies/Jane, bad name DOE^JANE.")
                == "Bad file <file>, bad folder <path>, bad name <name>")
        #expect(clean("Report.final.PDF:12 was not written by JSmith for jane smith") == "<file>:12 was not written by <user> for <user>")
        #expect(clean("Fetching https://pacs.example.org/studies/1.2.3?name=DOE failed with an I/O error")
                == "Fetching <url> failed with an I/O error")
        // What says where the fault is stays.
        for kept in ["*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds [0 .. 2]",
                     "-[IsiX_DICOM_Viewer.ExampleChart setScale:]: unrecognized selector sent to instance 0x600000c0ffee",
                     "Invalid parameter not satisfying: width > 0.5 && ratio == 1/2",
                     "No current point for line"] {
            #expect(clean(kept) == kept)
        }
        #expect(clean("line one\n\tline `two` is three") == "line one line '<removed>' is three")
        #expect(clean("  \n") == nil)
        #expect(clean(String(repeating: "word ", count: 200))?.count == CrashReportText.reasonLimit + 1)

        // Through a whole report, of either format.
        var body = drawBody
        body["lastExceptionBacktrace"] = exceptionBacktrace
        body["exceptionReason"] = ["name": "NSInvalidArgumentException",
                                   "composed_message": "Could not draw IM0001.dcm of jsmith from /Users/jsmith/Studies/DOE^JANE/IM0001.dcm"]
        let summary = CrashSummary.of(report: ips(body: body), userNames: users)
        #expect(summary.exceptionReason == "Could not draw <file> of <user> from <path>")
        let text = """
        Application Specific Information:
        *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'Could not draw /Users/jsmith/Studies/DOE^JANE'

        """
        let ofText = CrashSummary.of(report: Data(text.utf8), userNames: users)
        #expect(ofText.exceptionName == "NSInvalidArgumentException" && ofText.exceptionReason == "Could not draw <path>")
        for draft in [draft(summary), draft(ofText)] {
            for text in [draft.mailBody, draft.issueBody(), draft.issueURL.absoluteString, draft.mailSubject, draft.issueTitle] {
                #expect(!text.contains("jsmith") && !text.contains("DOE") && !text.contains("Studies") && !text.contains("IM0001"))
            }
        }
    }

    @Test func theTitleNamesTheExceptionAndNeverItsReason() {
        // Two exceptions end the application the same way, in the same version.
        let generic = draft(CrashSummary.of(report: ips(body: exceptionBody))).issueTitle
        #expect(generic == "Crash: EXC_BREAKPOINT (SIGTRAP), NSGenericException in 6.0.0")
        var body = drawBody
        body["lastExceptionBacktrace"] = exceptionBacktrace
        body["exceptionReason"] = ["name": "NSRangeException",
                                   "composed_message": "*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds for DOE^JANE"]
        let range = draft(CrashSummary.of(report: ips(body: body)))
        #expect(range.issueTitle == "Crash: EXC_BREAKPOINT (SIGTRAP), NSRangeException in 6.0.0")
        #expect(!range.issueTitle.contains("beyond") && !range.issueTitle.contains("DOE"))
        #expect(range.issueTitle != generic)
        #expect(range.issueBody().contains("NSRangeException: *** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds"))
        let items = URLComponents(url: range.issueURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "title" }?.value == range.issueTitle)

        // The name alone, the name of a class, and a name with a namespace.
        #expect(draft(CrashSummary(exceptionName: "NSRangeException")).issueTitle == "Crash: NSRangeException")
        #expect(draft(CrashSummary(version: "6.0.0", exceptionName: "_Private.Fault2")).issueTitle == "Crash: _Private.Fault2 in 6.0.0")
        // A name that is not the name of a type says what a reason says: it stays in the body.
        for sentence in ["Could not draw the series of <user>", "Séries", "9lives", "No-series", "a/b", ""] {
            let summary = CrashSummary(version: "6.0.0", exception: "EXC_CRASH (SIGABRT)", exceptionName: sentence, exceptionReason: "reason")
            #expect(draft(summary).issueTitle == "Crash: EXC_CRASH (SIGABRT) in 6.0.0")
        }
        // The reason and the backtrace alone change nothing, nor does no exception at all.
        let unnamed = CrashSummary(version: "6.0.0", exception: "EXC_CRASH (SIGABRT)", exceptionReason: "No current point for line",
                                   exceptionFrames: ["CoreFoundation  __exceptionPreprocess + 176"])
        #expect(draft(unnamed).issueTitle == "Crash: EXC_CRASH (SIGABRT) in 6.0.0")
        #expect(draft(CrashSummary(version: "6.0.0", exception: "EXC_BAD_ACCESS (SIGSEGV)")).issueTitle == "Crash: EXC_BAD_ACCESS (SIGSEGV) in 6.0.0")
        #expect(draft(CrashSummary()).issueTitle == "Crash: \(name) quit unexpectedly")
    }

    @Test func theExceptionKeepsToTheFrameLimit() {
        var body = exceptionBody
        body["lastExceptionBacktrace"] = (0..<40).map { frame(0, "function\($0)", $0) }
        var summary = CrashSummary.of(report: ips(body: body))
        #expect(summary.exceptionFrames.count == CrashSummary.frameLimit)
        #expect(summary.exceptionFrames.last == "IsiX DICOM Viewer  function\(CrashSummary.frameLimit - 1) + \(CrashSummary.frameLimit - 1)")
        #expect(summary.exceptionLines(frameLimit: 3).count == 4)
        let short = draft(summary).issueBody(frameLimit: 2)
        #expect(short.contains("function1 + 1") && !short.contains("function2 + 2"))
        #expect(short.contains("_NSViewDrawRect + 164") && !short.contains("-[NSViewBackingLayer display]"))
        let lines = (0..<40).map { "\($0)   IsiX DICOM Viewer   0x0000000100000000 function\($0) + \($0)" }
        let text = "Last Exception Backtrace:\n" + lines.joined(separator: "\n") + "\n\nThread 0 Crashed:\n" + lines.joined(separator: "\n") + "\n"
        let ofText = CrashSummary.of(report: Data(text.utf8))
        #expect(ofText.exceptionFrames.count == CrashSummary.frameLimit && ofText.frames.count == CrashSummary.frameLimit)
        // Long frames of both lists are dropped until the address fits.
        summary.exceptionFrames = (0..<CrashSummary.frameLimit).map { "raised\($0)  " + String(repeating: "veryLongSymbolName", count: 40) }
        summary.frames = (0..<CrashSummary.frameLimit).map { "crashed\($0)  " + String(repeating: "veryLongSymbolName", count: 40) }
        let url = draft(summary).issueURL.absoluteString
        #expect(url.count <= CrashReportDraft.maximumIssueURLLength)
        #expect(url.contains("raised0") && url.contains("crashed0") && url.contains("NSGenericException"))
    }

    @Test func anAccountNamedAsAWordOfThePlaceholderIsReplacedOnce() {
        for _ in 0..<20 {
            let cleaned = CrashReportText.cleaned("account user (Test User) failed", userNames: ["user", "Test User", "user"])
            #expect(cleaned == "account <user> (<user>) failed")
        }
    }
}
