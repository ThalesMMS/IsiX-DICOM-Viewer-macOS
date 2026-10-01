#!/usr/bin/env python3
"""A drop on the FlyThru steps table moves steps only when it is one (#971).

FlyThruStepsArrayController, the steps table's data source, reorders the
steps by drag and drop. It accepted any drop whose destination was its table:
the drag's source was not checked, the row numbers were read from the
pasteboard with NSKeyedUnarchiver.unarchiveObject(with:), which instantiates
whatever class the payload names, and the first row was truncated to Int32
and used without checking it was a step. The private pasteboard type does not
say where a drag comes from: any application can write it.

Now the destination and the drag's source must both be the steps table before
the pasteboard is read; the rows are decoded with
unarchivedObject(ofClass: NSIndexSet.self, from:); and the set must not be
empty, every row must be a step and the destination row must be in
0...count, before anything changes. Every dragged step moves, in order.

FlyThruStepsArrayController.swift is compiled as it is, with doubles for the
FlyThru controller, its adapter and Camera; the drags are an object that
answers -draggingSource and -draggingPasteboard, on a private pasteboard.

Valid moves, written by the controller's own -tableView:writeRowsWithIndexes:
toPasteboard: and by the former non-secure writer: down, up, to the end, and
two rows at once. Refused, with the steps and their camera indexes unchanged:
a drag from another table (same type, a valid index set), one with no source,
a drop on another table, no payload, a truncated one, a payload of another
class (an array, a string, a marker class whose -initWithCoder: counts its
runs), an empty set, rows past the steps (7, 2^32 + 1 - which the Int32
truncation made row 1 - and Int.max - 1), and a destination row outside
0...count.

`<git revision>` as an optional argument reads the source from that
revision: the negative control, where the refusals fail.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/FlyThruStepsArrayController.swift'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

bridge = r'''
#import <Cocoa/Cocoa.h>

/// A drag: only the source and the pasteboard, which is what the table's
/// data source reads.
@interface HarnessDrag : NSObject <NSDraggingInfo>
- (instancetype)initWithSource:(nullable id)source pasteboard:(NSPasteboard *)pasteboard;
@end
'''

drag = r'''
#import "Bridge.h"

@implementation HarnessDrag {
    id _source;
    NSPasteboard *_pasteboard;
}
- (instancetype)initWithSource:(id)source pasteboard:(NSPasteboard *)pasteboard
{
    if ((self = [super init])) { _source = source; _pasteboard = pasteboard; }
    return self;
}
- (id)draggingSource { return _source; }
- (NSPasteboard *)draggingPasteboard { return _pasteboard; }
@end
'''

doubles = r'''
import Cocoa

@objc(Camera)
final class Camera: NSObject {
    @objc dynamic var index: Int32 = 0
    @objc dynamic var previewImage: NSImage?
    let name: String
    init(_ name: String) { self.name = name }
    init?(dictionary: [AnyHashable: Any]?) { name = "imported" }
}

class FlyThruAdapter: NSObject {
    func setCurrentViewToCamera(_ aCamera: Camera?) {}
    func getCurrentCameraImage(_ highQuality: Bool) -> NSImage? { nil }
}

class FlyThru: NSObject {
    func exportToXML() -> NSMutableDictionary { NSMutableDictionary() }
}

class FlyThruController: NSObject {
    @objc var flyThru: FlyThru?
    @objc var hidePlayBox = false
    @objc var hideExportBox = false
    var ftAdapter: FlyThruAdapter?
    var currentCamera: Camera?
}
'''

main = r'''
import Cocoa

var failures: [String] = []
func fail(_ reason: String) { failures.append(reason) }

var markerRuns = 0
/// Records that a payload had it instantiated.
@objc(HorosDropMarker)
final class DropMarker: NSObject, NSCoding {
    override init() { super.init() }
    init?(coder: NSCoder) { markerRuns += 1; super.init() }
    func encode(with coder: NSCoder) {}
}

// The steps controller is the main actor's, as its window (#961).
MainActor.assumeIsolated {
let type = NSPasteboard.PasteboardType("FlyThruTableViewDataType")
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }

let table = NSTableView()
let otherTable = NSTableView()
let controller = FlyThruStepsArrayController()
controller.setValue(table, forKey: "tableview")
let names = ["c1", "c2", "c3", "c4", "c5"]

@MainActor func reset() {
    controller.content = NSMutableArray(array: names.map { Camera($0) })
    controller.resetCameraIndexes()
}

@MainActor func steps() -> [String] { (controller.arrangedObjects as! [Camera]).map { $0.name } }
@MainActor func indexes() -> [Int32] { (controller.arrangedObjects as! [Camera]).map { $0.index } }

/// The payload the table writes for `rows`.
@MainActor func written(_ rows: IndexSet) -> Data? {
    pasteboard.clearContents()
    guard controller.tableView(table, writeRowsWith: rows, to: pasteboard) else { return nil }
    return pasteboard.data(forType: type)
}

@MainActor func put(_ data: Data?) {
    pasteboard.clearContents()
    pasteboard.declareTypes([type], owner: nil)
    if let data { pasteboard.setData(data, forType: type) }
}

@MainActor @discardableResult
func drop(_ data: Data?, row: Int, source: Any? = table, on destination: NSTableView = table) -> (NSDragOperation, Bool) {
    put(data)
    let info = HarnessDrag(source: source, pasteboard: pasteboard)
    let validation = controller.tableView(destination, validateDrop: info, proposedRow: row, proposedDropOperation: .above)
    put(data)
    let accepted = controller.tableView(destination, acceptDrop: info, row: row, dropOperation: .above)
    return (validation, accepted)
}

// Valid moves.
let moves: [(IndexSet, Int, [String], String)] = [
    (IndexSet([0]), 3, ["c2", "c3", "c1", "c4", "c5"], "step 1 dropped above step 4"),
    (IndexSet([1]), 5, ["c1", "c3", "c4", "c5", "c2"], "step 2 dropped at the end"),
    (IndexSet([4]), 0, ["c5", "c1", "c2", "c3", "c4"], "step 5 dropped at the top"),
    (IndexSet([2]), 2, ["c1", "c2", "c3", "c4", "c5"], "step 3 dropped where it is"),
    (IndexSet([0, 2]), 5, ["c2", "c4", "c5", "c1", "c3"], "steps 1 and 3 dropped at the end"),
    (IndexSet([1, 3]), 1, ["c1", "c2", "c4", "c3", "c5"], "steps 2 and 4 dropped above step 2"),
]
for (rows, row, expected, label) in moves {
    reset()
    guard let payload = written(rows) else { fail("\(label): the table wrote no rows"); continue }
    let (validation, accepted) = drop(payload, row: row)
    if validation != .move { fail("\(label): the drop is not validated as a move") }
    if !accepted { fail("\(label): refused") }
    if steps() != expected { fail("\(label): the steps are \(steps()), not \(expected)") }
    if indexes() != [1, 2, 3, 4, 5] { fail("\(label): the camera indexes are \(indexes())") }
}

// The former writer's payload, a keyed archive without secure coding, still moves a step.
reset()
if !drop(NSKeyedArchiver.archivedData(withRootObject: NSIndexSet(index: 0)), row: 3).1 || steps() != moves[0].2 {
    fail("the former writer's payload no longer moves a step: \(steps())")
}

// Refusals: nothing changes.
@MainActor func refused(_ label: String, _ data: Data?, row: Int = 2, source: Any? = table, on destination: NSTableView = table,
             checkValidation: Bool = false) {
    reset()
    markerRuns = 0
    let (validation, accepted) = drop(data, row: row, source: source, on: destination)
    if accepted { fail("\(label): accepted") }
    if checkValidation && validation != [] { fail("\(label): validated as \(validation.rawValue)") }
    if steps() != names { fail("\(label): the steps became \(steps())") }
    if indexes() != [1, 2, 3, 4, 5] { fail("\(label): the camera indexes became \(indexes())") }
    if markerRuns != 0 { fail("\(label): the marker class was instantiated") }
}

let valid = written(IndexSet([0]))!
refused("a drag from another table with the same type and a valid index set", valid, source: otherTable, checkValidation: true)
refused("a drag without a source", valid, source: nil, checkValidation: true)
refused("a drag whose source is not a table", valid, source: NSObject(), checkValidation: true)
refused("a drop on another table", valid, on: otherTable, checkValidation: true)
refused("no payload", nil)
refused("an empty payload", Data())
refused("a truncated payload", valid.dropLast(12))
refused("a payload that is no archive", Data("FlyThruTableViewDataType".utf8))
refused("an array of rows", NSKeyedArchiver.archivedData(withRootObject: [0] as NSArray))
refused("a string", NSKeyedArchiver.archivedData(withRootObject: "0" as NSString))
refused("the marker class", NSKeyedArchiver.archivedData(withRootObject: DropMarker()))
refused("an index set inside the marker's array", NSKeyedArchiver.archivedData(withRootObject: [DropMarker(), NSIndexSet(index: 0)] as NSArray))
refused("an empty index set", written(IndexSet())!)
refused("row 7 of 5 steps", written(IndexSet([7]))!)
refused("row 2^32 + 1, which the Int32 truncation made row 1", written(IndexSet([4_294_967_297]))!)
refused("rows 1 and 2^32 + 1", written(IndexSet([1, 4_294_967_297]))!)
refused("row Int.max - 1", written(IndexSet([Int.max - 1]))!)
refused("destination row -1", valid, row: -1)
refused("destination row 6 of 5 steps", valid, row: 6)
refused("destination row 2^32 + 1", valid, row: 4_294_967_297)

for failure in failures { print("FAIL: \(failure)") }
print("done")
exit(failures.isEmpty ? 0 : 1)
}
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-flythru-drop-') as tmp:
    p = Path(tmp)
    (p / 'FlyThruStepsArrayController.swift').write_bytes(read(PATH))
    (p / 'Bridge.h').write_text(bridge)
    (p / 'Drag.m').write_text(drag)
    (p / 'Doubles.swift').write_text(doubles)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-w', '-I', str(p), str(p / 'Drag.m'),
                            '-o', str(p / 'Drag.o')], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-2000:])
        failures.append('the drag double does not compile')
    if not failures:
        build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(p / 'Bridge.h'),
                                str(p / 'FlyThruStepsArrayController.swift'), str(p / 'Doubles.swift'),
                                # The controller's main-actor callbacks (#961).
                                str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                                str(p / 'main.swift'), str(p / 'Drag.o'), '-o', str(p / 'test')],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-3000:])
            failures.append('the steps controller does not compile')
    if not failures:
        done = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=120)
        failures += [line[6:] for line in done.stdout.splitlines() if line.startswith('FAIL: ')]
        if 'done' not in done.stdout.splitlines():
            failures.append(f'the harness stopped with status {done.returncode}: {done.stderr[-800:]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: FlyThru steps move only on a drop from their own table with valid rows; external drags, '
      'bad payloads, empty sets and rows or destinations outside the steps change nothing')
