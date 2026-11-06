"""Compile a focused driver against the same installed DCMTK archives as Horos."""
from pathlib import Path
import os

ROOT = Path(__file__).resolve().parents[1]
CONFIGURATION = os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')
# script/build_and_run.sh passes -derivedDataPath build, which puts the
# intermediates at build/Intermediates.noindex; older layouts had build/Build.
BUILD = next((base / 'Intermediates.noindex/Horos.build' / CONFIGURATION
              for base in (ROOT / 'build', ROOT / 'build/Build')
              if (base / 'Intermediates.noindex/Horos.build' / CONFIGURATION).is_dir()),
             ROOT / 'build/Intermediates.noindex/Horos.build' / CONFIGURATION)
INSTALL = Path(os.environ.get('HOROS_TEST_DCMTK_INSTALL', str(BUILD / 'DCMTK.build/Install')))


def dcmtk_flags(*modules):
    modules = list(dict.fromkeys([*modules, 'dcmdata', 'oflog', 'ofstd', 'oficonv']))
    archives = [INSTALL / 'lib' / ('lib' + name + '.a') for name in modules]
    missing = [path for path in [INSTALL / 'include/dcmtk/config/osconfig.h', *archives]
               if not path.is_file()]
    if missing:
        print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(missing[0]))
        raise SystemExit(2)
    return ['-I' + str(INSTALL / 'include'), '-I' + str(ROOT / 'Horos/Sources'),
            *map(str, archives), '-lz', '-liconv']


def dcmtk_source():
    """The original DCMTK source the build compiles: the archive pinned in
    Horos/Scripts/external-sources.json, verified and extracted read-only by
    the same resolver as the recipe. For internal sources and data files that
    the installation does not carry; public headers are read from INSTALL."""
    from sources import dependency_source
    return dependency_source('DCMTK')


def dcmtk_dictionary():
    """The external dicom.dic of the pinned DCMTK source, the file the build
    ships beside the executables."""
    return dcmtk_source() / 'dcmdata/data/dicom.dic'
