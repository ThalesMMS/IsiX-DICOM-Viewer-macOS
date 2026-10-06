#!/usr/bin/env python3
"""Run the production patient command with prior search modes and both row types.

-searchForCurrentPatient: lives in BrowserController+Plugins.swift. The
method is compiled as it is, with xcrun swiftc, inside a double of the
browser: an outline that answers the selected row, a real NSSearchField whose
menu template carries the search modes, and a -setSearchType: that, like the
app's, changes the mode and clears the search and the selection.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

source = source_text('BrowserController+Plugins')
start = source.index('    @objc(searchForCurrentPatient:)')
method = source[start:source.index('    @objc(setFilterPredicate:description:)', start)]
code = r'''
import AppKit

final class OutlineFixture: NSObject {
    var selectedRow = 0
    var object: AnyObject?
    func item(atRow row: Int) -> Any? { return object }
}

final class BrowserFixture: NSObject {
    var horos_databaseOutline: OutlineFixture? = OutlineFixture()
    var horos_searchField: NSSearchField? = NSSearchField(frame: .zero)
    var searchType = 0
    var query: String?
    var searchString: String! {
        get { return query }
        set { query = newValue.map { String($0) } }
    }
    func setSearchType(_ sender: Any!) {
        searchType = (sender as? NSMenuItem)?.tag ?? -1
        self.searchString = nil
        horos_databaseOutline?.selectedRow = -1
    }
METHOD
}

let browser = BrowserFixture()
let menu = NSMenu()
for tag in [0, 1, 4, 11] {
    let item = NSMenuItem(title: "mode \(tag)", action: nil, keyEquivalent: "")
    item.tag = tag
    menu.addItem(item)
}
(browser.horos_searchField!.cell as! NSSearchFieldCell).searchMenuTemplate = menu
let rows: [NSDictionary] = [["type": "Study", "name": "QA Patient"], ["type": "Series", "study": ["name": "QA Patient"]]]
for mode in [0, 1, 4, 11] {
    for row in rows {
        browser.searchType = mode
        browser.horos_databaseOutline!.selectedRow = 0
        browser.horos_databaseOutline!.object = row
        browser.searchForCurrentPatient(nil)
        precondition(browser.searchType == 0, "Patient name must not be searched as an ID or description")
        precondition(browser.query == "QA Patient", "Keep selected patient's name across the field change")
    }
}
browser.searchType = 4
browser.searchString = "original"
browser.horos_databaseOutline!.selectedRow = -1
browser.searchForCurrentPatient(nil)
precondition(browser.searchType == 4 && browser.query == "original", "No selection must not clear unrelated search")
print("PASS: patient command selects name mode for study/series and preserves no-selection search")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-patient-search-') as tmp:
    path = Path(tmp)
    (path / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
