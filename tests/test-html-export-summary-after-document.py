#!/usr/bin/env python3
"""The HTML export writes its summary pages when any series was written.

A document series is written as a PDF and leaves no images behind, so a
condition on the images still held skipped the pages whenever the export
ended with a document. The export of a selection keeps whether a series was
written, sets it for every kind of series, and asks that for the summary."""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

text = sources.source_text('SelectionMovieExport')
failures = []
start = text.find('func writePreviousSeries(')
if start < 0:
    failures.append('the function that writes the previous series is gone')
else:
    body = text[start:text.index('\n        }\n', start)]
    first = body.split('\n')[1].strip()
    if first != 'if !imagesArray.isEmpty { seriesWritten = true }':
        failures.append(f'the series is not recorded as written before its images are consumed: {first}')
conditions = re.findall(r'if createHTML && ([^{]+)\{\s*\n\s*let htmlExport = QTExportHTMLSummary\(\)', text)
if conditions != ['seriesWritten ']:
    failures.append(f'the summary is made on {conditions}, not on whether a series was written')
if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('PASS: the HTML summary is written when any series was, a document last included')
