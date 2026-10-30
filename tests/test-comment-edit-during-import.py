#!/usr/bin/env python3
"""Studies arriving do not reload the outline under someone typing in it.

`-[BrowserController refreshDatabase:]`, the timer-driven refresh, has always
refused to run while a cell is being edited:

    if( DatabaseIsEdited) return;
    if( [databaseOutline editedRow] != -1) return;

The notification-driven refresh had no such guard. `OsirixAddToDBNotification`
is posted for every batch that lands, and `-_observeDatabaseAddNotification:`
called `-outlineViewRefresh` straight away — reloading the outline tears down the
field editor, so the partial text and the insertion point go. Studies arrive one
after another, which is the loss of focus per arrival the reports describe.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
failures = []
# The browser's study list state is BrowserState.swift.
state = (root / 'Horos/Sources/BrowserState.swift').read_text()
# The refreshes a study arriving triggers are BrowserController+DatabaseSwitching.swift.
switching = (root / 'Horos/Sources/BrowserController+DatabaseSwitching.swift').read_text()


def body(signature, source):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
        index += 1
    return ''


# --- the refresh that arrivals trigger has to stay out of an edit ------------
refresh = body('func _refreshDatabaseDisplay() {', switching)
if not refresh:
    failures.append('-_refreshDatabaseDisplay is gone')
else:
    if 'editedRow' not in refresh:
        failures.append('the refresh that a study arriving triggers does not ask whether a cell '
                        'is being edited, so it reloads the outline under the field editor')
    if 'outlineViewRefresh' not in refresh:
        failures.append('the refresh no longer refreshes')

# --- and the arrival notification has to go through it ----------------------
arrival = body('func _observeDatabaseAddNotification(', switching)
if not arrival:
    failures.append('-_observeDatabaseAddNotification: is gone')
else:
    if '_refreshDatabaseDisplayAfterImport' not in arrival:
        failures.append('the arrival notification refreshes the outline directly, bypassing the '
                        'guard entirely')
    # Import refreshes are coalesced; the one that fires keeps the guard.
    fire = body('func _importListRefreshFire()', switching)
    if 'editedRow' not in fire or 'horos_refreshDeferredWhileEditing = true' not in fire:
        failures.append('the coalesced import refresh reloads the outline under an edit')
    if 'outlineViewRefresh' in arrival:
        failures.append('the arrival notification still calls -outlineViewRefresh itself')

# --- what was deferred has to happen once the edit is over -------------------
if '@objc var refreshDeferredWhileEditing = false' not in state:
    failures.append('nothing remembers that a refresh was skipped, so the outline stays stale '
                    'until something else happens to refresh it')
deferred = body('func _refreshDatabaseDisplayIfDeferred()', switching)
if not deferred:
    failures.append('there is no way to run the refresh that was deferred')
else:
    if '_refreshDeferredWhileEditing' not in deferred:
        failures.append('the deferred refresh does not check whether one was deferred')
    if 'editedRow' not in deferred:
        failures.append('the deferred refresh can run while the edit is still open, which is the '
                        'thing it exists to avoid')

# Committing an edit is BrowserController+OutlineDataSource.swift, the
# timer-driven refresh BrowserController+StudyList.swift.
outline = (root / 'Horos/Sources/BrowserController+OutlineDataSource.swift').read_text()
study_list = (root / 'Horos/Sources/BrowserController+StudyList.swift').read_text()
commit = body('func setDatabaseValue(', outline)
if not commit:
    failures.append('-setDatabaseValue:item:forKey: is gone')
elif '_refreshDatabaseDisplayIfDeferred' not in commit:
    failures.append('committing an edit does not catch the outline up on what arrived meanwhile')

# --- the timer-driven refresh must keep its own guard ------------------------
timer = body('func refreshDatabase(_ sender: Any!)', study_list)
if not timer:
    failures.append('-refreshDatabase: is gone')
elif 'editedRow' not in timer:
    failures.append('the timer-driven refresh has lost the guard it always had')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a study arriving defers the outline reload while a cell is being edited, and the '
      'deferred reload happens once the edit is over')
