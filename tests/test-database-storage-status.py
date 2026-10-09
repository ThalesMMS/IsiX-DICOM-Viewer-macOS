#!/usr/bin/env python3
"""Under the list of sources: the size of the database folder and the space left on its disk.

DatabaseStorageStatus.swift is compiled as it is, with doubles for the
database window and the database (the members it reads), and driven in an
application process:
- text: sizes as the system writes file sizes, with the fewest digits it
  allows (the line is as wide as the sidebar), an ellipsis while the folder
  is being added up, a dash when the free space cannot be read.
- folder: a temporary tree of files of known sizes, nested folders and a
  link to a large file outside it adds up to the space its files take on
  disk (st_blocks), the link not followed.
- once a minute: the folder is added up again only a minute after the last
  time.
- line: installed under the list of sources, which gives up the line's
  height, with the list's background (the pane under it draws nothing); it shows the size of the database folder and its disk's free
  space, turns red when the database says its disk is full, is left empty
  for a remote database, and follows another local database when one is chosen.
- wiring: the database window installs it when it sets up its sources, and
  it listens to saved contexts (images indexed or deleted).

`<git revision>` as an optional argument reads BrowserController+Sources.swift
from that revision, the negative control for the wiring.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

if revision:
    sources = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/BrowserController+Sources.swift']).decode()
else:
    sources = (root / 'Horos/Sources/BrowserController+Sources.swift').read_text()
status_source = (root / 'Horos/Sources/DatabaseStorageStatus.swift').read_text()
awake = sources[sources.find('func awakeSources()'):]
awake = awake[:awake.find('\n    }\n')]
failures = []
if 'DatabaseStorageStatus.install(in: self)' not in awake:
    failures.append('the database window must install the storage line when it sets up its sources')
if 'name: .NSManagedObjectContextDidSave' not in status_source:
    failures.append('the storage line must listen to saved contexts')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

DOUBLES = r'''
import AppKit
import CoreData

@objc class DicomDatabase: NSObject {
    @objc var dataBaseDirPath: String!
    var local = true
    var full = false
    var context: NSManagedObjectContext!
    init(path: String) {
        dataBaseDirPath = path
        let model = NSManagedObjectModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }
    @objc func isLocal() -> Bool { local }
    @objc var managedObjectContext: NSManagedObjectContext! { context }
    @objc func isFileSystemFreeSizeLimitReached() -> Bool { full }
}

@objc class BrowserController: NSObject {
    @objc dynamic var database: DicomDatabase?
    @objc var horos_sourcesTableView: NSTableView?
}
'''

DRIVER = r'''
import AppKit

func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return done()
}

@main @MainActor struct Harness {
    static func main() {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let tree = args[1], expected = Int64(args[2])!, other = args[3]
        typealias S = DatabaseStorageStatus

        // text
        let short = ByteCountFormatter()
        short.countStyle = .file
        short.isAdaptive = false
        let mb = short.string(fromByteCount: 1_234_567), gb = short.string(fromByteCount: 210_000_000_000)
        precondition(S.size(205_040_000_000) == short.string(fromByteCount: 205_040_000_000) && !S.size(205_040_000_000).contains(where: { ",.".contains($0) }), "the fewest digits: \(S.size(205_040_000_000))")
        precondition(S.text(databaseBytes: 1_234_567, freeBytes: 210_000_000_000) == "Database: \(mb) · Free: \(gb)", S.text(databaseBytes: 1_234_567, freeBytes: 210_000_000_000))
        precondition(S.text(databaseBytes: nil, freeBytes: 210_000_000_000) == "Database: … · Free: \(gb)")
        precondition(S.text(databaseBytes: 0, freeBytes: nil).hasSuffix("Free: —"))

        // the folder, links not followed
        let size = S.folderSize(at: URL(fileURLWithPath: tree))
        precondition(size == expected, "folder: \(size) != \(expected)")
        precondition(S.freeBytes(at: tree).map { $0 > 0 } == true)
        precondition(S.freeBytes(at: "/no/such/folder") == nil)

        // once a minute
        precondition(S.mayRecompute(now: 5, last: 0))
        precondition(!S.mayRecompute(now: 100, last: 50))
        precondition(S.mayRecompute(now: 110, last: 50))

        // the line under the list
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let scroll = NSScrollView(frame: pane.bounds)
        let table = NSTableView()
        scroll.documentView = table
        pane.addSubview(scroll)
        let browser = BrowserController()
        browser.horos_sourcesTableView = table
        let database = DicomDatabase(path: tree)
        browser.database = database
        let status = S.install(in: browser)!
        precondition(S.install(in: browser) === status, "installed once")
        let label = status.label
        precondition(label.superview === pane, "the line is in the sources pane")
        precondition(abs(scroll.frame.height + label.frame.height - 300) < 0.5 && scroll.frame.minY == label.frame.maxY, "the list gives up the line's height: \(scroll.frame) \(label.frame)")
        precondition(spin(10) { status.shownDatabaseBytes?.int64Value == expected }, "size shown: \(String(describing: status.shownDatabaseBytes))")
        precondition(label.stringValue.hasPrefix("Database: \(S.size(expected)) · Free: "), label.stringValue)
        precondition(label.toolTip == label.stringValue + "\n" + tree, "tool tip: \(String(describing: label.toolTip))")
        precondition(label.textColor == .secondaryLabelColor)
        precondition(label.drawsBackground && label.backgroundColor == table.backgroundColor && label.frame.width == scroll.frame.width, "the line takes the list's background, full width")

        database.full = true
        status.refreshFreeSpace()
        precondition(label.textColor == .systemRed, "red when the disk is full")
        database.full = false
        status.refreshFreeSpace()

        // another local database, then a remote one
        browser.database = DicomDatabase(path: other)
        precondition(spin(10) { status.shownDatabaseBytes?.int64Value == 0 }, "the other database: \(String(describing: status.shownDatabaseBytes))")
        precondition(label.toolTip?.hasSuffix("\n" + other) == true)
        let remote = DicomDatabase(path: other)
        remote.local = false
        browser.database = remote
        precondition(label.stringValue.isEmpty && label.toolTip == nil, "empty for a remote database: \(label.stringValue)")
        print("PASS: sizes written as files are, ellipsis and dash; the folder adds up its files' space, links not followed; once a minute; the line sits under the list, shows the folder and the free space, turns red when full, follows another database and is left empty for a remote one; installed with the sources")
        exit(0)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-storage-status-') as directory:
    p = Path(directory)
    tree = p / 'IsiX Data'
    (tree / 'DATABASE.noindex' / '10000').mkdir(parents=True)
    (tree / 'DATABASE.noindex' / '20000').mkdir(parents=True)
    sizes = {'DATABASE.noindex/10000/1.dcm': 10000, 'DATABASE.noindex/10000/2.dcm': 5000,
             'DATABASE.noindex/20000/3.dcm': 1, 'Database.sql': 70000}
    for name, length in sizes.items():
        (tree / name).write_bytes(os.urandom(length))
    outside = p / 'outside.bin'
    outside.write_bytes(os.urandom(3_000_000))
    (tree / 'link.bin').symlink_to(outside)
    expected = sum(os.stat(tree / name).st_blocks * 512 for name in sizes)
    other = p / 'Other Data'
    other.mkdir()

    (p / 'doubles.swift').write_text(DOUBLES)
    (p / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(root / 'Horos/Sources/DatabaseStorageStatus.swift'),
                    str(p / 'doubles.swift'), str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test'), str(tree), str(expected), str(other)], check=True, timeout=120)
