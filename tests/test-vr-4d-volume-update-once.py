#!/usr/bin/env python3
"""A change of every time of a 4D volume makes the 3D window read its current volume once.

A Revert, a filter or an undo in a 4D series tells of each time's volume
(OsirixUpdateVolumeData, one notification a time). The window's
-updateVolumeData: answered each of them by reading the current time's volume
again: ten times for a series of ten times, each a rebuild of the rendering.
It now reads the current volume when the notification is of the current time,
once for the lot; another time's volume is read when that time is shown. A
notification the view itself sent, or one of a volume of another window,
reads nothing, as before.

-updateVolumeData: is compiled as VRController+Movie.swift has it, with
stand-ins of the window and of its view.

    python3 tests/test-vr-4d-volume-update-once.py [<git revision>]

A revision reads the source from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the compiler

ROOT = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/VRController+Movie.swift'
revision = sys.argv[1] if len(sys.argv) > 1 else None
if revision:
    source = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{PATH}'], capture_output=True, check=True).stdout.decode('utf-8')
else:
    source = (ROOT / PATH).read_text(encoding='utf-8')
found = re.search(r'\n    public final (func updateVolumeData\(_ note: Notification!\) \{\n.*?\n    \})\n', source, re.S)
if not found:
    print('FAIL: -updateVolumeData: is not in VRController+Movie.swift as the test reads it')
    sys.exit(1)

HARNESS = r'''
import Foundation

final class View: NSObject {
    var read = 0
    func movieChangeSource(_ volume: UnsafeMutablePointer<Float>!) { read += 1 }
}

final class VRController {
    var pixLists: [NSMutableArray?], volumeData: [NSData?]
    var maxMovieIndex: Int16, curMovieIndexStorage: Int16 = 0
    let vrView: View? = View()
    static let horosReadFromFilesKey = "HorosVolumeReadFromFiles"
    /// What the window was told of readings of its volume from the files.
    var forgot: [Bool] = []
    func horosVolumeWasReadFromFiles(tiltGone: Bool) { forgot.append(tiltGone) }
    init(times: Int) {
        pixLists = (0..<times).map { _ in NSMutableArray() }
        volumeData = (0..<times).map { _ in NSMutableData(length: 16) }
        maxMovieIndex = Int16(times)
    }

    %(function)s
}

var failures: [String] = []
func announceAll(_ window: VRController) { for list in window.pixLists { window.updateVolumeData(Notification(name: Notification.Name("update"), object: list)) } }

let window = VRController(times: 10)
window.curMovieIndexStorage = 6
announceAll(window)
if window.vrView?.read != 1 { failures.append("a change of the ten times of a series read the current volume \(window.vrView?.read ?? -1) times, not once") }
window.vrView?.read = 0
window.updateVolumeData(Notification(name: Notification.Name("update"), object: window.pixLists[2]))
if window.vrView?.read != 0 { failures.append("a change of another time's volume read the current one") }
window.updateVolumeData(Notification(name: Notification.Name("update"), object: window.pixLists[6], userInfo: ["sender": window.vrView as Any]))
if window.vrView?.read != 0 { failures.append("the view's own notification made it read its volume again") }
window.updateVolumeData(Notification(name: Notification.Name("update"), object: NSMutableArray()))
if window.vrView?.read != 0 { failures.append("a change of another window's volume read this window's") }
window.updateVolumeData(Notification(name: Notification.Name("update"), object: window.pixLists[6]))
if window.vrView?.read != 1 { failures.append("a change of the current time's volume did not read it") }
// Read from its files again by another window or by the 2D viewer: the window
// forgets the copies it kept of the volume before, whichever of its times the
// notification is of, and not for another window's volume.
func readAgain(_ list: Any?, tiltGone: Bool = false) -> Notification {
    Notification(name: Notification.Name("update"), object: list, userInfo: [VRController.horosReadFromFilesKey: tiltGone])
}
window.vrView?.read = 0
window.updateVolumeData(readAgain(window.pixLists[2]))
if window.forgot != [false] || window.vrView?.read != 0 { failures.append("another time read from its files again: the window keeps its copies of the volume before, or reads the current time (\(window.forgot))") }
window.updateVolumeData(readAgain(window.pixLists[6], tiltGone: true))
if window.forgot != [false, true] || window.vrView?.read != 1 { failures.append("the current time read from its files again: the window keeps its copies, or does not read the volume (\(window.forgot))") }
window.updateVolumeData(readAgain(NSMutableArray()))
window.updateVolumeData(Notification(name: Notification.Name("update"), object: window.pixLists[6]))
if window.forgot.count != 2 { failures.append("a change that is not a reading from the files, or another window's volume, made the window forget its copies") }
let single = VRController(times: 1)
announceAll(single)
if single.vrView?.read != 1 { failures.append("a change of the volume of a series of one time read it \(single.vrView?.read ?? -1) times") }
for failure in failures { print("FAIL: " + failure) }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-vr-4d-update-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(HARNESS % {'function': found.group(1)})
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        print('FAIL: -updateVolumeData: does not compile with the stand-ins')
        sys.exit(1)
    ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    sys.stdout.write(ran.stdout)
    if ran.returncode != 0:
        if 'FAIL' not in ran.stdout:
            print('FAIL: the harness ended with', ran.returncode, ran.stderr.strip()[-300:])
        sys.exit(1)
print('PASS: a change of every time of a 4D volume makes the 3D window read its current volume once; one read from its files makes it forget its copies')
