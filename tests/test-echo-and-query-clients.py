#!/usr/bin/env python3
"""Verification shares the query association setup, TLS and timeout configuration.

Native wire evidence and peer tests are documented in
the verification-stack implementation.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import class_text, source_text  # noqa: E402
failures = []
# OSILocationsPreferencePanePref is Swift.
pane = source_text('OSILocationsPreferencePanePref')
reporter = (root / 'tools/report-association-identity.py')

# The framework bridge must reach the executable's query implementation.
live = re.sub(r'//[^\n]*', '', pane)
region = live[live.find('@objc(echoAddress:'):live.find('func enableControls(')]
if ('NSSelectorFromString("verifyDICOMServer:")' not in region
        or 'verifyDICOMServer(queryClass, selector, serverParameters)' not in region
        or 'NSClassFromString("DCMTKQueryNode")' not in region):
    failures.append('Locations no longer reaches the application query stack')
if 'NSTask' in region or 'Process(' in region or 'echoscu' in region:
    failures.append('Locations still launches a different DICOM stack')
# The node is Swift; the DIMSE calls are in its DCMTK adapter.
query = class_text('DCMTKQueryNode')
adapter = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.mm').read_text()
entry = query.split('class func verifyDICOMServer(', 1)[-1].split('// MARK: The association', 1)[0]
for required in ('UserDefaults.defaultAETitle()', 'extraParameters: server',
                 'setupNetwork(service: .verification'):
    if required not in entry: failures.append('verification lost shared configuration: ' + required)
setup = query.split('// MARK: The association', 1)[-1].split('func find(on association:', 1)[0]
for required in ('association.echo(withStatus: &status)', 'status != 0',
                 'parameters.dimseTimeout = self.association.dimseTimeout',
                 'parameters.connectionTimeout = defaults.integer(forKey: "DICOMConnectionTimeout")'):
    if required not in setup: failures.append('verification lost bounded failure handling: ' + required)
for required in ('DIMSE_echoUser', 'DIMSE_NONBLOCKING', '_dimseTimeout', 'ASC_createAssociationParameters',
                 'connectionTimeout > 0 ? connectionTimeout : parameters.acseTimeout'):
    if required not in adapter: failures.append('the adapter lost bounded failure handling: ' + required)
if 'detachNewThreadSelector(#selector(testThread(_:))' not in pane:
    failures.append('the Verify action no longer runs in a background thread')

# --- and the tool that tells the two apart records enough to tell them --------
if not reporter.exists():
    failures.append('the SCP that records who called is gone')
else:
    text = reporter.read_text()
    for needed in ('callingAETitle', 'calledAETitle', "'from'", 'implementationClassUID',
                   'maximumLength', 'abstractSyntax', 'accepted'):
        if needed not in text:
            failures.append('the recorder does not write down %s' % needed)
    if 'EVT_C_ECHO' not in text:
        failures.append('the recorder does not record a C-ECHO, so the two cannot be compared')
    if 'EVT_ABORTED' not in text:
        failures.append('an association that is aborted leaves no record, which is the case the '
                        'report is about')
    if 'keys' not in text:
        failures.append('the query keys are not recorded, so a filter cannot be checked')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: verification shares query configuration and the recorder compares wire identity')
