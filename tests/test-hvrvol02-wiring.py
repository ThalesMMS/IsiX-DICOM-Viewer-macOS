#!/usr/bin/env python3
"""HVRVOL02 stays a host exporter: not DICOM, not DICOMweb, not a copied team."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
failures = []


def text(relative):
    return (root / relative).read_bytes().decode('latin1')


def require(condition, message):
    if not condition:
        failures.append(message)


source = text('Horos/Sources/HorosHVRVOL02.swift')
project = text('Horos.xcodeproj/project.pbxproj')
# BrowserController (SourcesCopy) is Swift.
copy = source_text('BrowserController+Sources+Copy')
config = text('Config.xcconfig')
browser = text('Horos/Sources/BrowserController.m')

require('HorosHVRVOL02.swift' in project, 'the exporter is not in the application target')
require('HVRVOL02' in source, 'the exporter does not name the HVRVOL02 contract')
require('_horosiphone._tcp' in source, 'Bonjour discovery type is missing')
require('explicitlyAuthorized' in source, 'authorization is not distinct from discovery')
require('DICOM_LPS_mm' in source and 'float32' in source, 'patient-space float32 contract is missing')

require('copyImagesToRemoteBrowserSourceThread' in copy,
        'remote database copy was removed to make room for the phone exporter')
require('SendController.h' in browser,
        'DICOM SendController is no longer imported by the browser')
web = text('Horos/Sources/DICOMwebClient.swift')
require('QIDO' in web and 'WADO' in web, 'DICOMweb client lost QIDO/WADO')

require('TPT6TVH8UY' not in config, 'the donor DEVELOPMENT_TEAM was copied into Config.xcconfig')
require('HOROS_DEVELOPMENT_TEAM' in config, 'local signing override was dropped')

if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    sys.exit(1)
print('PASS: HVRVOL02 wiring preserves DICOM, DICOMweb and local signing')
