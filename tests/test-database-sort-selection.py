#!/usr/bin/env python3
"""Execute the production sort callback and preserve the restored selection.

-outlineView:sortDescriptorsDidChange: is Swift, in
BrowserController+OutlineDataSource.swift: its body is compiled as it stands
into a double of the browser whose -outlineViewRefresh restores a row.
"""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController+OutlineDataSource.swift').read_text()
found = re.search(r'    func outlineView\(_ outlineView: NSOutlineView!, sortDescriptorsDidChange oldDescriptors: \[Any\]!\) \{.*?\n    \}\n', source, re.S)
if not found:
    raise SystemExit('FAIL: -outlineView:sortDescriptorsDidChange: is gone from BrowserController+OutlineDataSource.swift')
method = found.group(0)
code = r'''
import AppKit

final class Outline {
    var selectedRow = 0
    var scrolledRow = 0
    func scrollRowToVisible(_ row: Int) {
        precondition(row >= 0, "Invalid scroll row")
        scrolledRow = row
    }
}

final class Browser {
    var horos_databaseOutline: Outline? = Outline()
    var restoredRow = 0
    @discardableResult func outlineViewRefresh() -> String! {
        horos_databaseOutline?.selectedRow = restoredRow
        return nil
    }
METHOD
}

let browser = Browser()
browser.restoredRow = 7
browser.outlineView(nil, sortDescriptorsDidChange: [])
precondition(browser.horos_databaseOutline?.selectedRow == 7, "Sort replaced the restored selected item with the first row")
precondition(browser.horos_databaseOutline?.scrolledRow == 7, "Selected item must remain visible")
browser.restoredRow = -1
browser.horos_databaseOutline?.scrolledRow = 99
browser.outlineView(nil, sortDescriptorsDidChange: [])
precondition(browser.horos_databaseOutline?.selectedRow == -1, "Empty selection must remain empty")
precondition(browser.horos_databaseOutline?.scrolledRow == 99, "Empty selection must not scroll")
print("PASS: sorting preserves restored item and handles empty selection")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-sort-') as tmp:
    path = Path(tmp)
    (path / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
