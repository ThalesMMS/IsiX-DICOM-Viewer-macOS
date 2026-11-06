#!/usr/bin/env python3
"""2D Viewer > Reduce Series… opens a new viewer of a reduced copy of the series.

The rules (which slices are kept, the values the dialog accepts, the reduced
interval) are IsiXImaging's SeriesReduction, tested by
`swift test --package-path Modules --filter SeriesReductionTests`. This checks
the wiring: the menu item beside Flip Series, its action, sent to the main
menu's ViewerStudyCommands object, and its enabling there, the file in the app
target, outside the ViewerController hub, and that the command copies the
slices into a new viewer instead of changing the one it runs in.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


menu = (root / 'Horos/Resources/en.lproj/MainMenu.xib').read_text(encoding='utf-8')
items = re.findall(r'<menuItem title="([^"]*)"[^>]*id="([^"]+)"', menu)
titles = [title for title, _ in items]
if 'Reduce Series…' not in titles:
    fail('2D Viewer has no Reduce Series… item')
at = titles.index('Reduce Series…')
# The series commands follow Flip Series as one group.
if 'Flip Series' not in titles[max(0, at - 3):at]:
    fail(f'Reduce Series… is not beside Flip Series (after {titles[at - 1]!r})')
start = menu.index('id="Rds-sr-Itm"')
if 'selector="openReducedSeries:" target="Vsc-cm-Obj"' not in menu[start:menu.index('</menuItem>', start)]:
    fail('Reduce Series… does not send openReducedSeries: to the ViewerStudyCommands object')
if menu.count('id="Rds-sr-Itm"') != 1 or menu.count('id="Rds-sr-Act"') != 1:
    fail('the ids of Reduce Series… are not unique')

reduction = (sources / 'ViewerSeriesReduction.swift').read_text(encoding='utf-8')
commands = (sources / 'ViewerStudyCommands.swift').read_text(encoding='utf-8')
if '@objc(openReducedSeries:)' not in commands or 'ViewerSeriesReduction(viewer: viewer).run()' not in commands:
    fail('ViewerStudyCommands does not hand Reduce Series… to ViewerSeriesReduction')
if re.search(r'^\s*(?:public |internal )?extension ViewerController\b', reduction, re.M):
    fail('ViewerSeriesReduction.swift extends the ViewerController hub')
for needle, why in (
    ('SeriesReduction.make(', 'validates the dialog with the rule of IsiXImaging'),
    ('SeriesReduction.defaults(', 'proposes the defaults of the rule'),
    ('keptIndices(flipped:', 'keeps the slices the rule chooses'),
    ('sliceInterval(original:', 'gives the slices the reduced interval'),
    ('ViewerController.newWindow(', 'opens a new viewer'),
    ('addMovieSerie(', 'keeps the other time points'),
    ('checkEverythingLoaded()', 'waits for the pixels before copying them'),
    ('accessoryView', 'asks in an alert accessory'),
    ('NSStepper', 'has steppers'),
):
    if needle not in reduction:
        fail(f'the reduction no longer {why}: {needle!r} is missing')
for needle in ('changeImageData', 'replaceSeries', 'viewerChangeImageData'):
    if needle in reduction:
        fail(f'the reduction changes the viewer it runs in ({needle})')

validate = commands[commands.index('func validateMenuItem(_ item: NSMenuItem) -> Bool'):]
validate = validate[:validate.index('\n    }\n')]
case = 'case #selector(openReducedSeries(_:)):'
body = validate[validate.index(case):] if case in validate else ''
body = body[:body.find('\n        case ', len(case))]
if ('StudyViewers.databaseViewer()' not in body
        or '(viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) > 1' not in body):
    fail('Reduce Series… is not enabled like Flip Series, for a series of more than one slice')

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if pbx.count('ViewerSeriesReduction.swift in Sources') != 2 or 'path = ViewerSeriesReduction.swift;' not in pbx:
    fail('ViewerSeriesReduction.swift is not compiled into the app')
if not (root / 'Modules/IsiXImaging/Sources/SeriesOperations/SeriesReduction.swift').exists():
    fail('SeriesReduction.swift is not in IsiXImaging')
print('PASS: Reduce Series is wired to a new viewer of the kept slices')
