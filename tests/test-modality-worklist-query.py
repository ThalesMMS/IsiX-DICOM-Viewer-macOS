#!/usr/bin/env python3
"""The Modality Worklist window's C-FIND, against a local worklist SCP.

tools/serve-worklist-fixture.py answers the Modality Worklist Information
Model - FIND (1.2.840.10008.5.1.4.31) on 127.0.0.1 with five synthetic
scheduled steps relative to today; nothing leaves the machine. A driver is
compiled with the pieces the window's query runs through:
- IsiXDICOMNetwork, which makes the identifier's keys for the days, modality
  and station asked for (ModalityWorklistQuery), reads the answers into
  ScheduledProcedure values, merges them in start order, and matches them with
  received studies (ModalityWorklistMatching);
- Horos/Sources/CFindKeysCoding.swift, the app's writing of those keys into a
  DCMTK identifier, the scheduled step's keys in the first item of the
  Scheduled Procedure Step Sequence, and its reading of the matches;
- the DCMTK adapter of the query nodes (IsiXDCMTKQueryRetrieveSCU.mm and the
  dataset and error files), whose C-FIND takes the information model to ask in,
  compiled against the DCMTK and OpenSSL of the Debug build.

The driver asks for today, today's CT, one station, the next seven days and
any date, and checks the steps, their order, a name outside ASCII answered in
ISO_IR 192, and the marks of steps whose studies have arrived by Study Instance
UID, Accession Number and Patient ID on the scheduled day. A node that is asked
in the Study Root model finds no presentation context, since the fixture only
offers the worklist. The fixture's record of the identifiers is then read: each
was a Modality Worklist C-FIND with no Query/Retrieve Level and with the date,
modality and station in the item of the sequence.

Skipped (exit 2) without a Python that has pynetdicom (local-validation's
dicom-venv or fixture-venv, or HOROS_TEST_PYTHON), or without the DCMTK and
OpenSSL archives of a Debug build. The C-MOVE and C-GET loops of the adapter
are stubbed, as in test-dcmtk-query-retrieve-adapter.py.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT, dcmtk_flags
from isix_modules import module_flags


def fixture_python():
    """A Python with pydicom and pynetdicom, or None."""
    from python_with import interpreter
    candidates = [os.environ.get('HOROS_TEST_PYTHON'), interpreter('import pydicom', 'import pynetdicom')]
    candidates += [str(ROOT / 'local-validation' / name / 'bin/python') for name in ('work/dicom-venv', 'fixture-venv')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and subprocess.run(
                [candidate, '-c', 'import pydicom, pynetdicom'], capture_output=True).returncode == 0:
            return candidate
    return None


python = fixture_python()
if not python:
    print('skipped: needs a Python with pydicom and pynetdicom for tools/serve-worklist-fixture.py, such as '
          'local-validation/work/dicom-venv, or HOROS_TEST_PYTHON')
    raise SystemExit(2)
library = BUILD / 'OpenSSL.build/Install/lib'
openssl = [library / 'libssl.a', library / 'libcrypto.a']
if not all(path.is_file() for path in openssl):
    print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(openssl[0]))
    raise SystemExit(2)
dcmtk = dcmtk_flags('dcmnet', 'dcmtls')
dcmtk_includes = [flag for flag in dcmtk if flag.startswith('-I')]
dcmtk_links = [flag for flag in dcmtk if not flag.startswith('-I')]

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SOURCES = [ADAPTERS / name for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKDataset.mm', 'IsiXDCMTKQueryRetrieveSCU.mm')]
TARGET = ['-target', 'arm64-apple-macos15.0']

STUBS = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKQueryRetrieveSCU.h"
#include "IsiXDCMTKRetrieveLoops.hpp"

extern "C" BOOL HorosDIMSEAssociationPDUIsValid(const unsigned char *, ptrdiff_t) noexcept { return YES; }
OFCondition HorosDIMSEGetUser(T_ASC_Association*, T_ASC_PresentationContextID, T_DIMSE_C_GetRQ*, DcmDataset*,
    DIMSE_GetUserCallback, void*, T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_GetRSP*, DcmDataset**, DcmDataset**, IsiXDCMTKIncomingCallback, void*, id<IsiXDCMTKSCPDatabase>) { return EC_IllegalCall; }
OFCondition HorosDIMSEMoveUser(T_ASC_Association*, T_ASC_PresentationContextID, T_DIMSE_C_MoveRQ*, DcmDataset*,
    DIMSE_MoveUserCallback, void*, T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_MoveRSP*, DcmDataset**, DcmDataset**, OFBool) { return EC_IllegalCall; }
'''

BRIDGE = '''
#import "IsiXDCMTKError.h"
#import "IsiXDCMTKDataset.h"
#import "IsiXDCMTKQueryRetrieveSCU.h"
'''

DRIVER = r'''
import Foundation
import IsiXDICOMNetwork

struct Fixture: Decodable {
    struct Step: Decodable {
        let PatientID: String
        let AccessionNumber: String
        let StudyInstanceUID: String
        let StepID: String
    }
    let today: String
    let steps: [Step]
}

var failures = 0

@MainActor func check(_ condition: Bool, _ what: String) {
    print("\(condition ? "PASS" : "FAIL"): \(what)")
    if !condition { failures += 1 }
}

let port = Int32(CommandLine.arguments[1]) ?? 0
let calledAETitle = CommandLine.arguments[2]
let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))

/// One C-FIND as the window sends it: the module's keys, the app's identifier
/// coding and the adapter's association, then the answers as the window reads them.
@MainActor func ask(_ filter: ModalityWorklistQuery.Filter,
                    model: String = ModalityWorklistQuery.abstractSyntax) -> (steps: [ScheduledProcedure], failure: String?) {
    let keys: [PluginQueryKeys.Key]
    let identifier: IsiXDCMTKDataset
    do {
        keys = try ModalityWorklistQuery.keys(for: filter)
        identifier = try CFindKeysCoding.identifier(for: keys)
    } catch {
        return ([], "the identifier: \(error)")
    }
    let parameters = IsiXDCMTKAssociationParameters()
    parameters.callingAETitle = "MWLTEST"
    parameters.calledAETitle = calledAETitle
    parameters.peerHost = "127.0.0.1"
    parameters.peerPort = port
    parameters.abstractSyntax = model
    parameters.acseTimeout = 10
    parameters.dimseTimeout = 10
    let association: IsiXDCMTKAssociation
    do {
        association = try IsiXDCMTKAssociation(parameters: parameters)
    } catch {
        return ([], "the association parameters: \(error)")
    }
    defer { _ = association.invalidate() }
    if let failure = association.request() { return ([], "the association: \(failure.localizedDescription)") }
    guard association.acceptsAbstractSyntax(model) else {
        _ = association.releaseAssociation()
        return ([], "no presentation context")
    }
    var matches: [IsiXDCMTKDataset] = []
    let result = association.find(withIdentifier: identifier, abstractSyntax: model) { matches.append($0) }
    _ = association.releaseAssociation()
    if let failure = result.condition { return ([], "the C-FIND: \(failure.localizedDescription)") }
    guard result.status == 0 else { return ([], "the C-FIND ended with \(result.statusText)") }
    let steps = matches.map { match in
        let encoding: String.Encoding = CFindKeysCoding.characterSet(of: match) == "ISO_IR 192" ? .utf8 : .isoLatin1
        return ScheduledProcedure(values: CFindKeysCoding.values(of: match, keys: keys, encoding: encoding), node: "Fixture")
    }
    return (ScheduledProcedure.merged([steps]), nil)
}

let today = ask(.init(dateWindow: .today))
check(today.failure == nil, "today's steps are asked for (\(today.failure ?? "answered"))")
check(today.steps.map(\.stepID) == ["SPS1", "SPS2", "SPS3"], "today's three steps, in start order: \(today.steps.map(\.stepID))")
if let first = today.steps.first, let step = fixture.steps.first {
    check(first.displayPatientName == "MWL ALPHA" && first.patientID == step.PatientID, "the patient is read")
    check(first.accessionNumber == step.AccessionNumber && first.studyInstanceUID == step.StudyInstanceUID,
          "the Accession Number and the Study Instance UID are read")
    check(first.modality == "CT" && first.stationAETitle == "CT1" && first.stationName == "CT ROOM 1",
          "the step's modality and station come from the item of the sequence")
    check(first.procedureDescription == "CT HEAD STEP" && first.requestedProcedureDescription == "CT HEAD",
          "the step's description, and the requested procedure's")
    check(first.startDate == fixture.today && first.scheduledStart().map { Calendar.current.component(.hour, from: $0) } == 8,
          "the scheduled start is today at 08:00")
}
check(today.steps.last?.displayPatientName == "MWL JOÃO", "a name outside ASCII is read in ISO_IR 192: \(today.steps.last?.patientName ?? "")")

let computedTomography = ask(.init(dateWindow: .today, modality: "CT"))
check(computedTomography.steps.map(\.stepID) == ["SPS1", "SPS3"], "today's CT steps: \(computedTomography.steps.map(\.stepID))")
let station = ask(.init(dateWindow: .today, stationAETitle: "MR1"))
check(station.steps.map(\.stepID) == ["SPS2"], "the steps of one station: \(station.steps.map(\.stepID))")
let week = ask(.init(dateWindow: .nextSevenDays))
check(week.steps.map(\.stepID) == ["SPS1", "SPS2", "SPS3", "SPS4"], "the next seven days: \(week.steps.map(\.stepID))")
let all = ask(.init(dateWindow: .anyDate))
check(all.steps.count == 5 && all.steps.last?.stepID == "SPS5", "any date: \(all.steps.map(\.stepID))")
let studyRoot = ask(.init(dateWindow: .today), model: QueryRetrieveService.findStudyRoot.rawValue)
check(studyRoot.failure == "no presentation context", "a worklist SCP does not answer the Study Root model: \(studyRoot.failure ?? "answered")")

// The studies of the database, as the window reads them: one with the Study
// Instance UID of SPS2 under another Accession Number, one with the Accession
// Number of SPS1, and one of SPS3's patient made today.
let steps = Dictionary(uniqueKeysWithValues: fixture.steps.map { ($0.StepID, $0) })
let now = Date()
let received = [
    ReceivedStudy(studyInstanceUID: steps["SPS2"]?.StudyInstanceUID, accessionNumber: "ELSEWHERE", patientID: "OTHER", date: now),
    ReceivedStudy(studyInstanceUID: "2.25.1", accessionNumber: steps["SPS1"]?.AccessionNumber, patientID: steps["SPS1"]?.PatientID,
                  date: now.addingTimeInterval(-86_400 * 3)),
    ReceivedStudy(studyInstanceUID: "2.25.2", accessionNumber: "", patientID: steps["SPS3"]?.PatientID, date: now),
    ReceivedStudy(studyInstanceUID: "2.25.3", accessionNumber: "", patientID: steps["SPS4"]?.PatientID,
                  date: now.addingTimeInterval(-86_400 * 30)),
]
let marks = Dictionary(uniqueKeysWithValues: all.steps.map { ($0.stepID, ModalityWorklistMatching.match($0, among: received)) })
check(marks["SPS1"] == .accessionNumber, "SPS1 has arrived by its Accession Number")
check(marks["SPS2"] == .studyInstanceUID, "SPS2 has arrived by its Study Instance UID")
check(marks["SPS3"] == .patientIDOnScheduledDay, "SPS3 has arrived by its Patient ID on the scheduled day")
check(marks["SPS4"] == .some(nil) && marks["SPS5"] == .some(nil), "SPS4 and SPS5 have not arrived")
exit(failures == 0 ? 0 : 1)
'''


def run(command, **options):
    done = subprocess.run(command, capture_output=True, text=True, **options)
    if done.returncode:
        print(done.stdout[-3000:] + done.stderr[-4000:])
        print('FAIL: ' + ' '.join(map(str, command[:3])) + ' ... did not compile')
        sys.exit(1)
    return done


failures = []
with tempfile.TemporaryDirectory(prefix='isix-worklist-') as temporary:
    folder = Path(temporary)
    modules = module_flags('IsiXDICOMNetwork', folder / 'modules', TARGET)
    objects = []
    (folder / 'stubs.mm').write_text(STUBS)
    for source in [*SOURCES, folder / 'stubs.mm']:
        target = folder / (source.stem + '.o')
        run(['xcrun', 'clang++', '-c', '-std=gnu++17', '-fobjc-arc', '-mmacosx-version-min=15.0', '-Wall', '-Werror',
             '-Wno-unused-parameter', '-I' + str(ADAPTERS), *dcmtk_includes, str(source), '-o', str(target)])
        objects.append(target)
    (folder / 'bridge.h').write_text(BRIDGE)
    (folder / 'main.swift').write_text(DRIVER)
    run(['xcrun', 'swiftc', '-swift-version', '6', *TARGET, '-module-name', 'WorklistDriver',
         '-import-objc-header', str(folder / 'bridge.h'), '-Xcc', '-I' + str(ADAPTERS), *modules,
         str(ROOT / 'Horos/Sources/CFindKeysCoding.swift'), str(folder / 'main.swift'), *map(str, objects),
         *dcmtk_links, *map(str, openssl), '-lc++', '-framework', 'Foundation', '-o', str(folder / 'check')])

    evidence = folder / 'evidence'
    server = subprocess.Popen([python, str(ROOT / 'tools/serve-worklist-fixture.py'), str(evidence), '--port', '0'],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        line = server.stdout.readline()
        if 'listening on port' not in line:
            server.kill()
            print(line + server.stderr.read()[-3000:])
            print('FAIL: the worklist fixture did not start')
            sys.exit(1)
        port = line.split()[-1]
        try:
            driven = subprocess.run([str(folder / 'check'), port, 'MWLFIX', str(evidence / 'worklist-steps.json')],
                                    capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            print('FAIL: the driver did not end within 120 s')
            sys.exit(1)
        print(''.join(line for line in driven.stdout.splitlines(keepends=True) if line.startswith(('PASS', 'FAIL'))), end='')
        if driven.returncode:
            print(driven.stderr[-3000:])
            failures.append('the driver failed (exit %d)' % driven.returncode)
        for _ in range(50):
            if (evidence / 'worklist-queries.json').is_file():
                break
            time.sleep(0.1)
        record = json.loads((evidence / 'worklist-queries.json').read_text())
    finally:
        server.terminate()
        try:
            server.wait(10)
        except subprocess.TimeoutExpired:
            server.kill()


def check(condition, what):
    print('%s: %s' % ('PASS' if condition else 'FAIL', what))
    if not condition:
        failures.append(what)


queries = record['queries']
check(len(queries) == 5, 'the fixture answered five worklist queries (%d)' % len(queries))
check(all(query['model'] == '1.2.840.10008.5.1.4.31' for query in queries), 'each was a Modality Worklist C-FIND')
check(all('QueryRetrieveLevel' not in query['elements'] for query in queries), 'with no Query/Retrieve Level')


def item(query):
    sequence = query['elements'].get('ScheduledProcedureStepSequence') or [[{}]]
    return sequence[0][0] if sequence[0] else {}


if queries:
    first = queries[0]
    check(item(first).get('ScheduledProcedureStepStartDate') == [record['today']], "today's date is in the item of the sequence")
    check(all(first['elements'].get(key) == [] for key in ('PatientName', 'PatientID', 'AccessionNumber', 'StudyInstanceUID')),
          'the patient and order keys are asked for empty')
    check({'ScheduledStationAETitle', 'ScheduledStationName', 'ScheduledProcedureStepID', 'Modality'} <= set(item(first)),
          'the step keys are asked for in the item')
if len(queries) > 2:
    check(item(queries[1]).get('Modality') == ['CT'], 'the modality filter is in the item')
    check(item(queries[2]).get('ScheduledStationAETitle') == ['MR1'], 'the station filter is in the item')
if len(queries) > 4:
    check('-' in (item(queries[3]).get('ScheduledProcedureStepStartDate') or [''])[0], 'seven days are a date range')
    check(item(queries[4]).get('ScheduledProcedureStepStartDate') == [], 'any date asks for the date empty')

if failures:
    print('FAIL: %d check(s) of the Modality Worklist query failed' % len(failures))
    sys.exit(1)
print('PASS: the Modality Worklist C-FIND of the window reads the scheduled steps of a local worklist SCP and marks those received')
