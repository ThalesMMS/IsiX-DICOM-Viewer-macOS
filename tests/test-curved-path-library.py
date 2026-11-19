#!/usr/bin/env python3
"""A curved MPR window keeps several paths with names, and opens a coronary MIP from them.

A window had one path. A coronary CT is read along three or four vessels:
the window keeps a path for each, chosen from a menu of its toolbar, and its
path file - the one kept with the series and the one Save Path writes - holds
them all. The storage and the tube of the MIP are the module's
(`CurvedPathSet`, `VesselTube`, with tests of their own: several paths
written and read back, the former file of one path still read, the voxels
outside the tube left out). What is checked here is their place in the
application:

- the window reads and writes its path file through its path library, which
  keeps the set and decodes only curved paths;
- choosing, adding, renaming and deleting a path keep the path shown before
  they change it, and show the path chosen through the window, with its slab;
- the toolbar offers the Paths menu and the Coronary MIP button, by default
  and in its palette;
- the coronary MIP copies the volume, keeps the voxels within the tube
  around every path with points and opens a MIP of the copy: the series
  itself is not changed;
- the texts are in the twelve catalogs. The menu and the button are made in
  code, so no nib has a copy of them.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def text(path):
    return (root / path).read_text(encoding='utf-8')


controller = text('Horos/Sources/CPRController.swift')
library = text('Horos/Sources/CurvedPathLibrary.swift')
checks = [
    ('pathLibrary.save(toFile: path)' in controller and 'if !pathLibrary.load(fromFile: path) { _ = self.importPatientSpaceCenterline(fromFile: path) }' in controller,
     'the window reads and writes its path file through its path library'),
    ('NSKeyedArchiver' not in controller.split('func saveBezierPathToFile')[1].split('func importPatientSpaceCenterline')[0],
     'the window no longer archives its one path itself'),
    ('written.store(archive, defaultName: Self.defaultName)' in library and 'written.fileData(defaultName: Self.defaultName)' in library
     and 'CurvedPathSet(fileData: data, defaultName: Self.defaultName)' in library, 'the file is the set\'s, the path shown as it is now'),
    ('NSKeyedUnarchiver.unarchivedObject(ofClass: CPRCurvedPath.self, from: archive)' in library and 'requiringSecureCoding: true' in library,
     'a path of the file is decoded as a curved path and nothing else'),
    ('guard let current = read.current, let path = Self.path(from: current.path) else { return false }' in library,
     'a file with no path that opens is left to the import of points'),
    (all(f'func {name}' in library for name in ('showPath(at index: Int)', 'addPath(named name: String)', 'renameShownPath(to name: String)', 'deleteShown('))
     and library.count('storeShown()') >= 5, 'choosing, adding and renaming keep the path shown first'),
    ('controller?.showLoadedPath(path)' in library and 'func showLoadedPath(_ newCurvedPath: CPRCurvedPath)' in controller
     and 'self.setClippingRangeThicknessInMm(slabWithinEnds(Double(newCurvedPath.thickness)))' in controller,
     'a path chosen is shown through the window, with its slab'),
    ('NSToolbarItem.Identifier(CurvedPathLibrary.pathsItem), NSToolbarItem.Identifier(CurvedPathLibrary.coronaryMIPItem)' in controller
     and 'CurvedPathLibrary.pathsItem, CurvedPathLibrary.coronaryMIPItem, "tbCPRPathMode"' in controller
     and 'pathLibrary.configure(toolbarItem, as: itemIdent.rawValue)' in controller, 'the toolbar has the Paths menu and the Coronary MIP button'),
    ('viewer.copyVolumeData(&volumeData, andDCMPix: &copied' in library and 'VesselTube.mask(of: grid, around: paths, radius: tubeRadius)' in library
     and 'VesselTube.keep(mask, of: voxels, elsewhere: outside)' in library
     and 'VRController(pix: copied, files, volumeData, nil, viewer, style: "standard", mode: "MIP")' in library,
     'the coronary MIP is a MIP of a copy of the volume with the voxels outside the tube left out'),
    ('guard !paths.isEmpty, let viewer = controller?.viewer() else { NSSound.beep(); return }' in library, 'no path with a point, no MIP'),
    ('(ReconstructionPreferences.cprToolbarPathsInserted, [CurvedPathLibrary.pathsItem, CurvedPathLibrary.coronaryMIPItem], "tbStenosis")'
     in text('Horos/Sources/CPRToolbarAdditions.swift') and 'CPRToolbarAdditions.insertOnce(into: toolbar, store: self.preferenceStore)' in controller,
     'a toolbar saved before them gets the two items once, after Stenosis'),
    ('import IsiXImaging' in library and 'struct CurvedPathSet' not in library and 'enum VesselTube' not in library, 'the set and the tube are the module\'s'),
]
languages = sorted(p.name[:-6] for p in (root / 'Horos/Resources').glob('*.lproj') if (p / 'Localizable.strings').exists())
checks.append((len(languages) == 12, f'twelve catalogs: {languages}'))
for key in ('Path', 'Paths', 'New Path', 'Other…', 'Rename…', 'Delete Path', 'Coronary MIP', 'Coronary MIP Radius', '%@ mm around the paths',
            'Name of the path:', 'Coronary MIP: %@'):
    checks.append((f'NSLocalizedString("{key}"' in library, f'the library shows the text {key!r}'))
    for language in languages:
        raw = (root / f'Horos/Resources/{language}.lproj/Localizable.strings').read_bytes()
        catalog = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8')
        checks.append((f'"{key}" = ' in catalog, f'{language} has the text {key!r}'))
for ok, what in checks:
    if not ok:
        failures.append(what)
if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print(f'PASS: the curved MPR window keeps its paths in its path library and opens the coronary MIP from them; {len(languages)} catalogs have the texts')
