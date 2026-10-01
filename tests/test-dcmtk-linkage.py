#!/usr/bin/env python3
"""The pin, build graph, application policies and catalog describe the same library."""
from pathlib import Path
import re
import json
import sys
import subprocess
import tempfile
from dcmtk_build import ROOT, INSTALL, dcmtk_flags

IMPLEMENTATION_UID = '1.2.276.0.7230010.3.0.3.7.0'
pin = (ROOT / 'Horos/Scripts/DCMTK/UPSTREAM_REVISION').read_text().strip()
assert re.fullmatch('[0-9a-f]{40}', pin)
assert subprocess.check_output(['git','-C',str(ROOT/'DCMTK'),'rev-parse','HEAD'],text=True).strip() == pin
assert not subprocess.check_output(['git','-C',str(ROOT/'DCMTK'),'status','--porcelain'],text=True).strip()
index = subprocess.check_output(['git','-C',str(ROOT),'ls-files','--stage','--','DCMTK'],text=True).split()
assert index[:2] == ['160000', pin]
project=(ROOT/'Horos.xcodeproj/project.pbxproj').read_text()
assert 'Binaries/dcmtk-source' not in project
for name in ('HorosDIMSEPolicy.swift','HorosDIMSEAssociationPolicy.swift','HorosDIMSEGet.mm',
             'HorosDIMSEMove.mm','HorosQueryRetrieveServer.mm','dcmqrdbq.mm'):
    assert name+' in Sources' in project,name
assert '"-ldcmnet"' in project and '"-ldcmdata"' in project
assert '"-lhorosdcmjpls"' in project and '"-ldcmtkcharls"' not in project
listener=(ROOT/'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_text(encoding='latin1')
assert 'new HorosQueryRetrieveServer(' in listener
assert 'public DcmThreadSCP' in (ROOT/'Horos/Sources/HorosQueryRetrieveServer.mm').read_text()
script=(ROOT/'Horos/Scripts/DCMTK/CMake.sh').read_text()
for option in ('BUILD_SHARED_LIBS=OFF','CMAKE_CXX_STANDARD=11','DCMTK_DEFAULT_DICT=builtin',
               'DCMTK_WITH_OPENSSL=ON','DCMTK_MAX_SEQUENCE_NESTING=16','CMAKE_BUILD_TYPE='):
    assert option in script,option
for forbidden in ('git reset','git checkout','git apply'):
    assert forbidden not in script
assert 'git -C "$source_dir" status --porcelain' in script
assert 'print-status' not in script
assert not (ROOT/'Horos/Scripts/DCMTK/DCMTK-3.6.7-print-status.patch').exists()
assert 'HorosStoredPrint in Resources' in project and 'dcmprscu in Resources' not in project
assert 'BuildStoredPrint.sh' in (ROOT/'Horos/Scripts/DCMTK/Make.sh').read_text()
for name in ('main.swift','HorosStoredPrintBridge.mm','HorosStoredPrintBridge.h'):
    assert '$PROJECT_DIR/DICOMPrint/Helper/'+name in script,name
assert 'touch "$BUILT_PRODUCTS_DIR/DCMTK/.incomplete"' in script
for name in ('DICOMwebClient.swift','DICOMwebCredentials.swift','DICOMwebMultipart.swift','DICOMwebNodeEditor.swift'):
    assert (ROOT/'Horos/Sources'/name).is_file()
assert 'identifier: "dcmtk"' in (ROOT/'Horos/Sources/LicenseAttribution.swift').read_text()
# Verify the recipe against the catalog before installed-build checks.
catalog = json.loads((ROOT / 'Horos/Scripts/DCMTK/PREPARATION.json').read_text())
preparation = catalog
assert preparation['base']['revision'] == pin
for option in preparation['options']:
    if option.startswith(('CMAKE_BUILD_TYPE=', 'CMAKE_OSX_')):
        assert option.split('=')[0] in script
    elif option == 'DCMTK_ENABLE_CXX11=ON':
        continue  # upstream derives it from CMAKE_CXX_STANDARD=11
    else:
        assert option in script, option
# The pinned checkout is compiled as it is: the recipe applies no patch and
# prepares no copy, and the catalog says so for the library and for the app.
assert preparation['patches'] == [] and '/usr/bin/patch' not in script and 'ditto "$source_dir"' not in script
for key in ('compiled_library', 'compiled_into_app'):
    assert catalog[key]['revision'] == pin
    assert catalog[key]['equivalent_to_pin'] and catalog[key]['upstream_unpatched'] and catalog[key]['patches'] == []
assert preparation['jpeg_ls']['changes_source'] is False
assert 'libhorosdcmjpls.a' in (ROOT / preparation['jpeg_ls']['script']).read_text()
print('PASS: the catalog and the recipe agree that the pinned upstream sources are compiled unpatched')

if '--source-only' in sys.argv:
    raise SystemExit(0)
dcmtk_flags('dcmnet','dcmqrdb','dcmtls')
configuration=(INSTALL/'include/dcmtk/config/osconfig.h').read_text()
assert '#define PACKAGE_VERSION "3.7.0"' in configuration
assert '#define PACKAGE_VERSION_SUFFIX "+"' in configuration
print('PASS: clean upstream pin, installed library version, build graph and application-owned DIMSE policy agree')

with tempfile.TemporaryDirectory(prefix='horos-library-identity-') as temporary:
    directory = Path(temporary)
    (directory / 'main.cc').write_text('#include <dcmtk/dcmdata/dcuid.h>\n#include <cstdio>\nint main(){puts(OFFIS_IMPLEMENTATION_CLASS_UID);}')
    subprocess.run(['xcrun', 'clang++', '-std=c++11', str(directory/'main.cc'),
                    *dcmtk_flags('dcmnet'), '-o', str(directory/'check')], check=True)
    actual = subprocess.check_output([str(directory/'check')], text=True).strip()
    assert actual == IMPLEMENTATION_UID, actual
    assert actual in (ROOT/'Horos/Sources/HorosDIMSEPolicy.swift').read_text()
print('PASS: expected and Swift identity equal the installed upstream implementation UID')
