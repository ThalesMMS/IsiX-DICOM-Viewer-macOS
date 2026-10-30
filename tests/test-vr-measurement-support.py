#!/usr/bin/env python3
"""Exercise the real tool-selection guard and controller selection synchronization.

The view's -setCurrentTool: is Swift (VRView+Keyboard.swift), and so is
VRController's: the guard of the view and the two statements of the
controller that hand it the tool and select the tool it kept are compiled,
as written, into a Swift harness whose alert counts what it is shown."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
def source(path):
    return (subprocess.check_output(['git','show',sys.argv[1]+':'+path]) if len(sys.argv)>1 else (root/path).read_bytes()).decode('utf-8')
s=source('Horos/Sources/VRView+Keyboard.swift')
a=s.index('    func setCurrentTool(_ i: ToolMode) {\n')
a=s.index('{',a)+1;b=s.index('        let previousTool',a)
guard=s[a:b]
# VRController's -setCurrentTool: ends by handing the tool to the view and
# selecting in the tools matrix the tool the view kept.
s=source('Horos/Sources/VRController+Editing.swift');a=s.index('        vrView?.setCurrentTool(newTool)\n');b=s.index('\n    }',a)
sync=s[a:b]
if sync.split('\n')!=['        vrView?.setCurrentTool(newTool)','        toolsMatrixOutlet?.selectCell(withTag: Int(vrView?.currentTool().rawValue ?? 0))']:
    sys.exit('FAIL: VRController no longer selects the tool the view kept; this test needs a new look')
code=r'''
import AppKit
// The camera is the VTK adapter's: the view asks it whether it has one and
// whether it projects in parallel.
final class VolumeView {
    var hasCamera = false
    var cameraParallelProjection = false
}
enum ToolMode: Int16 { case tMesure = 1, t3DRotate = 2, tWL = 3 }
var alerts = 0
// Stands in for AppKit's alert: a declaration of the program hides the module's.
enum AlertStyle { case informational }
final class NSAlert {
    var alertStyle = AlertStyle.informational
    var messageText = ""
    var informativeText = ""
    func addButton(withTitle title: String) {}
    @discardableResult func runModal() -> Int {
        precondition(informativeText.contains("parallel projection"))
        alerts += 1
        return 1
    }
}
final class View {
    var horos_vtk = VolumeView()
    var horos_currentTool = ToolMode.tWL
    func currentTool() -> ToolMode { horos_currentTool }
    func setCurrentTool(_ i: ToolMode) {GUARD
        horos_currentTool = i
    }
}
final class Controller {
    var vrView: View?
    var toolsMatrixOutlet: NSMatrix?
    func setCurrentTool(_ newTool: ToolMode) {
SYNC
    }
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let c = Controller()
    let view = View()
    c.vrView = view
    let matrix = NSMatrix(frame: NSMakeRect(0, 0, 120, 40), mode: .radioModeMatrix, cellClass: NSButtonCell.self, numberOfRows: 1, numberOfColumns: 3)
    for i in 0..<3 { matrix.cell(atRow: 0, column: i)?.tag = i + 1 }
    c.toolsMatrixOutlet = matrix
    let camera = VolumeView()
    camera.hasCamera = true
    camera.cameraParallelProjection = false
    view.horos_vtk = camera
    view.horos_currentTool = .tWL
    c.setCurrentTool(.tMesure)
    if view.currentTool() != .tWL || matrix.selectedCell()?.tag != Int(ToolMode.tWL.rawValue) || alerts != 1 {
        FileHandle.standardError.write("FAIL: perspective request bypassed guard or toolbar selection diverged\n".data(using: .utf8)!)
        exit(1)
    }
    camera.cameraParallelProjection = true
    c.setCurrentTool(.tMesure)
    precondition(view.currentTool() == .tMesure && matrix.selectedCell()?.tag == 1 && alerts == 1)
    camera.cameraParallelProjection = false
    c.setCurrentTool(.t3DRotate)
    precondition(view.currentTool() == .t3DRotate)
    c.setCurrentTool(.tMesure)
    precondition(view.currentTool() == .t3DRotate && matrix.selectedCell()?.tag == 2 && alerts == 2)
    print("PASS: unsupported request explains restriction and preserves current tool/selection; parallel request succeeds")
}
'''.replace('GUARD',guard).replace('SYNC',sync)
with tempfile.TemporaryDirectory(prefix='horos-vr-support-') as d:
    p=Path(d);(p/'test.swift').write_text(code)
    subprocess.run(['xcrun','swiftc',str(p/'test.swift'),'-o',str(p/'test')],check=True)
    sys.exit(subprocess.run([str(p/'test')]).returncode)
