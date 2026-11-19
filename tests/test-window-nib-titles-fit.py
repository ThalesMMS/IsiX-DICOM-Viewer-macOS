#!/usr/bin/env python3
"""Every title of a window's nib fits its control, and every header its column, in every language.

The nibs of the windows are in Horos/Resources/en.lproj, with a copy in each of
eight languages; Spanish, Italian and Japanese have no copy and read the
English nib with the texts of their catalog (WindowNibCatalog). A copy keeps
the geometry of the English nib, which the tests of each language require, so
a title longer than the English one is cut where the English frame left it no
room: the sheet that exports the images of a viewer read "Fichiers JP" in
French, in cells of 55 points that "JPEG Files" itself did not fit. The main
nib and the preference panes have their own tests of this; the nibs of the
other windows had none.

Each copy of a nib is compiled and loaded without its bindings
(tests/pane_titles.py), and every window, sheet and panel of it is measured,
with the views it holds outside its windows (those of toolbar items) and the
views of every item of a tab view, not only of the one the nib selects; a view
of a toolbar item is held at the size of its nib, as the toolbar holds it,
unless FLEXIBLE names it as one its toolbar lets grow. The rule is that of the
preference panes' test: a label on one line may need 3 points more than its
frame, the padding AppKit counts in, a button, checkbox or radio button nothing
more, a wrapped label fits its lines and its longest word, the cells of a
matrix are measured in their cells and a box's title in the box, and two
controls of one view do not overlap in what they draw. The header of a table
column needs no more than the width of its column: the plugin manager read
"Aktivie..." over its checkboxes in German, in a column of 60 points. A matrix draws its cells
only: the sheet that propagates an ROI stands the two choices of "3D Series" in
the gap between that row and "4D Series", inside the frame of their matrix and
over none of its cells. A pull-down shows its title and a pop-up the item that
is chosen: the title, or the widest of the items, needs no more than the frame
(tests/pane_titles.py says how that is measured, and what it was checked
against in the running application). The volume rendering read «Применить ф…»
in Russian over the menu of its filters, in a pull-down of 110 points whose
title needs 127. The English nib is then measured with the texts of the
Spanish, Italian and Japanese catalogs written into it, after WindowNibFit gave
each text the room free beside it, as a window that reads the catalog is shown.

NIBS lists the nibs whose titles fit. PENDING lists the ones that are not
measured here yet, and every nib of a window is in one of the two. ALTERNATES
names the pairs of controls whose frames cross and that never draw one over
the other, each with its reason, and FILLED_IN_CODE the controls whose nib text
is a sample the code replaces, LAID_OUT_IN_CODE the ones the code of their
window gives another frame, HEADERS_FIT_IN_CODE the tables whose columns the
code of their window widens to their headers, TABLES_BUILT_IN_CODE the tables of
a nib that its window replaces by one it builds, and WINDOWS_BUILT_IN_CODE the
windows with no nib whose code fits a table to its headers; the source of each
has to hold the call that does it. PRESET_PULL_DOWNS names the pull-downs
whose title is the name of the preset in use, with the names the code itself
writes there, which are measured in the place of the title, and STORED_NAMES
the stored tables a window opens with; CUT_NAMES names those a window writes
later that its pull-down shows cut in the middle, as it shows any name that
does not fit; MENUS_FROM_CODE names the pull-downs
whose menu the code replaces and PLAIN_VIEWS the views outside the windows that
no toolbar holds. SHORT_NAME_CELLS names the cells of their own that draw a
short name: their pop-ups are measured with the short names, as the rule of
the application gives them, in the place of their items. The measure
is checked too: the English export sheet with its cells of 55 points again has
to be reported, and so have a column of the plugin manager made as narrow as it
was and the pull-down of the filters of the volume rendering at its 110 points.

A title with room for itself may still be cut by what holds it (contained): the
box that held the interval of a movie export had no bottom of its own, and the
row that counts the images ran through its border. Once the window is laid out
as it is shown, a control that shows a text of the nib and reaches more than 3
points outside a view above it, its box or its window, is reported;
CONTAINMENT_PENDING names the ones found and not corrected yet, none today, and
OUT_OF_SIGHT the ones no window shows; the measure is checked against that box
without its bottom. What is measured is what a control draws: a matrix draws
its cells, each no further than its title goes, and its frame may pass its box
with nothing cut. FRAMES_PAST_THEIR_BOX names the matrix whose nib does that
on purpose, with the constraint that says by how much: every cell of it has to
draw its title in the part of the cell that stays inside the box.

`--inventory` measures every nib, the pending ones too, and prints what does
not fit in each, by language; names given as arguments limit either run to
those nibs.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_titles  # noqa: E402
import pane_translations  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
COPIES = ('en', 'ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')
CATALOG_LANGUAGES = ('es', 'it-IT', 'ja-JP')
# The sources of WindowNibFit, which gives a translated text the room free beside it once the catalog is read.
ROOM = [ROOT / 'Horos/Sources/WindowNibCatalog.swift', ROOT / 'Preference Panes/PaneCatalogTranslation.swift']

# Nibs that other tests measure: the main nib (test-main-menu-windows-fit.py) and the About window.
ELSEWHERE = {'MainMenu', 'Splash'}

# The nibs whose titles fit in every language.
NIBS = [
    '3DPosition',
    'AnonymizationCustomTagPanel',
    'AnonymizationPanel',
    'AnonymizationSavePanel',
    'AnonymizationTemplateNamePanel',
    'AnonymizationView',
    'AYDicomPrint',
    'BurnViewer',
    'CalciumScoring',
    'CPR',
    'CustomIntervalPanel',
    'Endoscopy',
    'FlyThru',
    'Histogram',
    'ICloudDriveDetector',
    'ITKSegmentation',
    'LogWindow',
    'Loupe',
    'MPR',
    'Navigator',
    'O2HMigrationAssistant',
    'OrthogonalMPR',
    'PaletteBrush',
    'PETCT',
    'Plot',
    'PluginManager',
    'PreferencesWindow',
    'Query',
    'QuicktimeExport',
    'ROI',
    'ROIDefaults',
    'ROIManager',
    'ROIVolume',
    'ROIVolumeManager',
    'Send',
    'SmartAlbum',
    'SR',
    'ThickSlab',
    'ThreadModalForWindow',
    'ThumbnailsList',
    'ToolbarPanel',
    'VR',
    'Viewer',
    'ViewerPanels',
    'Wait',
    'WaitRendering',
    'XMLViewer',
]

# The nibs that are not measured here yet: none.
PENDING = set()

# Pairs of controls whose frames cross and that never draw one over the other.
ALTERNATES = {
    'Viewer': {
        # The item of the mouse tools: a transparent pull-down stands over the corner of the last cell of the tools,
        # the one of the ROI tool, and opens the menu of the kinds of ROI. It draws no bezel and no title.
        frozenset({'580', '24'}),
        # The subtraction item, 37 points high, stands its two bezelled buttons one above the other: their frames,
        # 22 and 21 points high, cross by the margins a bezel leaves around what it draws, and the bezels are apart.
        frozenset({'1663', '790'}),
    },
    'VR': {
        # The panel of the 3D presets writes the number of presets of the group in the middle of a label as wide as
        # the panel, whose frame starts over the end of the label of the group, at its left: the count, 163 points
        # at its widest in Russian, is drawn 60 points and more from that label.
        frozenset({'1410', '1553'}),
    },
}

# Controls whose text the code writes when the window opens, by nib and by their ids: what the nib holds there is a
# sample that is never shown, and its width says nothing.
FILLED_IN_CODE = {
    # The names of the nine presets of a page of the 3D presets panel, and the number of presets of the group.
    'VR': {'1479', '1480', '1481', '1482', '1483', '1484', '1485', '1486', '1487', '1553'},
}

# Controls that the code of their window lays out from their texts when it opens, by nib and by their ids: the
# frame the nib gives them is not the one they are shown in.
LAID_OUT_IN_CODE = {
    # The button that uninstalls a plugin shares its row with three buttons the manager adds, and the row has no
    # room for the widest translation of each: the manager gives the button the width of its title in the running
    # language, from its trailing edge (-configurePluginLoadDetails).
    'PluginManager': {'dNG-hG-PSZ'},
    # The Shadings item of the 3D MPR: the checkbox and the button under it keep in the nib the frames their
    # English titles need, two points over each other, and MPRShadingItemLayout replaces the frames by constraints
    # that give each the width of its title in the running language (tests/test-mpr-toolbar-views.py lays the
    # item out in every copy).
    'MPR': {'732', '734'},
    # The radios of the mouse buttons, under the tools of the 2D viewer: their item writes the short titles of the
    # catalog over the ones of the nib, spaces the cells, sizes the matrix to them, centres it in place of the
    # leading edge the nib pins it to, and takes the width its controls ask for (contained).
    'Viewer': {'1238'},
}

# Tables whose columns the code of their window widens to their headers when it opens, by nib and by the id of
# the table: the widths the nib gives its columns are not the ones they are shown with.
HEADERS_FIT_IN_CODE = {
    # The list of the results of a query: its columns are the ones the user chose, with the widths that were
    # saved, and the window widens each one that cuts its header (-resultColumnsDidReadCatalog).
    'Query': {'319'},
}

# Tables of a nib that its window never shows, by nib and by the id of the table, with the source of the window
# and what it has to hold: the window shows in their place a table that its code builds, whose columns the code
# fits to their headers in the running language.
TABLES_BUILT_IN_CODE = {
    # The ROI manager replaces the content of its window by an outline of its own, with columns for the name,
    # the slice, the count, the measure and the three states. What the table of the nib measures also depends on
    # the Xcode that compiles it: ibtool archives the last column of a table that resizes only that one at
    # another width than the nib gives it, 79 points for 108 with Xcode 27.2.
    'ROIManager': ({'9'}, 'Horos/Sources/ROIManagerController.swift',
                   ('window.contentView = content', 'PaneFit.fitColumns(of: outline)')),
}

# Windows built in code, with no nib, whose table takes the widths of its columns from their headers in the
# running language: the source of the window and the call it has to hold.
WINDOWS_BUILT_IN_CODE = {
    'Modality Worklist': ('Horos/Sources/ModalityWorklistWindowController.swift', 'PaneFit.fitColumns(of: table)'),
}

# Views of toolbar items that their toolbar gives the width of the nib as the least and lets grow with what they
# hold, by nib and by the id of the view: they are measured as wide as their contents ask.
FLEXIBLE = {
    # The blending item of the PET-CT window.
    'PETCT': {'67'},
    # The Thick Slab item of the orthogonal MPR, whose pop-up draws the whole name of a mode: its toolbar gives it
    # the width its controls ask for in the running language (ToolbarPolicy.localizedSize, which
    # tests/test-orthogonal-mpr-toolbar-views.py requires of it).
    'OrthogonalMPR': {'142'},
}

# Pull-downs whose title the code of their window writes, by the outlet that names them in their nib: the window
# level, the colour table, the opacity table and the convolution filter show the name of the preset in use, and
# the title their nib gives them («Opacity») is never shown. A preset the user made has the name the user gave
# it, which nothing here can measure; the names the code itself writes are measured in the place of the title:
# for each outlet, the catalog keys of the names a window shows when it opens and of the fixed choices of its
# menu. The default window level read «Уровень и шир…» in Russian, 200 points in a pull-down of 99, and
# «Default WL & WW» itself needs 102.
PRESET_PULL_DOWNS = {
    'wlwwPopup': ('Default WL & WW', 'Other', 'Full dynamic'),
    'wlww2DPopup': ('Default WL & WW', 'Other', 'Full dynamic'),
    'clutPopup': ('No CLUT',),
    'clut2DPopup': ('No CLUT',),
    'OpacityPopup': ('Linear Table',),
    'convPopup': ('No Filter',),
}
# Stored tables whose names the code of a window writes when it opens, by nib and by outlet: a table is stored
# under its English name and shown by it in every language. The volume rendering opens a greyscale series with
# this colour table and one of these opacity tables.
STORED_NAMES = {
    'VR': {'clutPopup': ('VR Muscles-Bones',), 'OpacityPopup': ('Logarithmic Table', 'Logarithmic Inverse Table')},
}
# Stored tables whose names the code of a window writes later, by nib, by outlet and with the source that writes
# them, which the pull-down need not hold whole: a pull-down of a preset shows a name that does not fit cut in the
# middle, with the whole name in its menu and its tool tip (PresetPullDownTitle, installed where the nib connects
# the outlet), as it shows a preset of the user's, whose name nothing here can measure. The 3D MPR and the curved
# MPR write this opacity table when the thick slab renders a volume: 136 points in pull-downs of 116. Such a name
# is not measured in the place of the title; its pull-down keeps the width at which the test of that rule,
# tests/test-preset-pull-down-titles.py, requires the cut title to hold six characters of each end of the name.
CUT_NAMES = {
    'MPR': {'OpacityPopup': (('Logarithmic Inverse Table', 'Horos/Sources/MPRController.swift'),)},
    'CPR': {'OpacityPopup': (('Logarithmic Inverse Table', 'Horos/Sources/CPRController.swift'),)},
}
CUT_NAME_RULE = ('Horos/Sources/Window3DController.swift', 'opacityPopupOutlet = popup; PresetPullDownTitle.install(on: popup)', 116)
PRESET_TITLES = ('Horos/Sources/ViewerWindowLevel.swift',
                 ('setPopupTitle(viewer.horos_wlwwPopup', 'setPopupTitle(viewer.horos_clutPopup',
                  'setPopupTitle(viewer.horos_OpacityPopup', 'setPopupTitle(viewer.horos_convPopup'))
# Where the code writes those names.
PRESET_NAME_SOURCES = ('Horos/Sources/ViewerWindowLevel.swift', 'Horos/Sources/ViewerColourTables.swift',
                       'Horos/Sources/VRController+State.swift',
                       'Modules/IsiXImaging/Sources/ViewerReconstruction/VolumeRenderingOpening.swift')

# Cells of their own, by their class and the source that has it: the pop-up of the thick slab mode keeps the whole
# name of a mode in its menu («MIP - Max Intensity Projection») and draws the short one («MIP») when closed, so
# its frame has to hold the widest of the short names, not of the items. The 3D MPR's cell draws what comes before
# the dash of a name, and a name with no dash whole (ThickSlabModeName); the 2D viewer's draws the name its
# catalog gives the tag of a mode, and falls back on that rule. The 2D viewer's has no bezel and needs three
# points less than it is measured with here, as a pop-up of a toolbar.
SHORT_NAME_CELLS = {
    'HorosThickSlabModePopUpButtonCell': 'Horos/Sources/ViewerToolbarItemViews.swift',
    'HorosMPRThickSlabModePopUpButtonCell': 'Horos/Sources/MPRToolbarItemViews.swift',
}
# The cell whose short names are catalog texts, by the tag of the item, and the source of the rule of the others.
SHORT_NAMES_BY_TAG = 'HorosThickSlabModePopUpButtonCell'
SHORT_NAME_RULE = ROOT / 'Modules/IsiXImaging/Sources/ViewerReconstruction/ThickSlabModeName.swift'

# Pull-downs whose menu the code replaces by one it builds, by nib and by their ids, with the source and the call
# it has to hold: the title of the nib is never shown.
MENUS_FROM_CODE = {
    # The sheet that asks for the kind of fusion gives its pull-down the menu of the fusion plugins, whose first
    # item is the title: «Select a fusion plug-in», or «No plugins available for this menu».
    'ViewerPanels': {'875': ('Horos/Sources/ViewerFusion.swift', 'viewer.blendingPlugins?.menu = fusionPlugins')},
}

# Views a nib holds outside its windows that no toolbar holds, by nib and by the id of the view: a sheet or a
# save panel takes them in, and their pop-ups are drawn as those of a window are.
PLAIN_VIEWS = {
    'AnonymizationView': {'23'},
    'QuicktimeExport': {'5'},
}

# Controls the measure finds outside what holds them (contained) and that are not corrected yet, by nib and by
# their ids, with what it reports of each: the list only shrinks, and one that is no longer outside fails the
# test until it is taken off. None is left.
CONTAINMENT_PENDING = {}

# Controls outside what holds them (contained) that no window shows, by nib and by their ids: one that an outlet,
# an action or a binding reaches, or that is no longer outside, fails the test.
OUT_OF_SIGHT = {
    # A second matrix with the titles of the size of a convolution matrix, left in the box of the normalization
    # of the convolution sheet 280 points under the top of that box, which is 64 points high: it stands under the
    # bottom of the sheet.
    'ViewerPanels': {'355'},
}


def catalog(language):
    path = RESOURCES / f'{language}.lproj/Localizable.strings'
    return plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'binary1', '-o', '-', str(path)]))


def with_catalog(name, language, table, folder):
    """A copy of the English nib named `name` with every text it shows as the catalog of `language` writes it."""
    tree = ET.parse(RESOURCES / f'en.lproj/{name}.xib')
    root = tree.getroot()
    for top in root.find('objects'):
        for element, attribute in pane_translations.shown_texts(top, root):
            text = pane_translations.text_of(element, attribute)
            if table.get(text, text) != text:
                pane_translations.set_text(element, attribute, table[text])
    copy = Path(folder) / f'{name}-{language}.xib'
    tree.write(copy, encoding='utf-8', xml_declaration=True)
    return copy


def titled_in_code(name):
    """Ids of the pop-ups of the nib named `name` whose closed title is not a text of the nib and is not measured:
    the pull-downs whose menu the code replaces."""
    return set(MENUS_FROM_CODE.get(name, ()))


def with_preset_names(name, language, path, table, folder):
    """`path`, or a copy of that nib in which each pull-down of a preset is a pop-up of the names the code writes
    into it, in the language of the nib: the measure then reads the widest of them against the frame."""
    tree = ET.parse(path)
    root = tree.getroot()
    outlets = {outlet.get('destination'): outlet.get('property') for outlet in root.iter('outlet')
               if outlet.get('property') in PRESET_PULL_DOWNS}
    pull_downs = [pop_up for pop_up in root.iter('popUpButton') if pop_up.get('id') in outlets]
    if not pull_downs:
        return path
    for pop_up in pull_downs:
        outlet = outlets[pop_up.get('id')]
        names = [table.get(key, key) for key in PRESET_PULL_DOWNS[outlet]] + list(STORED_NAMES.get(name, {}).get(outlet, ()))
        cell = pop_up.find('popUpButtonCell')
        items = cell.find('menu').find('items')
        for item in list(items):
            items.remove(item)
        for place, title in enumerate(names):
            ET.SubElement(items, 'menuItem', {'title': title, 'id': f'pre-{pop_up.get("id")[:3]}-{place:03d}'})
        cell.attrib.pop('pullsDown', None)
        cell.set('title', names[0])
        cell.set('selectedItem', items[0].get('id'))
    copy = Path(folder) / f'{name}-{language}-presets.xib'
    tree.write(copy, encoding='utf-8', xml_declaration=True)
    return copy


def tag_names():
    """{tag: catalog key} of the short names the 2D viewer's cell reads from the catalog."""
    source = (ROOT / SHORT_NAME_CELLS[SHORT_NAMES_BY_TAG]).read_text(encoding='utf-8')
    return {tag: key for tag, key in re.findall(r'case (\d+): return NSLocalizedString\("([^"]+)"', source)}


def short_names(names, folder):
    """What ThickSlabModeName, compiled as it is, draws for each of `names`."""
    tool = Path(folder) / 'short-names/tool'
    if not tool.exists():
        tool.parent.mkdir()
        driver = tool.parent / 'main.swift'
        driver.write_text('import Foundation\nwhile let name = readLine() { print(ThickSlabModeName.short(of: name)) }\n')
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(tool.parent / 'modules'), str(driver), str(SHORT_NAME_RULE),
                        '-o', str(tool)], check=True, capture_output=True)
    drawn = subprocess.run([str(tool)], input='\n'.join(names) + '\n', capture_output=True, text=True, check=True).stdout
    return dict(zip(names, drawn.split('\n')))


def with_short_names(name, language, path, table, folder):
    """`path`, or a copy of that nib in which the items of the pop-ups whose cell draws a short name are the short
    names, in the language of the nib: the measure then reads what the closed pop-up draws."""
    tree = ET.parse(path)
    cells = [cell for cell in tree.getroot().iter('popUpButtonCell') if cell.get('customClass') in SHORT_NAME_CELLS]
    if not cells:
        return path
    by_tag = tag_names()
    # The 2D viewer's pop-up is as wide as the short name it shows, by the size its cell gives it, and its row
    # lets it grow as far as the unit after it: here it is drawn out to that room, which the widest name has to fit.
    for pop_up in tree.getroot().iter('popUpButton'):
        if any(cell.get('customClass') == SHORT_NAMES_BY_TAG for cell in pop_up.iter('popUpButtonCell')):
            constraints = pop_up.find('constraints')
            if constraints is None:
                constraints = ET.Element('constraints')
                pop_up.insert(1, constraints)
            ET.SubElement(constraints, 'constraint', {'firstAttribute': 'width', 'constant': '600', 'priority': '700',
                                                      'id': 'sho-rt-nam'})
    items = [(cell, item) for cell in cells for item in cell.iter('menuItem') if item.get('title')]
    ruled = short_names(sorted({item.get('title') for _, item in items}), folder)
    for cell, item in items:
        key = by_tag.get(item.get('tag', '')) if cell.get('customClass') == SHORT_NAMES_BY_TAG else None
        short = table.get(key, key) if key else ruled[item.get('title')]
        if cell.get('title') == item.get('title'):
            cell.set('title', short)
        item.set('title', short)
    copy = Path(folder) / f'{name}-{language}-short.xib'
    tree.write(copy, encoding='utf-8', xml_declaration=True)
    return copy

# Matrices whose frame passes the box that holds them and that draw nothing outside it, by nib and by their ids,
# with the constraint of the nib that ends the box before the matrix does and the width of the border of the box.
FRAMES_PAST_THEIR_BOX = {
    # The modalities of the Query window: two columns of cells of 54 points for titles of two letters, which draw
    # 34. The constraint ends the box 9 points before the end of the matrix, so that the box closes on what the
    # second column draws and not on the empty end of its cells: with the border of the box, the frame of the
    # matrix is 10 points outside the view that holds it, which a measure of frames reports, and nothing is cut.
    'Query': {'528': ('gLH-a6-oRw', 1)},
}
PAST_ITS_BOX = r'<constraint firstAttribute="trailing" secondItem="%s" secondAttribute="trailing" constant="-([\d.]+)" id="%s" ?/>'


def misfits(name, tables, folder):
    """What does not fit in the nib named `name`, as messages that start with the language."""
    copies = {language: RESOURCES / f'{language}.lproj/{name}.xib' for language in COPIES}
    missing = [f'{language}: no copy of the nib' for language, path in copies.items() if not path.exists()]
    copies = {language: path for language, path in copies.items() if path.exists()}
    read = {language: with_catalog(name, language, tables[language], folder) for language in CATALOG_LANGUAGES
            if not (RESOURCES / f'{language}.lproj/{name}.xib').exists()}
    copies = {language: with_short_names(name, language, path, {} if language == 'en' else tables[language], folder)
              for language, path in copies.items()}
    read = {language: with_short_names(name, language, path, tables[language], folder) for language, path in read.items()}
    copies = {language: with_preset_names(name, language, path, {} if language == 'en' else tables[language], folder)
              for language, path in copies.items()}
    read = {language: with_preset_names(name, language, path, tables[language], folder) for language, path in read.items()}
    free = FLEXIBLE.get(name, ())
    plain = PLAIN_VIEWS.get(name, ())
    measured = pane_titles.measure(copies, every_window=True, every_view=True, every_tab=True, pin_views=True, free_views=free,
                                   headers=True, pop_ups=True, plain_views=plain, contained=True)
    if read:
        measured += pane_titles.measure(read, every_window=True, every_view=True, every_tab=True, pin_views=True, free_views=free,
                                        room=ROOM, headers=True, pop_ups=True, plain_views=plain, contained=True)
    languages = {item['language'] for item in measured}
    # A nib that holds no title at all (a view the code fills, a panel of images) has nothing to measure.
    if measured and len(languages) != len(copies) + len(read):
        missing.append(f'only {sorted(languages)} of its {len(copies) + len(read)} variants were measured')
    alternates = ALTERNATES.get(name, ())
    laid_out = set(LAID_OUT_IN_CODE.get(name, ()))
    filled = set(FILLED_IN_CODE.get(name, ())) | laid_out
    # Two controls the code lays out do not cross where it puts them, whatever their frames in the nib.
    kept = [item for item in measured
            if not ('overlap' in item and (frozenset(item['overlap']) in alternates or laid_out.issuperset(item['overlap'])))
            and not item.get('id', '').split('/')[0] in filled
            and not ('header' in item and item['table'] in HEADERS_FIT_IN_CODE.get(name, ()))
            and not ('header' in item and item['table'] in TABLES_BUILT_IN_CODE.get(name, ((),))[0])]
    # The closed title of some pop-ups is the code's.
    code_titles = titled_in_code(name)
    kept = [item for item in kept if not (item.get('popUp') and item['id'] in code_titles)]
    # A control known to reach outside what holds it is not reported again (contained); one that no longer does is.
    pending = set(CONTAINMENT_PENDING.get(name, {})) | OUT_OF_SIGHT.get(name, set())
    outside = {item['id'] for item in kept if item.get('contained') is False}
    missing += [f'en: the control {ident} no longer reaches outside what holds it: take it off the list that names it'
                for ident in sorted(set(pending) - outside)]
    kept = [item for item in kept if not (item.get('contained') is False and item['id'] in pending)]
    # What the cells of a matrix that passes its box draw ends inside the box (FRAMES_PAST_THEIR_BOX).
    for matrix, (constraint, border) in FRAMES_PAST_THEIR_BOX.get(name, {}).items():
        for language, path in list(copies.items()) + list(read.items()):
            past = re.search(PAST_ITS_BOX % (matrix, constraint), path.read_text(encoding='utf-8'))
            cells = [item for item in measured if item['language'] == language and item.get('id', '').startswith(matrix + '/')]
            if not past or not cells:
                missing.append(f'{language}: the matrix {matrix} no longer passes its box by the constraint {constraint}, or has no '
                               f'titled cell: take it off FRAMES_PAST_THEIR_BOX')
                continue
            outside = float(past.group(1)) + border
            missing += [f'{language}: "{item["title"]}" needs {item["needed"]:.0f} points, and its cell (id {item["id"]}) has '
                        f'{item["width"] - outside:.0f} inside the box of its matrix' for item in cells
                        if item['needed'] > item['width'] - outside + 0.5]
    return missing + pane_titles.misfits(kept), len(kept)


if not pane_titles.available():
    print('skipped: needs xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(2)

every = sorted(path.stem for path in (RESOURCES / 'en.lproj').glob('*.xib') if path.stem not in ELSEWHERE)
asked = [argument for argument in sys.argv[1:] if not argument.startswith('--')]
inventory = '--inventory' in sys.argv
failures = []
if not inventory and not asked:
    listed = set(NIBS) | PENDING
    failures += [f'{name}: a nib of a window that is neither measured nor pending' for name in every if name not in listed]
    failures += [f'{name}: listed, and no nib of a window has that name' for name in sorted(listed - set(every))]
    failures += [f'{name}: both measured and pending' for name in sorted(set(NIBS) & PENDING)]
    failures += [f'{name}: its alternates or its flexible views are named, and it is not measured'
                 for name in sorted((set(ALTERNATES) | set(FLEXIBLE) | set(FILLED_IN_CODE) | set(LAID_OUT_IN_CODE)
                                     | set(HEADERS_FIT_IN_CODE) | set(TABLES_BUILT_IN_CODE) | set(MENUS_FROM_CODE)
                                     | set(PLAIN_VIEWS)) - set(NIBS))]
    # The pop-ups whose title is the code's: every outlet and every cell named is some nib's, and the code still
    # writes the titles.
    nibs = {name: (RESOURCES / f'en.lproj/{name}.xib').read_text(encoding='utf-8') for name in NIBS if name in every}
    failures += [f'{outlet}: no nib of a window has a pull-down by that outlet'
                 for outlet in PRESET_PULL_DOWNS if not any(f'<outlet property="{outlet}" ' in text for text in nibs.values())]
    writer = (ROOT / PRESET_TITLES[0]).read_text(encoding='utf-8')
    failures += [f'{PRESET_TITLES[0]} no longer holds "{call}": the pull-down shows the title of its nib'
                 for call in PRESET_TITLES[1] if call not in writer]
    # The names measured in those pull-downs are names the code writes.
    writers = ''.join((ROOT / source).read_text(encoding='utf-8') for source in PRESET_NAME_SOURCES)
    failures += [f'"{key}": no source of {PRESET_NAME_SOURCES} writes that name of a preset any more'
                 for key in sorted({key for keys in PRESET_PULL_DOWNS.values() for key in keys}) if f'NSLocalizedString("{key}"' not in writers]
    failures += [f'{name}: "{stored}": no source of {PRESET_NAME_SOURCES} writes that name of a stored table any more'
                 for name, outlets in STORED_NAMES.items() for names in outlets.values() for stored in names if f'"{stored}"' not in writers]
    failures += [f'{name}: its stored names are listed, and it is not measured' for name in sorted(set(STORED_NAMES) - set(NIBS))]
    # The names shown cut: the window still writes each, the pull-down has the rule that cuts it, and every copy of
    # the nib keeps the pull-down as wide as the test of the rule takes it to be.
    if CUT_NAME_RULE[1] not in (ROOT / CUT_NAME_RULE[0]).read_text(encoding='utf-8'):
        failures.append(f'{CUT_NAME_RULE[0]} no longer holds "{CUT_NAME_RULE[1]}": a name that does not fit is cut at its end')
    for name, outlets in CUT_NAMES.items():
        failures += [f'{name}: "{cut}": {source} writes that name of a stored table no more' for names in outlets.values()
                     for cut, source in names if f'"{cut}"' not in (ROOT / source).read_text(encoding='utf-8')]
        for copy in sorted(RESOURCES.glob(f'*.lproj/{name}.xib')):
            document = ET.parse(copy).getroot()
            ids = {outlet.get('destination') for outlet in document.iter('outlet') if outlet.get('property') in outlets}
            widths = [float(pop_up.find('rect').get('width')) for pop_up in document.iter('popUpButton') if pop_up.get('id') in ids]
            if len(widths) != len(outlets) or min(widths, default=0) < CUT_NAME_RULE[2]:
                failures.append(f'{copy.parent.name[:-6]} {name}.xib: its pull-downs of {sorted(outlets)} are {widths} points '
                                f'wide; a name cut in the middle is checked at {CUT_NAME_RULE[2]}')
    failures += [f'{name}: its names shown cut are listed, and it is not measured' for name in sorted(set(CUT_NAMES) - set(NIBS))]
    for cell, source in SHORT_NAME_CELLS.items():
        if not any(f'customClass="{cell}"' in text for text in nibs.values()):
            failures.append(f'{cell}: no pop-up of a window nib has that cell')
        if f'@objc({cell})' not in (ROOT / source).read_text(encoding='utf-8'):
            failures.append(f'{cell}: {source} no longer has the cell that draws a short name')
        if 'ThickSlabModeName.short(of: ' not in (ROOT / source).read_text(encoding='utf-8'):
            failures.append(f'{cell}: {source} no longer takes a short name from the rule the pop-ups are measured with')
    if len(tag_names()) < 5:
        failures.append(f'{SHORT_NAMES_BY_TAG}: the short names its source reads from the catalog, by tag, were not found')
    if 'ToolbarPolicy.localizedSize(of: ThickSlabView)' not in (ROOT / 'Horos/Sources/OrthogonalMPRViewer.swift').read_text(encoding='utf-8'):
        failures.append('OrthogonalMPR: the Thick Slab item no longer takes the width its controls ask for')
    # The radios of the mouse buttons of the 2D viewer are still laid out by their item (contained).
    tools = (ROOT / 'Horos/Sources/ViewerToolbarItemFactory.swift').read_text(encoding='utf-8')
    failures += [f'Viewer: ViewerToolbarItemFactory.swift no longer holds "{call}": the radios of the mouse buttons are shown as '
                 'their nib lays them out' for call in ('matrix.sizeToCells()', 'matrix.centerXAnchor.constraint(equalTo: view.centerXAnchor)',
                                                        'ToolbarPolicy.localizedSize(of: viewer.horos_toolsView)') if call not in tools]
    # A control out of sight has no connection (contained).
    for name, identifiers in OUT_OF_SIGHT.items():
        tree = ET.fromstring(nibs[name])
        for identifier in sorted(identifiers):
            control = tree.find(f'.//*[@id="{identifier}"]')
            if control is None or control.find('.//connections') is not None or any(
                    identifier in (element.get('destination'), element.get('target')) for element in tree.iter()):
                failures.append(f'{name}: the control {identifier} is named out of sight, and an outlet, an action or a binding reaches it')
    for name, pull_downs in MENUS_FROM_CODE.items():
        for identifier, (source, call) in pull_downs.items():
            if call not in (ROOT / source).read_text(encoding='utf-8'):
                failures.append(f'{name}: {source} no longer holds "{call}": the pull-down {identifier} shows the title of its nib')
    for name, (_, source, held) in TABLES_BUILT_IN_CODE.items():
        text = (ROOT / source).read_text(encoding='utf-8')
        failures += [f'{name}: {source} no longer holds "{call}": the table of the nib is shown again, or the columns the '
                     f'window builds are not fitted to their headers' for call in held if call not in text]
    for name, (source, call) in WINDOWS_BUILT_IN_CODE.items():
        if call not in (ROOT / source).read_text(encoding='utf-8'):
            failures.append(f'{name}: {source} no longer fits the columns of its table to their headers ({call})')
    manager = (ROOT / 'Horos/Sources/PluginManagerController.swift').read_text(encoding='utf-8')
    if 'uninstallPluginButton.cell?.cellSize.width' not in manager or 'uninstallPluginButton.frame = frame' not in manager:
        failures.append('PluginManager: the manager no longer gives the button that uninstalls a plugin the width of its title')
    if 'pluginTable.sizeToFit()' not in manager or 'names.minWidth = min(names.minWidth, 200)' not in manager:
        failures.append('PluginManager: the manager no longer lets the column of the names narrow to keep the list as wide as its view')
    results = (ROOT / 'Horos/Sources/QueryController+Results.swift').read_text(encoding='utf-8')
    fitted = results[results.find('func resultColumnsDidReadCatalog()'):results.find('func saveTableColumns()')]
    if 'PaneFit.widenColumnsToHeaders(of: outlineView)' not in fitted or 'PaneFit.fitColumns(of: outlineView)' not in fitted:
        failures.append('Query: the window no longer widens the columns of its results to their headers')
    shading = (ROOT / 'Horos/Sources/MPRToolbarItemViews.swift').read_text(encoding='utf-8')
    if 'check.setContentCompressionResistancePriority(.required, for: .horizontal)' not in shading:
        failures.append('MPR: the Shadings item no longer gives its checkbox the width of its title')

tables = {language: catalog(language) for language in CATALOG_LANGUAGES + COPIES[1:]}
names = [name for name in (every if inventory else NIBS) if not asked or name in asked]
counted = 0
with tempfile.TemporaryDirectory(prefix='window-nib-titles-') as folder:
    for name in names:
        try:
            found, count = misfits(name, tables, folder)
        except (RuntimeError, subprocess.CalledProcessError) as error:
            found, count = [f'its titles could not be measured: {str(error)[-300:]}'], 0
        counted += count
        failures += [f'{name}: {failure}' for failure in found]
        if inventory:
            by_language = {}
            for failure in found:
                by_language[failure.split(':')[0]] = by_language.get(failure.split(':')[0], 0) + 1
            state = 'pending' if name in PENDING else 'measured' if name in NIBS else 'unlisted'
            print(f'{name} ({state}): {count} titles and overlaps measured, {len(found)} do not fit '
                  + ', '.join(f'{language} {number}' for language, number in sorted(by_language.items())), flush=True)

    if not inventory and not asked:
        # The measure itself: the English export sheet with its cells of 55 points again must be reported.
        narrow = Path(folder) / 'en.xib'
        text = (RESOURCES / 'en.lproj/ViewerPanels.xib').read_text(encoding='utf-8')
        wide = '<size key="cellSize" width="78" height="67"/>'
        if text.count(wide) != 1:
            failures.append('ViewerPanels: the cells of the destinations of an image export are not 78 points wide')
        narrow.write_text(text.replace(wide, '<size key="cellSize" width="55" height="67"/>'), encoding='utf-8')
        reported = pane_titles.misfits(pane_titles.measure({'en': narrow}, every_window=True))
        if not any('"JPEG Files" needs' in message for message in reported):
            failures.append('the measure does not report "JPEG Files" in a cell of 55 points')
        # And a header: the column of the plugin manager that says how a plugin loaded, as narrow as its checkboxes'.
        narrow = Path(folder) / 'ru.xib'
        text = (RESOURCES / 'ru.lproj/PluginManager.xib').read_text(encoding='utf-8')
        wide = 'width="126" minWidth="126" maxWidth="126" id="OCE-FJ-HJu"'
        if text.count(wide) != 1:
            failures.append('PluginManager: the column of the load status is not 126 points wide')
        narrow.write_text(text.replace(wide, 'width="60" minWidth="60" maxWidth="60" id="OCE-FJ-HJu"'), encoding='utf-8')
        reported = pane_titles.misfits(pane_titles.measure({'ru': narrow}, every_window=True, headers=True))
        if not any(message.startswith('ru: the header ') and 'has 60' in message for message in reported):
            failures.append('the measure does not report the header of a column of 60 points that needs 122')
        # And a pull-down: the one of the filters of the volume rendering in the item of 118 points it had, which
        # left it 110, where the running application showed «Применить ф…».
        narrow = Path(folder) / 'ru.xib'
        text = (RESOURCES / 'ru.lproj/VR.xib').read_text(encoding='utf-8')
        wide = '<constraint firstAttribute="width" constant="136" id="W87-fr-ke7"/>'
        if text.count(wide) != 1:
            failures.append('VR: the item of the filters is not 136 points wide')
        narrow.write_text(text.replace(wide, wide.replace('136', '118')), encoding='utf-8')
        reported = pane_titles.misfits(pane_titles.measure({'ru': narrow}, every_window=True, every_view=True, pin_views=True,
                                                           pop_ups=True))
        if not any('the pull-down "Применить фильтр" needs 127 points, its frame (id 954) has 110' in message for message in reported):
            failures.append('the measure does not report the pull-down of the filters, which needs 127 points, in 110')
        # And a control that a binding fills: the count of the key images of the 2D viewer stands after the
        # checkbox of its toolbar item, and with the 21 points it stood from it the Russian checkbox, 150 points
        # wide, put it past the end of the item. A count is data, and its frame is drawn all the same.
        narrow = Path(folder) / 'ru.xib'
        text = (RESOURCES / 'ru.lproj/Viewer.xib').read_text(encoding='utf-8')
        near = 'secondItem="1205" secondAttribute="trailing" constant="4" id="0JE-4N-fXM"/>'
        if text.count(near) != 1:
            failures.append('Viewer: the count of the key images no longer stands 4 points from its checkbox')
        narrow.write_text(text.replace(near, near.replace('constant="4"', 'constant="40"')), encoding='utf-8')
        reported = pane_titles.misfits(pane_titles.measure({'ru': narrow}, every_window=True, every_view=True, pin_views=True,
                                                           contained=True))
        if not any('(id 2455) reaches' in message for message in reported):
            failures.append('the measure does not report the count of the key images past the end of its toolbar item')
        # And a control outside what holds it (contained): the count of the images of the 2D viewer's movie export,
        # the last row of a box that had no bottom of its own and was cut through by it.
        narrow = Path(folder) / 'en.xib'
        text = (RESOURCES / 'en.lproj/ViewerPanels.xib').read_text(encoding='utf-8')
        bottom = [line for line in text.split('\n') if 'secondItem="2076" secondAttribute="bottom"' in line]
        if len(bottom) != 1:
            failures.append('ViewerPanels: the box of the movie export no longer stands its bottom under the count of the images')
        narrow.write_text('\n'.join(line for line in text.split('\n') if line not in bottom), encoding='utf-8')
        reported = pane_titles.misfits(pane_titles.measure({'en': narrow}, every_window=True, contained=True))
        if not any('"Images:" (id 2076) reaches' in message and 'outside the box' in message for message in reported):
            failures.append('the measure does not report the count of the images outside the box of the movie export')

if inventory:
    for failure in failures:
        print('  ' + failure.replace('\n', ' / '))
    sys.exit(0)
if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: {counted} titles, pop-ups and table headers fit their controls and columns in {len(COPIES) + len(CATALOG_LANGUAGES)} languages of {len(names)} window nibs; '
      f'{len(PENDING)} nibs are pending')
