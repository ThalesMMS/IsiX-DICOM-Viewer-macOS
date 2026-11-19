#!/usr/bin/env python3
"""The PET pane shows the linear opacity table a preference names in the words
a language once had for it, and stores it as every language does.

"PET Default Opacity Table" held the title of the pane's pop-up, whose first
item, the linear table, had its title from the language of the day: chosen in
German, the preference held "Lineare Tabelle". Every language writes the item
as English does now. The viewer reads the preference in every language
(tests/test-stored-names-any-language.py); the pane gave the stored text to
-setTitle:, and a pop-up that has no item of a title adds one after its items
and selects it, so the pane showed the words of the other day as one table
more and wrote them back when it was left. What is checked, with the pane's
source compiled beside `AnyLanguage` and its three pop-ups given to it:

- for every text a language wrote for the linear table, and for the English
  one, the pane selects the first item of the pop-up, which has as many items
  as it has tables, and leaving the pane stores "Linear Table";
- a stored table is selected under its name and stored under it;
- a name that is neither (a table since removed) is shown as an item of its
  own and stored as it was, as before: only the names of the linear table are
  recognised;
- the first item is stored as "Linear Table" whatever its title;
- the list of the texts is `AnyLanguage`'s, which the application reads too:
  the pane keeps none of its own.

    python3 tests/test-pet-pane-stored-opacity-table.py
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import harness_defaults  # noqa: E402
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
pane = root / 'Preference Panes/OSIPETPreferencePane/OSIPETPreferencePane.swift'
any_language = root / 'Horos/Sources/AnyLanguage.swift'
failures = []

# The list of the former texts is the preferences module's; AnyLanguage reads it.
source = (root / 'Modules/IsiXPreferences/Sources/StoredTableNames.swift').read_text()
former = source[source.index('static let formerTexts'):]
linear = re.search(r'"Linear Table": \[(.*?)\],\n', former, re.S)
if not linear:
    sys.exit('the former texts of "Linear Table" were not read from StoredTableNames.swift')
FORMER = re.findall(r'"([^"]+)"', linear.group(1))
if len(FORMER) < 8 or 'Lineare Tabelle' not in FORMER:
    sys.exit(f'the former texts of "Linear Table" were not read from StoredTableNames.swift: {FORMER}')
TABLES = ['Logarithmic Inverse Table', 'Logarithmic Table', 'Smooth Table']

MAIN = harness_defaults.SWIFT + r'''
import AppKit
import PreferencePanes

extension NSPreferencePane {
    // The pane of the test has no nib: its pop-ups are given to it.
    @MainActor @discardableResult
    func instantiatePaneNib(named name: String, mirrors: Bool = true, topLevelObjects: inout NSArray?) -> Bool { false }
}

@MainActor func open(firstTitle: String?) -> OSIPETPreferencePane {
    let pane = OSIPETPreferencePane()
    pane.mainView = NSView()
    pane.DefaultCLUTMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    pane.CLUTBlendingMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    pane.OpacityTableMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    pane.mainViewDidLoad()
    // The title a language may give the item of the linear table.
    if let firstTitle { pane.OpacityTableMenu?.item(at: 0)?.title = firstTitle }
    return pane
}

@MainActor func run() {
    let defaults = UserDefaults.standard
    let arguments = Array(CommandLine.arguments.dropFirst())
    let tables = arguments[0].split(separator: "|").map(String.init)
    defaults.set(Dictionary(uniqueKeysWithValues: tables.map { ($0, [Any]()) }), forKey: "OPACITY")
    defaults.set(["Hot": [String: Any](), "PET": [String: Any]()], forKey: "CLUT")
    defaults.set("PET", forKey: "PET Default CLUT")
    defaults.set("Hot", forKey: "PET Blending CLUT")
    var results: [[String: Any]] = []
    for stored in arguments.dropFirst() {
        defaults.set(stored, forKey: "PET Default Opacity Table")
        let pane = open(firstTitle: nil)
        var result: [String: Any] = ["stored": stored, "items": pane.OpacityTableMenu?.itemTitles ?? [],
                                     "selected": pane.OpacityTableMenu?.indexOfSelectedItem ?? -2,
                                     "title": pane.OpacityTableMenu?.titleOfSelectedItem ?? "(nil)",
                                     "cluts": [pane.DefaultCLUTMenu?.titleOfSelectedItem ?? "(nil)", pane.CLUTBlendingMenu?.titleOfSelectedItem ?? "(nil)"]]
        pane.willUnselect()
        result["written"] = defaults.string(forKey: "PET Default Opacity Table") ?? "(nil)"
        results.append(result)
    }
    // The first item under a title of its own, chosen by the user: stored as every language stores it.
    defaults.set("Smooth Table", forKey: "PET Default Opacity Table")
    let pane = open(firstTitle: "Lineare Tabelle")
    pane.OpacityTableMenu?.selectItem(at: 0)
    pane.willUnselect()
    results.append(["stored": "(first item chosen)", "written": defaults.string(forKey: "PET Default Opacity Table") ?? "(nil)"])
    // Another item chosen: stored under its title.
    let other = open(firstTitle: nil)
    other.OpacityTableMenu?.selectItem(withTitle: "Smooth Table")
    other.willUnselect()
    results.append(["stored": "(a table chosen)", "written": defaults.string(forKey: "PET Default Opacity Table") ?? "(nil)"])
    print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
}
MainActor.assumeIsolated { run() }
'''

with tempfile.TemporaryDirectory(prefix='horos-pet-pane-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(MAIN)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(any_language), str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                            str(pane), str(path / 'main.swift'), '-framework', 'PreferencePanes',
                            *isix_modules.module_flags('IsiXPreferences', path / 'modules'), '-o', str(path / 'test')],
                           capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the pane does not compile beside AnyLanguage:\n' + built.stderr[-3000:])
    stored = ['Linear Table'] + FORMER + TABLES + ['A table since removed']
    ran = subprocess.run([str(path / 'test'), '|'.join(TABLES)] + stored, capture_output=True, text=True)
    if ran.returncode:
        sys.exit('FAIL: the pane did not run:\n' + ran.stderr[-3000:])
    results = {result['stored']: result for result in json.loads(ran.stdout)}

menu = ['Linear Table'] + sorted(TABLES, key=str.casefold)
for text in ['Linear Table'] + FORMER:
    result = results[text]
    if result['items'] != menu:
        failures.append(f'with {text!r} stored, the pop-up lists {result["items"]}, and the tables are {menu}')
    if result['selected'] != 0 or result['title'] != 'Linear Table':
        failures.append(f'with {text!r} stored, the pane selects item {result["selected"]}, {result["title"]!r}, not the linear table')
    if result['written'] != 'Linear Table':
        failures.append(f'with {text!r} stored, leaving the pane stores {result["written"]!r}')
for table in TABLES:
    result = results[table]
    if result['items'] != menu or result['title'] != table or result['written'] != table:
        failures.append(f'the stored table {table!r} is shown as {result["title"]!r} among {result["items"]} and stored as {result["written"]!r}')
removed = results['A table since removed']
if removed['items'] != menu + ['A table since removed'] or removed['title'] != 'A table since removed' or removed['written'] != 'A table since removed':
    failures.append(f'a name no table has is shown as {removed["title"]!r} among {removed["items"]} and stored as {removed["written"]!r}')
for result in results.values():
    if result.get('cluts', ['PET', 'Hot']) != ['PET', 'Hot']:
        failures.append(f'the colour tables of the pane are shown as {result["cluts"]}')
if results['(first item chosen)']['written'] != 'Linear Table':
    failures.append(f'the first item, under another title, is stored as {results["(first item chosen)"]["written"]!r}')
if results['(a table chosen)']['written'] != 'Smooth Table':
    failures.append(f'a table chosen in the pop-up is stored as {results["(a table chosen)"]["written"]!r}')

# The texts are AnyLanguage's: the pane lists none.
text = pane.read_text()
for former_text in FORMER:
    if former_text in text:
        failures.append(f'the pane lists {former_text!r} itself')
if 'AnyLanguage.tableName(stored: stored)' not in text:
    failures.append('the pane does not read the stored opacity table through AnyLanguage')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'ok: the PET pane selects the linear table for {len(FORMER) + 1} stored names of it, with no item more, and stores "Linear Table"')
