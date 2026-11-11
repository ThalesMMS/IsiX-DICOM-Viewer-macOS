#!/usr/bin/env python3
"""The states a study can be given come from one list.

The list (numbers that never move, names, colours and actions the user
edits, the preference it is kept in) is IsiXDatabase's StudyStateList, tested
in its module. This checks that the application has one provider of it,
StudyStates, and that every place that shows a state asks it:

* the State column of the database list and of the Query window, the
  viewer's status pop-up, the smart albums' rule editor and the Web Portal;
* +[BrowserController statesArray], which plugins call, answers the list's
  names, and nothing else names the states by itself;
* a number the list does not have is answered as no state, where an index
  into a fixed array of five used to be read;
* the first eight states have their names in every catalog;
* applying a state runs its action, from the study's setter, once;
* Option and a digit, and the contextual menu, give the selected studies a
  state; the editor is opened from the column's pop-up and from that menu.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
failures = []


def source(name):
    return (sources / name).read_text(errors='replace')


def need(name, fragments):
    text = source(name)
    for fragment, what in fragments:
        if fragment not in text:
            failures.append(f'{name}: {what} ({fragment!r} not found)')


need('StudyStates.swift', [
    ('StudyStateList(stored: PreferencesSource.process.preferences[StudyStateList.preference])', 'the list is read from the preferences'),
    ('preferences.remove(StudyStateList.preference)', 'the list of a new installation is kept as no preference'),
    ('columns.removeAll { !$0.refresh() }', 'a change reaches the State columns that are open'),
    ('list.index(ofStored: value).map', 'a number the list does not have has no name'),
    ('item.keyEquivalentModifierMask = [.option]', 'the menu shows Option and the digit'),
    ('browser.setDatabaseValue(NSNumber(value: state), item: item, forKey: "stateText")', 'a state goes to the whole selection, as the column gives it'),
    ('let action = list.action(from: Int(previous), to: Int(state))', 'the action is the new state\'s, when the state changed'),
    ('ValidatedReportPDF.isDue(from: previous, to: state)', 'the DICOM PDF of a validated study is not made twice'),
    ('study.archiveValidatedReportAsDICOMPDF()', 'the DICOM PDF goes into the study'),
    ('browser.databaseOpenStudy(study)', 'the images are opened'),
])
need('BrowserController+ClassState.swift', [('@objc(statesArray)', 'plugins keep +statesArray'), ('return StudyStates.names', '+statesArray answers the list')])
need('BrowserController+Window.swift', [('StudyStates.install(on: outline, columns: ["stateText"], editable: true)', 'the database list\'s State column')])
need('BrowserController+OutlineDataSource.swift', [('if StudyStates.openEditorIfChosen(object, column: tableColumn) { return }', 'the column\'s Edit item is not a state')])
need('QueryController.swift', [('StudyStates.install(on: outlineView, columns: ["stateText", "serverStateText"], editable: false)', 'the Query window\'s State columns')])
need('MyOutlineView.swift', [('if StudyStates.applyShortcut(event, in: self.window?.windowController) { return }', 'Option and a digit in the list')])
need('BrowserToolbar.swift', [('StudyStates.addContextualItems(to: menu)', 'the contextual menu\'s Study State')])
need('ViewerSeriesLoad.swift', [('StudyStates.select(shown?.series?.study?.stateText?.intValue ?? 0, in: viewer.horos_StatusPopup)', 'the viewer\'s status pop-up, as a series loads')])
need('ViewerSessionGraph+ViewerLife.swift', [('StudyStates.select(shown?.series?.study?.stateText?.intValue ?? 0, in: viewer.horos_StatusPopup)', 'the viewer\'s status pop-up, as the window opens')])
need('StudyAnnotationEditor.swift', [('StudyStates.select(Int(value), in: viewer.horos_StatusPopup)', 'the viewer\'s status pop-up, as a status is applied')])
need('WebPortalConnection+Data.swift', [('StudyStates.name(ofStored: Int(objcIntValue(stateText)))', 'the Web Portal\'s study list')])
need('O2DicomPredicateEditorCodeStrings.swift', [('for (number, name) in StudyStates.names.enumerated()', 'the smart albums\' rule editor'),
                                                  ('return key == studyStatusKey ? studyStates() :', 'read each time it is asked for')])
if source('WebPortalResponse.swift').count('StudyStates.name(ofStored: Int(stateText))') != 2:
    failures.append('WebPortalResponse.swift: the study and the series state do not both ask the list')
setter = source('DicomStudy.swift')
if setter.count('StudyStates.stateChanged(of: self, from: previousState?.int32Value ?? 0, to: c?.int32Value ?? 0)') != 1:
    failures.append('DicomStudy.swift: the state\'s setter does not run the action once')

# Nothing else names the states or indexes the array.
for path in sorted(sources.glob('*.swift')):
    text = path.read_text(errors='replace')
    if path.name != 'StudyStates.swift':
        for name in ('unread', 'reviewed', 'dictated', 'validated', 'printed', 'distributed', 'archived'):
            if f'NSLocalizedString("{name}"' in text:
                failures.append(f'{path.name} names the state "{name}" itself')
    if re.search(r'statesArray\(\)[^\n]*\.object\(at:', text):
        failures.append(f'{path.name} indexes the names with a stored number')

# The names of the first eight, in every language.
module = (root / 'Modules/IsiXDatabase/Sources/StudyStates.swift').read_text()
names = re.search(r'builtInNames = \[([^\]]+)\]', module).group(1).replace('"', '').replace(' ', '').split(',')
if names[:5] != ['empty', 'unread', 'reviewed', 'dictated', 'validated'] or len(names) != 8:
    failures.append(f'the built-in names are {names}')
provider = source('StudyStates.swift')
for name in names:
    if f'case "{name}": return NSLocalizedString("{name}", comment: "")' not in provider:
        failures.append(f'the state "{name}" is not localized')
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    strings = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(catalog)]))
    missing = [name for name in names + ['State %d', 'Edit States…', 'Study State', 'Study States'] if name not in strings]
    if missing:
        failures.append(f'{catalog.parent.stem}: no {", ".join(missing)}')

# The actions the editor offers are the module's, none of which removes or sends.
editor = source('StudyStatesEditor.swift')
offered = re.findall(r'\(\.(\w+), NSLocalizedString', editor)
declared = re.findall(r'^    case (\w+)$', module[module.index('enum StudyStateAction'):module.index('/// The colour a state shows')], re.M)
if offered != declared or declared != ['none', 'openImages', 'reportToPDF', 'reportToDICOMPDF', 'saveReportAsPDF']:
    failures.append(f'the editor offers {offered}, the module declares {declared}')
need('StudyStatesEditor.swift', [('StudyStates.save(list)', 'each change is kept at once'), ('removeButton.isEnabled = list.canRemoveLast', 'only the last state can be removed')])

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('ok: one list of study states, asked by the lists, the viewer, the rule editor, the Web Portal and plugins; %d names in every catalog' % len(names))
