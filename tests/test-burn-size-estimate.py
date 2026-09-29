#!/usr/bin/env python3
"""The medium size estimate counts what goes on the medium, and nothing else (#632).

Links the BurnerWindowController.o and DefaultsOsiriX.o the application is
built from into tools/probe-burn-size-estimate.m and runs
-estimateFolderSize: over synthetic selections - small and large files, Unicode
names - with the launcher preference absent (the app's registered value),
true and false (a value persisted by an older version), Weasis on and off, and
a supplementary folder on, off, pointing nowhere and at a path longer than 300 bytes
(its size used to be read through a 300-byte buffer). The oracle is computed
from the files themselves with the estimate's own units: each file's size in
KiB rounded down, 17 MiB for Weasis, `du -sk` of the supplementary folder, the
sum shown in MB with two decimals.

No launcher is put on the medium, so no case may count one.

    python3 tests/test-burn-size-estimate.py                 # the built objects
    python3 tests/test-burn-size-estimate.py --revision REV  # the sources at REV

Against the revision before #632 the cases that count the launcher fail by
exactly 8 x 1024 KiB.

BurnerWindowController is Swift since #717. Its object, as the application
builds it, goes into a library with the HorosObjCException and HorosAlertPanel
objects it calls and stand-ins for the Swift classes of the module it names:
the anonymization classes, ThreadsManager (Swift since #716), DicomStudy
(Swift since #721) and AppController (Swift since #830). The estimate reaches
none of them, and a Swift symbol of the module that no stand-in provides is
named as a failure before the probe runs. The probe sets the same `files` and
`sizeField` of the Swift class. --revision still recompiles the Objective-C
source of a revision before #717.
"""
import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import object_probe  # noqa: E402
sys.path.insert(0, str(ROOT / "tests"))
from sources import is_swift  # noqa: E402

SOURCES = {"BurnerWindowController": "Horos/Sources/BurnerWindowController.m",
           "DefaultsOsiriX": "Horos/Sources/DefaultsOsiriX.m"}
# The Swift classes of module Horos that BurnerWindowController.swift calls
# directly, with the signatures it calls them by.
STAND_INS = """
import AppKit
@objc(BurnSizeProbeAnonymizationPanelController) public class AnonymizationPanelController: NSObject {
    @objc public var end: Int32 = 0
    @objc public var anonymizationViewController: AnonymizationViewController!
}
@objc(BurnSizeProbeAnonymizationViewController) public final class AnonymizationViewController: NSObject {
    public func tagsValues() -> [Any]! { return [] }
}
@objc(BurnSizeProbeAnonymization) public final class Anonymization: NSObject {
    @discardableResult public class func showPanel(forDefaultsKey defaultsKey: String?, modalFor window: NSWindow?, modalDelegate delegate: Any?,
                                                   didEnd sel: Selector?, representedObject: Any?) -> AnonymizationPanelController? { return nil }
    public class func anonymizeFiles(_ files: NSArray?, dicomImages: NSArray?, toPath dirPath: String?, withTags intags: NSArray?,
                                     error outError: NSErrorPointer) -> NSDictionary? { return nil }
}
@objc(BurnSizeProbeAnonymizationErrorPresenter) public final class AnonymizationErrorPresenter: NSObject {
    public static func present(error supplied: NSError?) {}
}
@objc(BurnSizeProbeThreadsManager) public final class ThreadsManager: NSObject {
    public class func `default`() -> ThreadsManager! { return nil }
    public func addThreadAndStart(_ thread: Thread!) {}
}
// AppController is Swift since #830; the Weasis branch asks it for the viewer's folder.
@objc(BurnSizeProbeAppController) public final class AppController: NSObject {
    public class func shared() -> AppController! { return nil }
    public func weasisBasePath() -> String! { return nil }
}
@objc(BurnSizeProbeDicomStudy) public final class DicomStudy: NSObject {
    @objc public dynamic class func displaySeries(withSOPClassUID uid: String!, andSeriesDescription description: String!) -> Bool {
        return true
    }
    public func saveReportAsPdfInTmp() -> String! { return nil }
}
"""


def undefined_module_symbols(image):
    """The Swift symbols of module Horos that `image` references and does not define."""
    listing = subprocess.run(["nm", "-u", str(image)], check=True, capture_output=True, text=True).stdout
    return {line.strip() for line in listing.splitlines() if line.strip().startswith("_$s5Horos")}
parser = argparse.ArgumentParser()
parser.add_argument("--revision")
parser.add_argument("--configuration", default="Debug")
arguments = parser.parse_args()

work = Path(tempfile.mkdtemp(prefix="horos-burn-estimate-"))
# Removed however the test ends, skips included (#803).
atexit.register(shutil.rmtree, work, ignore_errors=True)
objects = []
for name, source in SOURCES.items():
    if arguments.revision:
        try:
            command = object_probe.compile_command(source, arguments.configuration)
        except LookupError as error:
            print(f"needs a build log with the compile command: {error}", file=sys.stderr)
            raise SystemExit(2)
        copy = object_probe.revision_source(source, arguments.revision, work / "src" / Path(source).name)
        obj = work / f"{name}.o"
        object_probe.compile_source(command, copy, obj)
    else:
        obj = object_probe.app_object(name, arguments.configuration)
        if obj is None:
            print(f"needs a built {name}.o", file=sys.stderr)
            raise SystemExit(2)
    objects.append(obj)
support = object_probe.app_object("N2Debug", arguments.configuration)
if support is None:
    print("needs a built N2Debug.o", file=sys.stderr)
    raise SystemExit(2)
if is_swift("BurnerWindowController") and not arguments.revision:
    # The Swift object calls these; the Swift classes of the module it names
    # directly are stood in for under other Objective-C names.
    helpers = [object_probe.app_object(name, arguments.configuration) for name in ("HorosObjCException", "HorosAlertPanel")]
    if None in helpers:
        print("needs built HorosObjCException.o and HorosAlertPanel.o", file=sys.stderr)
        raise SystemExit(2)
    stand_ins = work / "stand_ins.swift"
    stand_ins.write_text(STAND_INS)
    bridging = work / "bridging.h"
    bridging.write_text("#import <Foundation/Foundation.h>\n")
    burner = object_probe.swift_dylib([stand_ins], [objects[0]] + helpers, work / "libBurnerWindowController.dylib",
                                      bridging_header=bridging,
                                      frameworks=("Cocoa", "DiscRecording", "DiscRecordingUI"))
    # A Swift class of the module the object came to name after these stand-ins
    # were written would stop the probe at load time with one dyld line; name them all.
    missing = undefined_module_symbols(burner)
    if missing:
        names = subprocess.run(["xcrun", "swift-demangle"], input="\n".join(sorted(missing)), capture_output=True,
                               text=True).stdout.splitlines()
        print("FAIL: BurnerWindowController.o needs Swift symbols of module Horos that no stand-in provides:")
        for name in names:
            print("  ", name)
        raise SystemExit(1)
    objects[0] = burner
probe = object_probe.link_probe(ROOT / "tools/probe-burn-size-estimate.m", objects + [support], work / "probe",
                                frameworks=("Cocoa", "DiscRecording", "DiscRecordingUI", "IOKit", "AVFoundation"))

# The selection: small, large and Unicode-named files.
selection = work / "selection"
selection.mkdir()
sizes = {"tiny.dcm": 300, "exactly-one-kib.dcm": 1024, "medium.dcm": 700_123, "large.dcm": 9_500_000,
         "estudo-coração-é.dcm": 2_048_001, "画像-日本語.dcm": 65_536}
files = []
for name, size in sizes.items():
    path = selection / name
    with open(path, "wb") as handle:
        handle.truncate(size)
        handle.seek(0)
        handle.write(b"DICM")
    files.append(str(path))
supplementary = work / "supplementary"
(supplementary / "sub").mkdir(parents=True)
(supplementary / "readme.txt").write_bytes(os.urandom(3000))
(supplementary / "sub" / "viewer.bin").write_bytes(os.urandom(1_200_000))
supplementary_kib = int(subprocess.run(["/usr/bin/du", "-sk", str(supplementary)], capture_output=True, text=True,
                                       check=True).stdout.split()[0])
# du's line for this one does not fit the 300 bytes the size used to be read through.
long_supplementary = work / "supplementary-long"
while len(str(long_supplementary).encode()) <= 400:
    long_supplementary = long_supplementary / "pasta suplementar com um nome bem comprido, ção"
long_supplementary.mkdir(parents=True)
(long_supplementary / "notes.bin").write_bytes(os.urandom(500_000))
long_kib = int(subprocess.run(["/usr/bin/du", "-sk", str(long_supplementary)], capture_output=True, text=True,
                              check=True).stdout.split()[0])

cases = []
for launcher in ("absent", True, False):
    for weasis in (False, True):
        for extra in ("off", "on", "missing", "long"):
            defaults = {"BurnWeasis": weasis}
            if launcher != "absent":
                defaults["BurnOsirixApplication"] = launcher
            if extra == "on":
                defaults.update(BurnSupplementaryFolder=True, SupplementaryBurnPath=str(supplementary))
            elif extra == "long":
                defaults.update(BurnSupplementaryFolder=True, SupplementaryBurnPath=str(long_supplementary))
            elif extra == "missing":
                defaults.update(BurnSupplementaryFolder=True, SupplementaryBurnPath=str(work / "nowhere"))
            else:
                defaults.update(BurnSupplementaryFolder=False)
            cases.append({"name": f"launcher={launcher} weasis={weasis} supplementary={extra}", "files": files,
                          "defaults": defaults, "weasis": weasis, "extra": extra})
cases.append({"name": "empty selection, launcher=True", "files": [], "defaults": {"BurnOsirixApplication": True},
              "weasis": False, "extra": "off"})
(work / "cases.json").write_text(json.dumps(cases))
run = subprocess.run([str(probe), str(work / "cases.json")], capture_output=True, text=True, timeout=120)
if run.returncode != 0:
    print(run.stdout[-2000:], run.stderr[-4000:])
    raise SystemExit(1)
results = {r["name"]: r for r in json.loads(run.stdout.strip().splitlines()[-1])}
print(f"objects under test: {', '.join(str(o) for o in objects)}")

failures = []
PATTERN = re.compile(r"No of files: (\d+)\s+Files size \(without compression\): ([\d.]+)MB")
for case in cases:
    text = results[case["name"]]["text"]
    match = PATTERN.search(text)
    if not match:
        failures.append(f"{case['name']}: unreadable estimate {text!r}")
        continue
    kib = sum(os.path.getsize(f) // 1024 for f in case["files"])
    if case["weasis"]:
        kib += 17 * 1024
    if case["extra"] == "on":
        kib += supplementary_kib
    elif case["extra"] == "long":
        kib += long_kib
    expected = f"{kib / 1024.0:3.2f}"
    count, shown = int(match.group(1)), match.group(2)
    if count != len(case["files"]) or shown != expected:
        shown_kib = float(shown) * 1024
        failures.append(f"{case['name']}: shows {count} files, {shown} MB; expected {len(case['files'])} files, "
                        f"{expected} MB (difference {shown_kib - kib:+.0f} KiB)")
for failure in failures:
    print("FAIL:", failure)
if failures:
    print(f"{len(failures)} failure(s)")
    raise SystemExit(1)
print(f"PASS: {len(cases)} selections (small, large and Unicode files; launcher preference absent, true and false; "
      "Weasis on and off; supplementary folder on, off, missing and at a path over 400 bytes) estimate exactly the "
      "files, Weasis and the "
      "supplementary folder, and never a launcher")
