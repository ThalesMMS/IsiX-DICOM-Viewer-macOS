#!/usr/bin/env python3
"""A restart asks, schedules the reopening, then quits, and the URL scheme alert restarts.

ApplicationRestart.swift is compiled alone with stand-ins for the three steps:
no application is quit or opened. The wiring of the lifecycle and of the
"Activate & Restart" button is read from the sources.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path, source_text  # noqa: E402

DRIVER = r'''
import Foundation

struct Unschedulable: LocalizedError {
    var errorDescription: String? { "no shell" }
}

@MainActor final class Steps {
    var events = [String]()
    var agrees = true
    var schedules = true
    func restart() -> ApplicationRestart {
        ApplicationRestart(agree: { self.events.append("agree"); return self.agrees },
                           reopen: { self.events.append("reopen"); if !self.schedules { throw Unschedulable() } },
                           quit: { self.events.append("quit") })
    }
}

@main struct Driver {
    @MainActor static func main() {
        // The reopening is scheduled while the process is there, before the quit.
        let agreed = Steps()
        precondition(agreed.restart().run() == .quitting)
        precondition(agreed.events == ["agree", "reopen", "quit"], "\(agreed.events)")

        // A refused quit schedules nothing: no shell is left waiting for a
        // process that goes on.
        let refused = Steps()
        refused.agrees = false
        precondition(refused.restart().run() == .refused)
        precondition(refused.events == ["agree"], "\(refused.events)")

        // Without a reopening the application stays, and the reason is given.
        let stuck = Steps()
        stuck.schedules = false
        precondition(stuck.restart().run() == .notScheduled("no shell"))
        precondition(stuck.events == ["agree", "reopen"], "\(stuck.events)")

        // The copy that opens is given the arguments of the launch, after the
        // executable. A preference that no longer holds goes with its value,
        // wherever it stands, and one that ends the arguments goes alone.
        let launch = ["/Applications/Viewer.app/Contents/MacOS/Viewer", "-DATABASELOCATION", "1", "-hideListenerError", "NO",
                      "-DATABASELOCATIONURL", "/Volumes/It's here/a b", "--LoadPlugin", "/tmp/A.isixplugin", "-ProtectedMode"]
        precondition(ApplicationRestart.arguments(ofLaunch: launch) == Array(launch.dropFirst()))
        precondition(ApplicationRestart.arguments(ofLaunch: launch, dropping: ["DATABASELOCATION", "DATABASELOCATIONURL", "ProtectedMode"])
                     == ["-hideListenerError", "NO", "--LoadPlugin", "/tmp/A.isixplugin"])
        precondition(ApplicationRestart.arguments(ofLaunch: [], dropping: ["DATABASELOCATION"]).isEmpty)
        precondition(ApplicationRestart.arguments(ofLaunch: ["/Viewer"]).isEmpty)
        print("PASS: restart order, refusal and a reopening that cannot be scheduled")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-restart-') as folder:
    folder = Path(folder)
    driver = folder / 'Driver.swift'
    driver.write_text(DRIVER)
    binary = folder / 'driver'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    str(source_path('ApplicationRestart')), str(driver), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


lifecycle = source_text('ApplicationLifecycle')


def body(source, signature):
    block = source[source.index(signature):]
    return block[:block.index('\n    }\n')]


# The Quit command's question; the database window that agreed before its folder
# was moved is not asked again. Both are the one sequence.
check("restart(sender, agree: { self.quit.agreeNow() }, droppingArgumentsFor: [])"
      in body(lifecycle, '@discardableResult func restart(_ sender: Any?)'), 'the restart no longer asks as the Quit command does')
check('restart(sender, agree: { true }, droppingArgumentsFor: stale)'
      in body(lifecycle, '@discardableResult func restartAlreadyAgreed(_ sender: Any?, droppingArgumentsFor stale: Set<String>)'),
      'a restart agreed to beforehand asks again, or no longer is the same sequence')
restart = body(lifecycle, 'private func restart(_ sender: Any?, agree: @escaping @MainActor () -> Bool,')
check('agree: agree,' in restart, 'the restart no longer asks what its caller gives it to ask')
check('HorosNativeInstallOperations().relaunch(Bundle.main.bundleURL, diskImage: nil, arguments: arguments)' in restart,
      'the restart no longer reopens the running copy through the shell that waits for the process')
# A copy given its database for one launch must not come back on the one of the Documents folder.
check('let arguments = ApplicationRestart.arguments(ofLaunch: ProcessInfo.processInfo.arguments, dropping: stale)' in restart,
      'the restart no longer reopens the copy with the arguments of this launch')
check('quit: { self.finishTermination(sender) }' in restart, 'the restart no longer ends in the rest of quitting')

# The move of a database out of a synchronized folder: one copy at a time, and
# the copy that opens is not sent back to the folder that was moved.
detector = source_text('ICloudDriveDetector')
relaunch = detector[detector.index('private func relaunch(databaseMoved: Bool) {'):]
relaunch = relaunch[:relaunch.index('\n    }\n')]
check('Process.launchedProcess' not in detector, 'the detector starts a second copy while the first one still quits')
check('lifecycle.restartAlreadyAgreed(self, droppingArgumentsFor: stale)' in relaunch,
      'the detector no longer restarts through the lifecycle, without a second question')
check('[location.mode.name, location.folder.name, defaultLocation.mode.name, defaultLocation.folder.name] : []' in relaunch
      and 'databaseMoved' in relaunch, 'a moved database is given again by the arguments of the launch')
check('case .notScheduled(let reason)' in relaunch and 'Restart IsiX DICOM Viewer to apply this change.' in relaunch
      and relaunch.index('Restart IsiX DICOM Viewer to apply this change.') < relaunch.index('lifecycle.finishTermination(self)'),
      'a restart that cannot be scheduled no longer tells the user before the application quits')
check(detector.count('self.relaunch(databaseMoved: false)') == 2 and detector.count('self.relaunch(databaseMoved: true)') == 1
      and detector.index('try FileManager.default.moveItem(atPath: databasePath, toPath: newDatabasePath)')
      < detector.index('self.relaunch(databaseMoved: true)'),
      'the detector no longer tells a moved database from one left in place')

handler = source_text('ExternalRequestHandler')
branch = handler[handler.index('if result == HorosAlertPanel.alternateResponse {'):]
branch = branch[:branch.index('            return\n')]
turned_on = 'preferences.set(true, for: NetworkPreferences.xmlrpcServer)'
saved = 'processGraph.preferences.synchronize()'
restarted = 'controller.lifecycle.restart(controller)'
check(turned_on in branch and saved in branch and restarted in branch,
      '"Activate & Restart" no longer turns the scheme on, saves it and restarts')
check(turned_on in branch and restarted in branch and branch.index(turned_on) < branch.index(saved) < branch.index(restarted),
      'the scheme is not saved before the application restarts')
check('controller.terminate(controller)' not in branch, '"Activate & Restart" only quits again')
check('case .notScheduled(let reason)' in branch and 'Restart IsiX DICOM Viewer to apply this change.' in branch,
      'a restart that cannot be scheduled no longer tells the user what is left to do')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the lifecycle restarts through the reopening shell and "Activate & Restart" uses it')
