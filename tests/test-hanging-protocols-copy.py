#!/usr/bin/env python3
"""The Protocols pane edits a native copy of HANGINGPROTOCOLS and keeps nothing behind (#618).

tools/probe-hanging-protocols.m loads the pane and drives willSelect/willUnselect
with preferences held in memory - no preferences domain is read or written. The
pane is Swift since #711: OSIHangingPreferencePanePref.swift is compiled into a
library the probe loads, against the application's own AppController.h (the
probe stubs the class; AppController is Swift since #830, and the header's
former interface declares it here). WindowLayoutManager is Swift since #714: its source is
compiled into the same library, with HorosObjCException, and the pane calls it
(the probe's stub of the class is not what the pane reaches):

- a stored value: the copy is not the stored object, every nested dictionary and
  array is mutable, what the pane edits does not reach the stored value until it
  is saved, the value saved is the edited copy, dates, data and numbers keep
  their types;
- only the registered value: the same;
- a stored string or array (a damaged preference): no exception, and the stored
  value is left exactly as it was;
- nothing stored or registered: an empty dictionary to edit, no exception;
- 500 visits to one pane with 400 protocols: less than 1 KiB retained per visit.

Before #618 the damaged values raised (`-deepMutableCopy` sent to a string,
`-objectForKey:` to an array) and each visit leaked its deep copy; the numbers are
in the separate integration validation (#618).

No build products are needed.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tools"))
sys.path.insert(0, str(root / "tests"))
import object_probe  # noqa: E402
from sources import source_path  # noqa: E402

failures = []
with tempfile.TemporaryDirectory(prefix="horos-hanging-protocols-") as temporary:
    bridging = Path(temporary) / "bridging.h"
    # As the app's bridging header: WindowLayoutManager.h only names the class
    # that WindowLayoutManager.swift declares. AppController is Swift since #830:
    # under HOROS_BRIDGING_HEADER its header only names the class, which the app
    # compiles into the same module as the pane and this library does not. It is
    # imported first, without HOROS_BRIDGING_HEADER and without a Horos-Swift.h,
    # so that it declares the class with its former interface (the branch the
    # Decompress helper reads) - the selectors AppController.swift keeps - and
    # the probe's stub is what the pane reaches.
    bridging.write_text('#import <Cocoa/Cocoa.h>\n#import "AppController.h"\n#define HOROS_BRIDGING_HEADER 1\n'
                        '#import "WindowLayoutManager.h"\n#import "HorosObjCException.h"\n#import "N2Debug.h"\n')
    # WindowLayoutManager logs through N2LogException, which the pane's calls never reach.
    log_stub = Path(temporary) / "log_stub.m"
    log_stub.write_text('#import <Foundation/Foundation.h>\n'
                        'void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) {}\n')
    objects = []
    for source in (root / "Horos/Sources/HorosObjCException.m", log_stub):
        objects.append(Path(temporary) / (source.stem + ".o"))
        subprocess.run(["xcrun", "clang", "-c", "-fno-objc-arc", "-arch", "arm64", "-mmacosx-version-min=26.0",
                        "-I", str(root / "Horos/Sources"), str(source), "-o", str(objects[-1])], check=True)
    try:
        pane = object_probe.swift_dylib([source_path("OSIHangingPreferencePanePref"), source_path("WindowLayoutManager"),
                                         # The pane's main-actor callbacks (#961).
                                         source_path("MainActorCallbacks")], objects,
                                        Path(temporary) / "libHangingPane.dylib", bridging_header=bridging,
                                        include_dirs=(root / "Horos/Sources", root / "Nitrogen/Sources"),
                                        frameworks=("Cocoa", "PreferencePanes"))
    except subprocess.CalledProcessError as error:
        print(f"the pane does not compile: {error}")
        raise SystemExit(1)
    probe = Path(temporary) / "probe"
    built = subprocess.run(["xcrun", "clang", "-fno-objc-arc", "-arch", "arm64", "-mmacosx-version-min=26.0",
                            "-framework", "Cocoa", "-framework", "PreferencePanes",
                            str(root / "tools/probe-hanging-protocols.m"),
                            "-Wl,-undefined,dynamic_lookup", "-Wl,-export_dynamic", "-o", str(probe)],
                           capture_output=True, text=True)
    if built.returncode != 0:
        print(built.stderr[-2000:])
        raise SystemExit(1)
    # A selector is not an undefined symbol, and strings(1) does not list the method
    # names of an object file: look for the bytes.
    if b"deepMutableCopy\0" in pane.read_bytes():
        failures.append("the pane still sends -deepMutableCopy")
    run = subprocess.run([str(probe), "check", str(pane)], capture_output=True, text=True, timeout=120)
    if run.returncode != 0:
        print(run.stderr[-2000:])
        raise SystemExit(1)
    result = json.loads(run.stdout.strip().splitlines()[-1])

cases = {case["case"]: case for case in result["cases"]}
for name in ("stored", "registered only"):
    case = cases[name]
    if case.get("exception"):
        failures.append(f"{name}: {case['exception']}")
        continue
    for key, wanted in (("copy_is_stored_object", False), ("mutable_throughout", True), ("stored_untouched_before_save", True),
                        ("wrote", True), ("stored_after_equals_copy", True)):
        if bool(case.get(key)) != wanted:
            failures.append(f"{name}: {key} is {case.get(key)} (immutable at {case.get('immutable_paths')})")
    types = case.get("first_protocol_types", {})
    if "Date" not in types.get("Created", "") or "Data" not in types.get("Blob", "") or types.get("Comparative") != "0.5":
        failures.append(f"{name}: the saved protocol lost its types: {types}")
for name in ("stored string", "stored array"):
    case = cases[name]
    if case.get("exception"):
        failures.append(f"{name}: {case['exception']}")
    if not case.get("stored_after_equals_before"):
        failures.append(f"{name}: the damaged value was overwritten")
case = cases["nothing"]
if case.get("exception") or not case.get("mutable_throughout"):
    failures.append(f"nothing stored: {case}")
if result["retained_bytes_per_visit"] > 1024:
    failures.append(f"{result['retained_bytes_per_visit']:.0f} bytes retained per visit")

for failure in failures:
    print("FAIL:", failure)
if failures:
    raise SystemExit(1)
print(f"ok: the pane copies natively, isolates and keeps its edits typed, leaves damaged values alone, "
      f"and retains {result['retained_bytes_per_visit']:.0f} bytes per visit")
