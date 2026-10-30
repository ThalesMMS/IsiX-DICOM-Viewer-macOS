#!/usr/bin/env python3
"""The crash report window appears once for a new crash of this application,
and its two buttons prepare the expected mail and GitHub page.

CrashReportWindowController.swift is compiled as it is, with the
IsiXCrashReporting module and a GitHub-build stand-in for DistributionChannel,
into a driver that runs with CFFIXED_USER_HOME in a temporary folder and keeps
its preferences in a suite of its own. Synthetic reports are written to a
temporary DiagnosticReports folder:

- the first look finds the newest new crash of this application; a second
  look finds nothing (the window appears once); a crash of another
  application, an older crash and a hang report are never offered;
- the window holds the explanation and the privacy notice and its buttons;
- the mail: NSSharingService for composing mail is configured as the
  "Send by Email" button would use it (recipient, subject, the body and the
  report as items) and only inspected: perform(withItems:) is never called,
  so no mail application opens and nothing is sent. The mailto: fallback is
  checked as a URL;
- the GitHub page: the new-issue URL of the public repository, with title and
  body, is checked as a URL and never opened.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

NAME = 'IsiX DICOM Viewer'
IDENTIFIER = 'thalesmms.isis.workstation'

DRIVER = r'''
import AppKit
import IsiXCrashReporting

func check(_ condition: Bool, _ label: String) {
    if !condition { print("FAIL: \(label)"); exit(1) }
}
let arguments = CommandLine.arguments
guard NSHomeDirectory() == arguments[1] else {
    print("FAIL: the home folder is \(NSHomeDirectory()), not the temporary \(arguments[1])")
    exit(3)
}
let reports = URL(fileURLWithPath: arguments[2])
let suite = "isix.crash-report-test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
// The look before the crash: an hour ago.
defaults.set(Date(timeIntervalSinceNow: -3600), forKey: CrashReportFinder.lastCheckKey)

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let first = CrashReportWindowController.newReport(defaults: defaults, directories: [reports],
                                                      baseName: "%NAME%", bundleIdentifier: "%IDENTIFIER%")
    check(first?.lastPathComponent == "%NAME%-2026-10-29-120000.ips", "first look: \(String(describing: first))")
    let second = CrashReportWindowController.newReport(defaults: defaults, directories: [reports],
                                                       baseName: "%NAME%", bundleIdentifier: "%IDENTIFIER%")
    check(second == nil, "the second look found \(String(describing: second))")
    print("ok: a new crash of this application is offered once; older, other and hang reports are not")

    let controller = CrashReportWindowController(report: first!, applicationName: "%NAME%")
    let window = controller.window!
    var texts: [String] = []
    var buttons: [String] = []
    func collect(_ view: NSView) {
        if let button = view as? NSButton { buttons.append(button.title) }
        else if let field = view as? NSTextField { texts.append(field.stringValue) }
        else if let text = view as? NSTextView { texts.append(text.string) }
        view.subviews.forEach(collect)
    }
    collect(window.contentView!)
    check(window.title == "Crash Report", "title \(window.title)")
    check(texts.contains { $0.contains("quit unexpectedly") }, "no explanation: \(texts)")
    check(texts.contains { $0.contains("Nothing is sent without you") && $0.contains("patients") }, "no privacy notice: \(texts)")
    check(texts.contains { $0.contains("EXC_BAD_ACCESS (SIGSEGV)") && $0.contains("__pthread_kill") }, "no summary: \(texts)")
    check(!texts.joined().contains("patient-name"), "a path of the report is shown")
    for title in ["Send by Email…", "Open an Issue on GitHub…", "Show Report in Finder", "Close"] {
        check(buttons.contains(title), "no button \(title): \(buttons)")
    }
    let size = window.contentView!.fittingSize
    check(size.width >= 560 && size.height > 200 && size.height < 900, "window size \(size)")
    print("ok: the window explains the crash, warns about patient data and offers the three ways, \(Int(size.width))x\(Int(size.height))")

    // The mail, as "Send by Email" composes it, inspected and never performed.
    let draft = controller.draft
    check(draft.mailRecipients == ["thalesmmsradio@gmail.com"], "recipients \(draft.mailRecipients)")
    check(draft.mailSubject == "%NAME% crash report: 6.0.0 (600), arm64", "subject \(draft.mailSubject)")
    check(controller.mailItems.count == 2 && (controller.mailItems[1] as? URL) == first, "the report is not attached")
    check((controller.mailItems[0] as? String)?.contains(first!.lastPathComponent) == true, "the body does not name the report")
    if let service = NSSharingService(named: .composeEmail) {
        service.recipients = draft.mailRecipients
        service.subject = draft.mailSubject
        check(service.recipients == ["thalesmmsradio@gmail.com"] && service.subject == draft.mailSubject, "service fields")
        print("ok: mail service configured: \(service.recipients ?? []), \(service.subject ?? ""), can compose: \(service.canPerform(withItems: controller.mailItems)), not performed")
    } else {
        print("note: no mail sharing service on this Mac; the mailto: fallback applies")
    }
    let mailto = URLComponents(url: controller.mailtoURL, resolvingAgainstBaseURL: false)!
    check(mailto.scheme == "mailto" && mailto.path == "thalesmmsradio@gmail.com", "mailto \(controller.mailtoURL)")
    check(mailto.queryItems?.first { $0.name == "subject" }?.value == draft.mailSubject, "mailto subject")
    print("ok: mailto fallback \(mailto.path), subject kept")

    // The GitHub page, never opened.
    let issue = URLComponents(url: draft.issueURL, resolvingAgainstBaseURL: false)!
    check(issue.host == "github.com" && issue.path == "/ThalesMMS/IsiX-DICOM-Viewer-macOS/issues/new", "issue \(draft.issueURL)")
    let items = Dictionary(uniqueKeysWithValues: (issue.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    check(items["title"] == "Crash: EXC_BAD_ACCESS (SIGSEGV) in 6.0.0", "issue title \(items["title"] ?? "")")
    for line in ["- Version: 6.0.0 (600)", "- Architecture: arm64", "__pthread_kill + 8", first!.lastPathComponent] {
        check(items["body"]?.contains(line) == true, "issue body lacks \(line)")
    }
    check(!draft.issueURL.absoluteString.contains("patient-name"), "the issue carries a path")
    print("ok: issue page \(issue.path) with version, architecture and crash summary, not opened")
}
'''


def ips(name, bug_type='309', body=None):
    header = {'app_name': name, 'bundleID': IDENTIFIER, 'bug_type': bug_type, 'app_version': '6.0.0',
              'build_version': '600', 'os_version': 'macOS 27.0.1 (26A434)'}
    return json.dumps(header) + '\n' + json.dumps(body or {})


BODY = {'cpuType': 'ARM-64', 'procPath': '/Users/patient-name/Downloads/IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer',
        'exception': {'type': 'EXC_BAD_ACCESS', 'signal': 'SIGSEGV'}, 'faultingThread': 0,
        'usedImages': [{'name': 'libsystem_kernel.dylib', 'path': '/usr/lib/system/libsystem_kernel.dylib'}],
        'threads': [{'frames': [{'imageIndex': 0, 'symbol': '__pthread_kill', 'symbolLocation': 8}]}]}

with tempfile.TemporaryDirectory(prefix='isix-crash-window-') as temporary:
    work = Path(temporary)
    reports = work / 'DiagnosticReports'
    reports.mkdir()
    now = time.time()
    for name, text, age in ((f'{NAME}-2026-10-29-120000.ips', ips(NAME, body=BODY), 60),
                            (f'{NAME}-2026-10-29-110000.ips', ips(NAME, body=BODY), 120),
                            (f'{NAME}-2026-10-28-090000.ips', ips(NAME, body=BODY), 7200),
                            (f'{NAME}-2026-10-29-115900.ips', ips(NAME, '288'), 30),
                            (f'{NAME}-2026-10-29-115800.ips', ips(NAME + ' Helper', body=BODY), 20),
                            ('Other-2026-10-29-115700.ips', ips('Other', body=BODY), 10)):
        path = reports / name
        path.write_text(text)
        os.utime(path, (now - age, now - age))
    source = work / 'CrashReportWindowController.swift'
    shutil.copy(root / 'Horos/Sources/CrashReportWindowController.swift', source)
    channel = work / 'DistributionChannel.swift'
    channel.write_text('enum DistributionChannel { static let isAppStore = false }\n')
    main = work / 'main.swift'
    main.write_text(DRIVER.replace('%NAME%', NAME).replace('%IDENTIFIER%', IDENTIFIER))
    target = ['-target', 'arm64-apple-macos15.0']
    try:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target, '-module-name', 'Horos',
                        *isix_modules.module_flags('IsiXCrashReporting', work / 'modules', target),
                        str(source), str(channel), str(main), '-o', str(work / 'driver')],
                       check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        print('FAIL: the driver did not build:', error.stderr[-3000:])
        sys.exit(1)
    home = work / 'home'
    home.mkdir()
    result = subprocess.run([str(work / 'driver'), str(home), str(reports)], capture_output=True, text=True,
                            timeout=60, env=dict(os.environ, CFFIXED_USER_HOME=str(home)))
    print(result.stdout.strip())
    if result.returncode != 0:
        print('FAIL: driver exited with', result.returncode, result.stderr[-2000:])
        sys.exit(1)
print('PASS: the crash report window appears once, and prepares the mail and the GitHub page without sending or opening them')
