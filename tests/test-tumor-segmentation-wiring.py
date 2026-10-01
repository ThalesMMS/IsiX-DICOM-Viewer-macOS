#!/usr/bin/env python3
"""Tumour-segmentation job contract is compiled into the app target."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
source = root / 'Horos/Sources/TumorSegmentationJob.swift'
helper = root / 'tools/metal3d_tumor_segmentation_mock.py'

if 'TumorSegmentationJob.swift' not in pbx:
    print('FAIL: TumorSegmentationJob.swift is not in the app target')
    sys.exit(1)
if 'TumorSegmentationJob.swift in Sources' not in pbx:
    print('FAIL: TumorSegmentationJob.swift is not in a Sources build phase')
    sys.exit(1)
if not source.is_file():
    print('FAIL: Horos/Sources/TumorSegmentationJob.swift is missing')
    sys.exit(1)
text = source.read_text(encoding='utf-8')
if 'helper --job' not in text and '["--job"' not in text:
    print('FAIL: the job type no longer launches with --job')
    sys.exit(1)
if 'shape-resize' not in source.read_text(encoding='utf-8') and 'resize' not in text:
    print('FAIL: resize fallback is no longer refused as registration')
    sys.exit(1)
if not helper.is_file():
    print('FAIL: mock helper is missing')
    sys.exit(1)
mock = helper.read_text(encoding='utf-8')
if '--job' not in mock or 'mock-threshold' not in mock:
    print('FAIL: mock helper is not the --job smoke backend')
    sys.exit(1)
if 'adapted from' in mock.lower() and 'NOTICE' not in mock:
    print('FAIL: mock helper says it was adapted but does not point at NOTICE for its provenance')
    sys.exit(1)
print('PASS: tumour-segmentation job is in the app target with a versioned mock helper')
