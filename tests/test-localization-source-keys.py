#!/usr/bin/env python3
"""Every host NSLocalizedString key must exist in all supported host catalogs."""
from collections import Counter
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
tool = root / "tools/collect-localized-strings.py"
parser = argparse.ArgumentParser()
parser.add_argument("--language", action="append")
arguments = parser.parse_args()
command = [sys.executable, str(tool), "--check"]
for language in arguments.language or []:
    command += ["--language", language]
subprocess.run(command, check=True)

# Japanese remains an existing catalog: check its complete live source/menu
# coverage and argument bindings without requiring an unrelated UI rewrite.
for name in ("collect-localized-strings.py", "collect-menu-strings.py"):
    subprocess.run([sys.executable, str(root / "tools" / name),
                    "--check", "--language", "ja-JP"], check=True)
spec = importlib.util.spec_from_file_location("collector", tool)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
path = root / "Horos/Resources/ja-JP.lproj/Localizable.strings"
japanese = collector.catalog("ja-JP")
source = path.read_text(encoding="utf-16")
literals = re.findall(r'^\s*("(?:\\.|[^"\\])*")\s*=', source, re.M)
assert len(literals) == len(set(json.loads(x) for x in literals)), "Duplicate Japanese keys"

# Historical entries use numbered arguments and occasionally omit minimum
# display widths. Verify each argument index and C conversion type, allowing
# those existing presentation choices while detecting unsafe format changes.
format_pattern = re.compile(
    r"%(?:(\d+)\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(hh|ll|[hljztLq])?([@diuoxXfFeEgGaAcCsSpn%])")

def bindings(value):
    result = []
    sequential = 0
    for match in format_pattern.finditer(value):
        position, length, conversion = match.groups()
        if conversion == "%":
            result.append((0, "", "%"))
            continue
        sequential += 1
        result.append((int(position) if position else sequential, length or "", conversion))
    return Counter(result)

for key in collector.keys():
    value = japanese[key]
    assert value and "\ufffd" not in value, f"Invalid Japanese value: {key!r}"
    assert bindings(key) == bindings(value), f"Changed Japanese argument binding: {key!r}"
    assert all(key.count(c) == value.count(c) for c in "\r\n\t"), f"Changed Japanese control escapes: {key!r}"
assert japanese["DICOMweb Query Failed"] == "DICOMwebクエリに失敗"
assert japanese["Export ROIs as JSON..."] == "ROIをJSONとして書き出し..."
assert japanese["Choose database folder"] == "データベースフォルダを選択"
print(f"PASS: {len(japanese)} Japanese entries; complete live source/menu coverage, unique keys, argument bindings and control escapes")
print("PASS: host source keys are present in the selected supported host catalogs" if arguments.language else
      "PASS: host source keys are present in all supported host catalogs")
