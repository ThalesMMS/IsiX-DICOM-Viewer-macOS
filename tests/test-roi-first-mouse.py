#!/usr/bin/env python3
"""A measure starts with the first click in a viewer that is not the key window.

With a ROI or measuring tool, -[DCMView acceptsFirstMouse:] answered NO, so the
first click in the second of two tiled viewers only made it the key window: the
two-click Length lost its first point there and measuring in turn felt broken.
It now answers YES when the application is active - the click comes from
another window of this application - and NO only when the click brings the
application forward from another one. Tools that are not ROIs accept it as
before.

The method is Swift (DCMView+Mouse.swift) and its rule IsiXImaging's
ViewInput: the method is compiled from the source, in a stand-in view, with
the module and an application whose activity the test sets, and run.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DCMView+Mouse.swift').read_text()
start = source.index('    @objc(acceptsFirstMouse:)\n')
method = source[start:source.index('\n    }\n', start) + 7]

DRIVER = r'''
import AppKit
import IsiXImaging

nonisolated(unsafe) var active = false
final class TestApplication: NSApplication {
    override var isActive: Bool { active }
}
struct ToolMode { var rawValue: Int16 }
class DCMView: NSView {
    var horos_currentTool = ToolMode(rawValue: 0)
}
extension DCMView {
METHOD
}
@main struct Check {
    @MainActor static func main() {
        _ = TestApplication.shared
        let view = DCMView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        var failures = 0
        let cases: [(Int16, Bool, Bool, String)] = [
            (5, true, true, "a ROI tool, the click from another viewer of the application"),
            (5, false, false, "a ROI tool, the click bringing the application forward"),
            (20, true, true, "another ROI tool, within the application"),
            (0, false, true, "window level, from another application"),
            (0, true, true, "window level, within the application"),
        ]
        for (tool, isActive, expected, what) in cases {
            view.horos_currentTool = ToolMode(rawValue: tool)
            active = isActive
            if view.acceptsFirstMouse(for: nil) != expected { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); failures += 1 }
        }
        if failures > 0 { exit(1) }
        print("PASS: a measure starts with the first click in another viewer of the application")
    }
}
'''.replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='horos-first-mouse-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    flags = isix_modules.module_flags('IsiXImaging', work / 'module')
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *flags, str(work / 'main.swift'), '-o', str(work / 'check')],
                           capture_output=True, text=True)
    if built.returncode:
        print('FAIL: the method does not compile\n' + built.stderr[-1500:])
        sys.exit(1)
    run = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    sys.exit(run.returncode)
