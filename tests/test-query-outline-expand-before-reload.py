#!/usr/bin/env python3
"""The query window's outline survives changes of its list around an expansion.

Expanding a study asks for its series inside AppKit's expansion, and the data
source waits for them in a modal session that keeps delivering main-queue work.
A reload arriving then makes AppKit raise NSInternalInconsistencyException
("should not be expanded already!") when the answer comes, and a new list makes
it read rows that no longer exist. The outline holds both until the expansion
ends. It also ignores an item that is not a row: a study of a list not shown
yet, or of a list already replaced.

Static checks, everywhere:
- the outline of Query.xib, in every language, is QueryOutlineView;
- QueryOutlineView guards both expandItem: methods with the item's row before
  it reaches AppKit;
- the data source waits with the outline and ends the wait outside the block an
  exception skips, -refreshList: holds a new list during the wait, and a child
  that no longer exists is answered with nil;
- the data source still expands only studies (and the root node), which the
  outline holds at the top level, the premise of the row check.

Runtime, where xcrun is present (skipped otherwise, exit 2): the real
QueryOutlineView.swift, compiled with a data source of plain objects:
- an item the outline never held, and the items of a list replaced but not
  reloaded yet, are ignored without an exception;
- after the reload the same item expands;
- the root (nil) still expands everything;
- the first right-arrow expansion after a reload survives a run-loop wait for
  its children, with and without Option, and subsequent navigation still works;
- a reload and a new list arriving while the data source waits are held until
  the expansion ends, and without the wait the same reload raises, which is the
  negative control.
Then, for the record only, whether a plain NSOutlineView raises for the item it
never held (this does not decide the result: AppKit's behaviour is what the
guard protects against, whatever this macOS version does).
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
from sources import source_text
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import process_graph_stand_in  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
failures = []

xibs = sorted((root / 'Horos/Resources').glob('*.lproj/Query.xib'))
if not xibs:
    failures.append('no Query.xib found')
for xib in xibs:
    text = xib.read_text(encoding='utf-8')
    if not re.search(r'<tableView [^>]*id="319"[^>]*customClass="QueryOutlineView"', text):
        failures.append(f'{xib.parent.name}/Query.xib: the results outline is not a QueryOutlineView')

outline = source_text('QueryOutlineView')
for needle, what in [
    ('public override func expandItem(_ item: Any?) {', 'expandItem: is not overridden'),
    ('public override func expandItem(_ item: Any?, expandChildren: Bool) {', 'expandItem:expandChildren: is not overridden'),
    ('item == nil || row(forItem: item) >= 0', 'an item is not checked against the rows before it is expanded'),
    ('guard holdsRow(for: item) else { return }', 'an item that is not a row still reaches AppKit'),
]:
    if needle not in outline:
        failures.append(f'QueryOutlineView: {what}')
# Each override checks the row first and only then hands the item to AppKit.
for signature, call in (('public override func expandItem(_ item: Any?) {', 'super.expandItem(item)'),
                        ('public override func expandItem(_ item: Any?, expandChildren: Bool) {',
                         'super.expandItem(item, expandChildren: expandChildren)')):
    body = outline[outline.find(signature):]
    body = body[:body.find('\n    }\n')]
    guard, handed = body.find('guard holdsRow(for: item) else { return }'), body.find(call)
    if not 0 <= guard < handed:
        failures.append(f'QueryOutlineView: {call} is not reached only through the row check')

results = source_text('QueryController+Results')
expandable = results[results.find('@objc(outlineView:isItemExpandable:)'):]
expandable = expandable[:expandable.find('@objc(outlineView:numberOfChildrenOfItem:)')]
if 'type(of: item) == DCMTKStudyQueryNode.self || type(of: item) == DCMTKRootQueryNode.self' not in expandable:
    failures.append('the query data source expands something other than studies and the root node: '
                    'the row check assumes the expandable items are top-level')

children = results[results.find('@objc(outlineView:numberOfChildrenOfItem:)'):]
children = children[:children.find('@objc(outlineView:objectValueForTableColumn:byItem:)')]
wait, query = children.find('self.outlineView.beginWaitingForChildren()'), children.find('node.query(withValues: nil)')
caught, end = children.find('} catch {'), children.find('self.outlineView.endWaitingForChildren()')
if not 0 <= wait < query < caught < end:
    failures.append('the data source does not wait with the outline around the query, outside the block an exception skips')
if 'child = children.count > index ? children[index] : nil' not in results:
    failures.append('a series row that no longer exists is not answered with nil')
query_source = source_text('QueryController+Query')
refresh = query_source[query_source.find('public func refreshList('):]
held, swapped = refresh.find('outlineView.holdUntilChildrenArrive'), refresh.find('resultArray.removeAllObjects()')
if not 0 <= held < swapped:
    failures.append('-refreshList: replaces the list while the outline waits for a series answer')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS (static): the outline of every Query.xib is QueryOutlineView and both expandItem: methods are '
      'guarded by the row')

if shutil.which('xcrun') is None:
    print('skipped: the runtime part needs xcrun (swiftc) and AppKit', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
import AppKit

// The controller a Command-click on a download arrow is sent to, named by #selector.
final class QueryController: NSObject {
    @objc(queueRetrieveOfItem:) func queueRetrieveOfItem(_ item: Any?) {}
}

final class Node: NSObject {
    let name: String
    var children: [Node]
    init(_ name: String, _ children: [Node] = []) {
        self.name = name
        self.children = children
    }
    override var description: String { name }
}

@MainActor
final class Source: NSObject, NSOutlineViewDataSource {
    var items: [Node] = []
    var rootAsks = 0
    /// What runs where the real data source waits for a study's series.
    var duringSeriesQuery: ((Node) -> Void)?

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else {
            rootAsks += 1
            return items.count
        }
        if let wait = duringSeriesQuery {
            duringSeriesQuery = nil
            wait(node)
        }
        return node.children.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return items[index] }
        return node.children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        (item as? Node)?.name
    }
}

func study(_ name: String) -> Node { Node(name, [Node(name + ".1"), Node(name + ".2")]) }

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let baseline = CommandLine.arguments.contains("baseline")
    let outline: NSOutlineView = baseline ? NSOutlineView() : QueryOutlineView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    let source = Source()
    outline.dataSource = source

    if CommandLine.arguments.contains("keyboard") {
        // A window and scroll view let AppKit resize the outline column after
        // the series arrive, including before the outline has been drawn.
        column.width = 200
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = outline
        window.contentView!.addSubview(scroll)
        let parent = study("Keyboard")
        source.items = [parent]
        outline.reloadData()
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeFirstResponder(outline)
        window.displayIfNeeded()
        let queryOutline = outline as! QueryOutlineView
        let option = CommandLine.arguments.contains("option")
        func key(_ character: String, code: UInt16, option: Bool = false) {
            var flags: NSEvent.ModifierFlags = [.function, .numericPad]
            if option { flags.insert(.option) }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: character, charactersIgnoringModifiers: character,
                                        isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        for _ in 0..<3 {
            outline.reloadData()
            source.duringSeriesQuery = { _ in
                queryOutline.beginWaitingForChildren()
                // The series query runs a modal loop. No reload is delivered
                // inside this wait: the pending column layout alone suffices.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                queryOutline.endWaitingForChildren()
            }
            key("\u{F703}", code: 124, option: option)
            precondition(outline.isItemExpanded(parent) && outline.numberOfRows == 3,
                         "the first keyboard expansion after a reload did not show its series")
            precondition(!queryOutline.isWaitingForChildren && outline.autoresizesOutlineColumn,
                         "the wait or automatic column resizing changed")
            key("\u{F701}", code: 125)
            precondition(outline.selectedRow == 1, "Down did not select the first series")
            key("\u{F700}", code: 126)
            precondition(outline.selectedRow == 0, "Up did not select the study")
            key("\u{F702}", code: 123)
            precondition(!outline.isItemExpanded(parent) && outline.numberOfRows == 1,
                         "Left did not collapse the study")
        }
        print("PASS (keyboard): first expansion after reload, series wait, navigation and collapse; option=\(option)")
        exit(0)
    }

    let a = study("A"), b = study("B")
    source.items = [a, b]
    outline.reloadData()
    precondition(outline.numberOfRows == 2, "rows: \(outline.numberOfRows)")

    if CommandLine.arguments.contains("unheld") {
        // What the outline holds back: a reload inside the expansion, and what
        // the modal session then does, redrawing the rows.
        source.items = [a]
        outline.reloadData()
        _ = outline.numberOfRows
        source.duringSeriesQuery = { _ in
            outline.reloadData()
            _ = outline.numberOfRows
        }
        outline.expandItem(a)
        print("no exception for a reload inside the expansion")
        exit(0)
    }

    // A study the outline never held.
    let stranger = study("stranger")
    if baseline {
        outline.expandItem(stranger)
        print("AppKit did not raise for an item the outline never held")
        exit(0)
    }
    outline.expandItem(stranger)
    outline.expandItem(stranger, expandChildren: true)
    precondition(!outline.isItemExpanded(stranger) && outline.numberOfRows == 2, "a study that is not a row was expanded")

    // The list replaced, the outline not reloaded yet: its studies are not rows.
    let c = study("C"), d = study("D")
    source.items = [c, d]
    outline.expandItem(c)
    precondition(!outline.isItemExpanded(c), "a study of a list not reloaded yet was expanded")

    // After the reload the same study expands.
    outline.reloadData()
    precondition(outline.row(forItem: c) >= 0 && outline.row(forItem: a) < 0, "the reload did not show the new list")
    outline.expandItem(a)
    precondition(!outline.isItemExpanded(a), "a study of the replaced list was expanded")
    outline.expandItem(c)
    precondition(outline.isItemExpanded(c) && outline.numberOfRows == 4, "a row did not expand: \(outline.numberOfRows) rows")

    // The root still expands everything.
    outline.expandItem(nil, expandChildren: true)
    for node in source.items {
        precondition(outline.isItemExpanded(node), "the root did not expand \(node)")
    }
    // A reload and a new list arrive while the data source waits for series.
    source.items = [study("E")]
    outline.reloadData()
    let queryOutline = outline as! QueryOutlineView
    let waited = source.items[0]
    let replacement = [study("G")]
    source.duringSeriesQuery = { _ in
        queryOutline.beginWaitingForChildren()
        queryOutline.reloadData()
        queryOutline.holdUntilChildrenArrive { source.items = replacement; queryOutline.reloadData() }
        queryOutline.endWaitingForChildren()
    }
    let asks = source.rootAsks
    outline.expandItem(waited)
    precondition(outline.isItemExpanded(waited) && outline.numberOfRows == 3, "the expansion did not finish: \(outline.numberOfRows) rows")
    precondition(source.rootAsks == asks, "a reload ran inside the expansion")
    precondition(source.items[0] !== replacement[0], "a new list arrived inside the expansion")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(!queryOutline.isWaitingForChildren, "the wait did not end")
    precondition(outline.numberOfRows == 1 && outline.row(forItem: replacement[0]) == 0, "the held list was not shown: \(outline.numberOfRows) rows")

    print("PASS (runtime): an item that is not a row is ignored, the same study expands after the reload, "
          + "the root expands everything, and a reload or a new list waits for the expansion")
}
'''

with tempfile.TemporaryDirectory(prefix='horos-query-outline-expand-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(DRIVER)
    binary = work / 'driver'
    # The view reads its preferences from PreferencesSource, over a stand-in of the process graph.
    subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/QueryOutlineView.swift'), str(work / 'main.swift'),
                    *process_graph_stand_in.swift_flags(work / 'graph'), '-o', str(binary)], check=True)
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    sys.stdout.write(run.stdout)
    if run.returncode != 0:
        sys.stderr.write(run.stderr)
        print(f'FAIL: the driver ended with {run.returncode}')
        sys.exit(1)
    for modifiers in ([], ['option']):
        keyboard = subprocess.run([str(binary), 'keyboard', *modifiers], capture_output=True, text=True, timeout=120)
        sys.stdout.write(keyboard.stdout)
        if keyboard.returncode != 0:
            sys.stderr.write(keyboard.stderr)
            print(f'FAIL: keyboard expansion ended with {keyboard.returncode}, modifiers={modifiers}')
            sys.exit(1)
    # Negative control: without the wait the same reload raises.
    unheld = subprocess.run([str(binary), 'unheld'], capture_output=True, text=True, timeout=120)
    if unheld.returncode == 0 or 'should not be expanded' not in unheld.stderr:
        print('FAIL: a reload inside an expansion no longer raises, so this test proves nothing: '
              + (unheld.stdout + unheld.stderr).strip()[:300])
        sys.exit(1)
    print('PASS (control): a reload inside an expansion raises when nothing holds it')
    # For the record only: what AppKit does without the guard on this macOS.
    plain = subprocess.run([str(binary), 'baseline'], capture_output=True, text=True, timeout=120)
    if plain.returncode == 0:
        print('note: ' + plain.stdout.strip())
    else:
        reason = next((line for line in plain.stderr.splitlines() if 'Exception' in line or 'expanded' in line), '')
        print(f'note: a plain NSOutlineView ended with {plain.returncode} for an item it never held. {reason}'.rstrip())
