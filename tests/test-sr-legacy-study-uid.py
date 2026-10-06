#!/usr/bin/env python3
"""A report or annotation SR keeps the study's UID, even a legacy one.

Older scanners write StudyInstanceUIDs with a component that has a leading
zero, such as 1.2.076.4951.999.1. DCMTK's strict check refuses it, and
SRAnnotation ignored the refusal: the SR got a generated study UID and was
indexed as another study. The study stayed without its SR, so every report
synchronization archived again into a new file, and each of those became one
more study with one more copy of the report.

Compiles the production HorosStructuredReportBridge.cpp against the project's
DCMTK and checks that a canonical and a legacy UID come out identical after
creating, writing and reading an SR, that malformed values are refused, and
that SRAnnotation does not write an SR whose study UID is missing or refused.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
from dcmtk_build import ROOT, dcmtk_flags

failures = []

annotation = (ROOT / 'Horos/Sources/SRAnnotation.mm').read_text(encoding='utf-8', errors='replace')
write = annotation[annotation.find('- (BOOL)writeToFileAtPath:'):]
create = write.find('createNewSeriesInStudy(')
if create < 0 or 'return NO;' not in write[create:create + 400] or 'studyUID.length == 0' not in write[:create]:
    failures.append('SRAnnotation writes the SR even when the study UID is missing or refused')

code = r'''
#include "HorosStructuredReportBridge.h"
#include <dcmtk/dcmdata/dctk.h>
#include <cstdio>
#include <cstring>
#include <string>

static int failures = 0;
static void fail(const std::string& message) { printf("FAIL: %s\n", message.c_str()); ++failures; }

// Creates, writes and reads back an SR in the given study; returns its study UID.
static std::string roundTrip(const OFString& uid, OFCondition& created) {
    HorosSRDocument report(DSRTypes::DT_ComprehensiveSR);
    report.setPatientsName("SYNTHETIC^UID");
    report.setPatientID("LOCALUID");
    created = report.createNewSeriesInStudy(uid);
    if (created.bad()) return "";
    auto tree = report.getTree();
    if (!tree.addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container)) return "";
    tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("18748-4", "LN", "Diagnostic imaging study"));
    if (!tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent)) return "";
    tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("121106", "DCM", "Comment"));
    tree.getCurrentContentItem().setStringValue("Synthetic report");
    DcmFileFormat file;
    if (report.write(*file.getDataset()).bad()) return "";
    if (file.saveFile("report.dcm", EXS_LittleEndianExplicit).bad()) return "";
    DcmFileFormat loaded;
    if (loaded.loadFile("report.dcm").bad()) return "";
    HorosSRDocument decoded;
    if (decoded.read(*loaded.getDataset()).bad()) return "";
    const char* study = decoded.getStudyInstanceUID();
    return study ? study : "";
}

int main(int argc, char** argv) {
    if (argc != 2 || chdir(argv[1]) != 0) return 2;
    const char* accepted[] = {"1.2.826.0.1.3680043.8.498.1", "1.2.076.4951.999.1", "1.2.0.3"};
    for (const char* uid : accepted) {
        for (int cycle = 0; cycle < 20; ++cycle) {
            OFCondition created;
            std::string written = roundTrip(uid, created);
            if (created.bad()) { fail(std::string(uid) + " refused: " + created.text()); break; }
            if (written != uid) { fail(std::string(uid) + " written as '" + written + "'"); break; }
        }
    }
    const OFString refused[] = {"", "1..2", ".1.2", "1.2.", "1.2.a", "1.2\\1.3", "1.2 3",
                                OFString(65, '1'), OFString("1.2\0.3", 6)};
    for (const OFString& uid : refused) {
        HorosSRDocument report(DSRTypes::DT_ComprehensiveSR);
        if (report.createNewSeriesInStudy(uid).good())
            fail("'" + std::string(uid.c_str()) + "' (" + std::to_string(uid.size()) + " bytes) accepted");
    }
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-sr-legacy-uid-') as directory:
    work = Path(directory)
    (work / 'main.cc').write_text(code)
    built = subprocess.run(['xcrun', 'clang++', '-std=c++17', str(work / 'main.cc'),
                            str(ROOT / 'Horos/Sources/HorosStructuredReportBridge.cpp'),
                            *dcmtk_flags('dcmsr', 'dcmjpeg', 'dcmimage', 'dcmimgle', 'ijg8', 'ijg12', 'ijg16'),
                            '-lxml2', '-o', str(work / 'check')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the driver does not build:\n' + built.stderr[-3000:])
    else:
        run = subprocess.run([str(work / 'check'), str(work)], capture_output=True, text=True)
        failures += [line[len('FAIL: '):] for line in run.stdout.splitlines() if line.startswith('FAIL: ')]
        if run.returncode != 0 and not run.stdout.strip():
            failures.append('the driver failed:\n' + run.stderr[-3000:])

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: canonical and legacy study UIDs survive the SR round trip; malformed ones are refused')
