#!/usr/bin/env python3
"""The query window can sort on how much of a study is already here.

The percentage existed already, in the tooltip and as a pie next to the name, and
four places worked it out the same two ways: divide the local file count by the
remote one and clamp to 1. That reads a remote total of zero - what a node that
does not send NumberOfStudyRelatedInstances gives you - as 0%, which is
indistinguishable from a study none of which has arrived; and it reads more files
locally than the node reports as 100%, which is the one case where the counts
agreeing proves least.

HorosLocalCompleteness keeps the three states apart. Compile its Swift value,
then execute the production controller methods, taken from the Swift of the
Query window, with a real AppKit outline and the query node's copying children
accessors, transcribed from the Swift node, whose source is checked to copy the
same way. Only the database count boundary is substituted; series order,
selection and refresh use the production code.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
completeness = root / 'Horos/Sources/LocalCompleteness.swift'
results_source = root / 'Horos/Sources/QueryController+Results.swift'
controller = results_source.read_text(encoding='utf-8')

DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String) { print(key + "\t" + value) }

func row(_ name: String, _ local: Int, _ remote: NSNumber?) -> LocalCompleteness {
    let value = LocalCompleteness(localCount: local, remoteCount: remote)
    emit(name + ".text", value.text)
    emit(name + ".sort", String(format: "%.4f", value.sortValue))
    emit(name + ".complete", value.isComplete ? "yes" : "no")
    emit(name + ".known", value.remoteCountIsKnown ? "yes" : "no")
    emit(name + ".fraction", String(format: "%.4f", value.fraction))
    emit(name + ".explanation", value.explanation)
    return value
}

let none = row("none", 0, 10)
let half = row("half", 5, 10)
let all = row("all", 10, 10)
let unknown = row("unknown", 4, nil)
let zeroTotal = row("zeroTotal", 4, 0)
let excess = row("excess", 12, 10)
let nothingAtAll = row("nothingAtAll", 0, nil)

// Sorting is numeric, and the unknown total is not a low percentage.
let ordered = [all, unknown, half, excess, none].sorted { $0.compare($1) == .orderedAscending }
emit("order", ordered.map { $0.text }.joined(separator: " | "))
'''

# --- the value, compiled and run ---------------------------------------------
results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-completeness-') as directory:
        # Top-level statements are only allowed in a file called main.swift.
        (Path(directory) / 'main.swift').write_text(DRIVER)
        binary = Path(directory) / 'completeness'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(completeness), str(Path(directory) / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the completeness value does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {
        'none.text': '0% (0/10)', 'none.complete': 'no', 'none.sort': '0.0000',
        'half.text': '50% (5/10)', 'half.complete': 'no', 'half.sort': '0.5000',
        'all.text': '100% (10/10)', 'all.complete': 'yes', 'all.sort': '1.0000',
        # The node said nothing. That is not zero per cent, and it is not
        # complete either.
        'unknown.text': '? (4 local)', 'unknown.complete': 'no', 'unknown.known': 'no',
        'unknown.sort': '-1.0000', 'unknown.fraction': '0.0000',
        # A total of zero is the same as no total: it is what a node that does
        # not fill the field sends.
        'zeroTotal.text': '? (4 local)', 'zeroTotal.known': 'no',
        # More here than the node reports is not proof that nothing is missing.
        'excess.text': '>100% (12/10)', 'excess.complete': 'no',
        'nothingAtAll.text': '?',
    }
    for key, value in expected.items():
        if results.get(key) != value:
            failures.append('%s is %r, expected %r' % (key, results.get(key), value))
    if results.get('half.explanation') != '5 of 10 here; 5 still to retrieve.':
        failures.append('the explanation does not say what is left: %r'
                        % results.get('half.explanation'))
    if 'did not say' not in results.get('unknown.explanation', ''):
        failures.append('an unknown total is not explained: %r' % results.get('unknown.explanation'))
    # Ascending: unknown, then 0%, then 50%, then 100%, then more than the node says.
    order = results.get('order', '')
    if order != '? (4 local) | 0% (0/10) | 50% (5/10) | 100% (10/10) | >100% (12/10)':
        failures.append('the sort order is %r' % order)

# --- the column ---------------------------------------------------------------
for expected, missing in (
        (r'NSTableColumn\(identifier: NSUserInterfaceItemIdentifier\("localCompleteness"\)\)', 'there is no completeness column'),
        (r'sortDescriptorPrototype = NSSortDescriptor\(key: "localCompleteness"', 'the column cannot be sorted on'),
        (r'case "localCompleteness":\s*\n\s*value = self\.displayedCompletenessForItem\(item\)\?\.text',
         'the column has no value')):
    if not re.search(expected, controller):
        failures.append(missing)

# One place reads the two counts, so the column, the tooltip and the pie agree.
# The remaining readers are the auto-retrieve decisions, which are a different
# question - whether to fetch again - and are left alone here.
def body(signature):
    at = controller.find(signature)
    if at < 0:
        failures.append('%s is gone' % signature.split(':')[0])
        return ''
    opening = controller.index('{', at)
    depth, index = 0, opening
    while index < len(controller):
        if controller[index] == '{':
            depth += 1
        elif controller[index] == '}':
            depth -= 1
            if depth == 0:
                return controller[opening:index + 1]
        index += 1
    return ''


TOOLTIP = 'public func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell,'
CELL = 'public func outlineView(_ outlineView: NSOutlineView, willDisplayCell cell: Any,'
VALUE = 'func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?)'
SORT = 'nonisolated func sortArray() -> [NSSortDescriptor]'
FROZEN = 'nonisolated static func frozenCompleteness(of row: Any,'
for signature, what in ((TOOLTIP, 'the tooltip'), (CELL, 'the cell'), (VALUE, 'the column')):
    if 'rawNoFiles' in body(signature):
        failures.append('%s works the percentage out for itself again' % what)
painted = [body(TOOLTIP), body(CELL), body(VALUE), body(SORT) + body(FROZEN)]
if any('displayedCompletenessForItem(' not in text for text in painted) or 'frozenCompleteness(of:' not in body(SORT):
    failures.append('the column, the tooltip, the pie and the sort do not all use one value')

# The column is read on every repaint; its inventory refresh must not wait on
# the database from the main thread.
reader = body('nonisolated func inventoryCompleteness(forItem item: Any?, inventory: RetrieveInventory)')
if 'refreshRetrieveInventoryWithoutWaiting()' not in reader or re.search(r'refreshRetrieveInventory\(\)', reader):
    failures.append('the completeness value refreshes the inventory synchronously')

# The sort compares rows, because completeness is not a property of the node.
sort = body(SORT)
if 'localCompleteness' not in sort or 'NSSortDescriptor(key: "self", ascending: descriptor.ascending) { a, b in' not in sort:
    failures.append('sorting by completeness does not compare the rows')

# A pie is a proportion; an unknown total has none to draw.
pie = controller[controller.find('NSImage.pieChartImage(withPercentage: Float(completeness.fraction))') - 600:]
pie = pie[:700]
if 'remoteCountIsKnown' not in pie:
    failures.append('a pie is still drawn when the node did not say how many it holds')

# Execute the actual controller methods with an AppKit outline. The local
# database boundary returns explicit counts; the Swift value is tested above.
def member(signature):
    """The declaration of `signature` in the Swift source, with its attributes."""
    at = controller.find(signature)
    if at < 0:
        failures.append('%s is gone' % signature)
        return ''
    line = controller.rfind('\n', 0, at) + 1
    while True:
        previous = controller.rfind('\n', 0, line - 1) + 1
        if line == 0 or not controller[previous:line].strip().startswith('@'):
            break
        line = previous
    return controller[line:at] + controller[at:controller.index('{', at)] + body(signature)


methods = [member(signature) for signature in (
    SORT, FROZEN, 'func sortResultsPreservingSelection()', 'func reloadResultsAfterLocalChange()',
    'public func executeRefresh(_ sender: Any?)',
    'func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor])',
    'func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int',
    'func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any?',
    'func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any?) -> Bool')]

HARNESS = r"""
import AppKit

// What the production methods use of the rest of the app: the query nodes, with
// the node's copying children accessors, the exception bridge, and the window
// state they read. The completeness read from the database is the substitute.
class DCMTKQueryNode: NSObject {
    @objc var name: String? = "Same"
    @objc var time: NSNumber?
    @objc var date: NSNumber? = 1
    @objc var value: NSNumber?
    var reads = 0
    required override init() { super.init() }
    private var childrenStorage: NSMutableArray? = NSMutableArray()
    NODE_CHILDREN
    @objc(queryWithValues:)
    func query(withValues values: [Any]?) { setChildren([]) }
}
final class DCMTKStudyQueryNode: DCMTKQueryNode {}
final class DCMTKSeriesQueryNode: DCMTKQueryNode {}
final class DCMTKRootQueryNode: DCMTKQueryNode {}

enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}

@MainActor public final class QueryController: NSObject {
    struct WindowState { var sortDescriptors: [NSSortDescriptor] = [] }
    var outlineView: NSOutlineView!
    nonisolated(unsafe) var resultArray = NSMutableArray()
    nonisolated(unsafe) var performingCFind = false
    nonisolated(unsafe) var progressIndicator: NSProgressIndicator! = NSProgressIndicator()
    nonisolated(unsafe) var windowState = WindowState()
    nonisolated(unsafe) var DatabaseIsEdited = false
    nonisolated(unsafe) static var currentController: QueryController?
    nonisolated class func current() -> QueryController? { currentController }
    nonisolated class func currentAuto() -> QueryController? { nil }
    func captureWindowState() { windowState.sortDescriptors = outlineView.sortDescriptors }
    func readLocalSnapshot() {}
    @objc(computeStudyArrayInstanceUID:)
    nonisolated func computeStudyArrayInstanceUID(_ sender: NSNumber?) {}
    nonisolated static func synchronized<T>(_ object: AnyObject?, _ body: () throws -> T) rethrows -> T { try body() }
    nonisolated static func log(_ error: Error, _ function: String) { print(function, error) }
    /// The database boundary: the completeness the row's value stands for.
    nonisolated func displayedCompletenessForItem(_ item: Any?) -> LocalCompleteness? {
        guard let node = item as? DCMTKQueryNode, let value = node.value?.doubleValue else { return nil }
        node.reads += 1
        return value < 0 ? LocalCompleteness(localCount: 4, remoteCount: nil)
                         : LocalCompleteness(localCount: Int((value * 100).rounded()), remoteCount: 100)
    }
}

extension QueryController {
METHODS
}
"""

DRIVER = r"""
import AppKit

MainActor.assumeIsolated {
    _ = NSApplication.shared
    func node(_ type: DCMTKQueryNode.Type, _ value: Double, _ time: Int) -> DCMTKQueryNode {
        let n = type.init(); n.value = NSNumber(value: value); n.time = NSNumber(value: time); return n
    }
    func local(_ ascending: Bool) -> NSSortDescriptor { NSSortDescriptor(key: "localCompleteness", ascending: ascending) }
    func values(_ nodes: Any?) -> [Double] { ((nodes as? [DCMTKQueryNode]) ?? []).map { $0.value!.doubleValue } }
    func check(_ condition: Bool, _ what: String) { if !condition { print("FAIL: " + what); exit(1) } }

    let c = QueryController(); QueryController.currentController = c
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    c.outlineView = outline
    outline.allowsMultipleSelection = true
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.perform(Selector(("setDataSource:")), with: c)
    let full = node(DCMTKStudyQueryNode.self, 1, 1), half = node(DCMTKStudyQueryNode.self, 0.5, 2)
    let empty = node(DCMTKStudyQueryNode.self, 0, 3), unknown = node(DCMTKStudyQueryNode.self, -1, 4)
    let excess = node(DCMTKStudyQueryNode.self, 1.2, 5)
    c.resultArray.addObjects(from: [full, half, empty, unknown, excess])
    full.setChildren([node(DCMTKSeriesQueryNode.self, 1, 1), node(DCMTKSeriesQueryNode.self, 0.5, 2), node(DCMTKSeriesQueryNode.self, 0, 3)])
    outline.reloadData()
    outline.selectRowIndexes(IndexSet(0..<2), byExtendingSelection: false)
    outline.sortDescriptors = [local(true)]
    check(values(c.resultArray as? [Any]) == [-1, 0, 0.5, 1, 1.2], "Ascending numeric order")
    check(outline.selectedRowIndexes.count == 2 && outline.isRowSelected(outline.row(forItem: full)) && outline.isRowSelected(outline.row(forItem: half)),
          "Preserve multiple selected studies")
    for case let n as DCMTKQueryNode in c.resultArray { check(n.reads == 1, "Read each row once per sort") }
    outline.expandItem(full)
    check(values(full.children()) == [0, 0.5, 1], "First expansion sorts series")
    let selectedSeries = full.children()[1] as AnyObject
    outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: selectedSeries)), byExtendingSelection: false)
    outline.sortDescriptors = [local(false)]
    check(values(c.resultArray as? [Any]) == [1.2, 1, 0.5, 0, -1], "Descending numeric order")
    check(values(full.children()) == [1, 0.5, 0], "Expanded series descending")
    check(outline.item(atRow: outline.selectedRow) as AnyObject === selectedSeries, "Preserve selected series and expansion")
    outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true), local(true)]
    check(values(c.resultArray as? [Any]) == [-1, 0, 0.5, 1, 1.2], "Local as secondary key")
    outline.sortDescriptors = [local(true)]
    empty.value = 0.75; (selectedSeries as! DCMTKQueryNode).value = 0.9
    c.executeRefresh(nil)
    check(values(c.resultArray as? [Any]) == [-1, 0.75, 0.5, 1, 1.2], "Refresh redraws without moving rows")
    check(outline.item(atRow: outline.selectedRow) as AnyObject === selectedSeries, "Refresh preserves selected series")
    c.outlineView(outline, sortDescriptorsDidChange: [])
    check(values(c.resultArray as? [Any]) == [-1, 0.5, 0.75, 1, 1.2], "A header click sorts on the new local counts")
    check(values(full.children()) == [0, 0.9, 1], "A header click sorts expanded series")
    check(outline.item(atRow: outline.selectedRow) as AnyObject === selectedSeries, "A header click preserves selected series")
    outline.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true), local(true)]
    let dated = c.resultArray.sortedArray(using: c.sortArray()).map { $0 as AnyObject }
    check(dated[0] === full && dated[1] === half, "Date retains time tie breaker")
    c.resultArray.removeAllObjects(); outline.reloadData()
    c.outlineView(outline, sortDescriptorsDidChange: [])
    check(outline.selectedRow == -1, "Empty results keep empty selection")
    print("PASS: Swift controller numeric sorting, secondary key, series, refresh and selection")
}
"""
# The query node is Swift. Its children accessors copy, as these do: what
# the controller reads is a copy, and what it sets is copied in.
node_source = (root / 'Horos/Sources/DCMTKQueryNode.swift').read_text()
accessors = {
    '@objc func children() -> [Any]! {': 'return childrenStorage.map { $0.mutableCopy() as? [Any] ?? [] }',
    '@objc func setChildren(_ children: [Any]!) {': 'childrenStorage = children.map { NSMutableArray(array: $0) }',
    '@objc func purgeChildren() {': 'childrenStorage = nil',
}
node_children = ''
for signature, statement in accessors.items():
    at = node_source.find(signature)
    if at < 0 or statement not in node_source[at:node_source.index('\n    }\n', at)]:
        failures.append('the node\'s %s no longer %s' % (signature.split('(')[0].split()[-1], statement))
    node_children += '    %s objc_sync_enter(self); defer { objc_sync_exit(self) }; %s }\n' % (signature, statement)
harness = HARNESS.replace('NODE_CHILDREN', node_children).replace('METHODS', '\n'.join(methods))
with tempfile.TemporaryDirectory(prefix='horos-local-sort-') as directory:
    path = Path(directory)
    (path / 'Harness.swift').write_text(harness)
    (path / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', str(completeness), str(path / 'Harness.swift'),
                            str(path / 'main.swift'), '-o', str(path / 'test')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the Swift controller methods do not compile in the harness: ' + built.stderr[-4000:])
    else:
        run = subprocess.run([str(path / 'test')], capture_output=True, text=True, timeout=60)
        if run.returncode:
            failures.append('Swift controller regression: ' + (run.stdout + run.stderr)[-2000:])
        else:
            print(run.stdout.strip())

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: completeness tells an unknown total from 0%, refuses to call a study complete when '
      'the counts do not match exactly, sorts numerically with the unknowns apart only when '
      'asked, and one value feeds the column, the tooltip, the pie and the sort')
