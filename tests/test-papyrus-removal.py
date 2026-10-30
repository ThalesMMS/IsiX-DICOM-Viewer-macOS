#!/usr/bin/env python3
"""What the Papyrus removal took out stays out, and what it had to keep is kept.

An inventory guard, read from the sources and the project; the compiled
behaviour (images read, cache, locks under concurrency) is validated in the
app.

Removed: the Papyrus3 toolkit folder and any project or include reference to it;
the always-NO `gUSEPAPYRUSDCMPIX` flag, its branch and the fallback that re-read
a whole file to call a reader that always failed; the group cache nothing
filled (`cachedPapyGroups`, `-clearCachedPapyGroups`); the unused
`PapyrusLockFunction`; the `USEPAPYRUSDCMPIX4` default; extern declarations of
the lock in files that never take it.

Kept: the `PapyrusLock` global, allocated at launch and still taken around the
parsed-file cache, the annotations and the DCMTK reads in DicomFile; the store
listener locks; the photometric interpretation codes of the YBR conversion;
`-loadDICOMPapyrus` and `-releaseParsedFile` (formerly `-clearCachedDCMFrameworkFiles`) in the SDK header;
`TOOLKITPARSER4`, whose presence DicomFile reads; the annotations method named
`loadCustomImageAnnotationsPapyLink:DCMLink:`.

    python3 tests/test-papyrus-removal.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from sources import class_text, source_path  # noqa: E402
failures = []


def text(path):
    return (ROOT / path).read_bytes().decode("latin-1")


def check(condition, message):
    if not condition:
        failures.append(message)


# Removed.
check(not (ROOT / "Papyrus3").exists(), "the Papyrus3 folder is still there")
for project in ("Horos.xcodeproj/project.pbxproj",):
    check(not re.search(r"Papyrus3|PapyrusLockFunction", text(project)), f"{project} still names Papyrus3")
sources = [p for p in (ROOT / "Horos/Sources").rglob("*") if p.suffix in {".h", ".m", ".mm", ".c", ".swift"}]
for path in sources:
    body = path.read_bytes().decode("latin-1")
    rel = path.relative_to(ROOT)
    check('"Papyrus3/' not in body, f"{rel} still includes a Papyrus3 header")
    check("gUSEPAPYRUSDCMPIX" not in body, f"{rel} still has the gUSEPAPYRUSDCMPIX flag")
    check("cachedPapyGroups" not in body and "clearCachedPapyGroups" not in body, f"{rel} still has the Papyrus group cache")
    check("PapyrusLockFunction" not in body, f"{rel} still has PapyrusLockFunction")
    check("USEPAPYRUSDCMPIX4" not in body, f"{rel} still names USEPAPYRUSDCMPIX4")
pix = class_text("DCMPix")
check("= loadDICOMPapyrus()" not in pix and "if loadDICOMPapyrus()" not in pix, "DCMPix still falls back to the Papyrus stub")
# NSImage (OsiriX) is in Swift.
# DicomFile is Swift (DicomFile.swift and DicomFile+<category>.swift); its DCMTK
# reading (DicomFile+DICOMReading, +DICOMCrop, +DCMTKFields) takes the lock.
DCMTK_READING = ("DicomFile+DICOMReading.swift", "DicomFile+DICOMCrop.swift", "DicomFile+DCMTKFields.swift")
dicomfile = ["Horos/Sources/DicomFile.swift"] + [str(p.relative_to(ROOT)) for p in sorted((ROOT / "Horos/Sources").glob("DicomFile+*.swift"))]
# The former DCMTK categories of the browser and the XML editor are Swift and
# adapters.
for path in ("Horos/Sources/BrowserController+Transcoding.swift", "Horos/Sources/Adapters/DCMTK/IsiXDCMTKTagEditor.mm",
             str(source_path("NSImage+OsiriX").relative_to(ROOT)),
             *[path for path in dicomfile if Path(path).name not in DCMTK_READING]):
    check("PapyrusLock" not in text(path), f"{path} still declares a lock it never takes")

# Kept. AppController is Swift: the exported globals stayed in
# AppController+CAPI.m, and the Swift launch code allocates them.
app = text(source_path("AppController").relative_to(ROOT))
capi = text(source_path("AppController+CAPI").relative_to(ROOT))
check(re.search(r"NSRecursiveLock\s+\*PapyrusLock = nil", capi) is not None, "the PapyrusLock global is gone")
check("PapyrusLock = NSRecursiveLock()" in app, "PapyrusLock is no longer allocated at launch")
for lock in ("STORESCP", "STORESCPTLS"):
    check(f"*{lock} = nil" in capi and f"{lock} = NSRecursiveLock()" in app, f"the {lock} lock is gone")
# The parsed-file cache in DCMPix+Loading.swift, the annotations in DCMPix+Annotations.swift.
annotations = text("Horos/Sources/DCMPix+Annotations.swift")
cache = text("Horos/Sources/DCMPix+Loading.swift")
locks = pix.count("PapyrusLock?.lock()")
unlocks = pix.count("PapyrusLock?.unlock()")
check(cache.count("PapyrusLock?.lock()") >= 3 and annotations.count("PapyrusLock?.lock()") >= 1 and locks == unlocks,
      "DCMPix no longer takes PapyrusLock in balanced pairs around the parsed-file cache and annotations")
dcmtk = "".join(text("Horos/Sources/" + name) for name in DCMTK_READING)
check(dcmtk.count("PapyrusLock?.lock()") >= 4 and dcmtk.count("PapyrusLock?.lock()") == dcmtk.count("PapyrusLock?.unlock()"),
      "the DCMTK reading of DicomFile no longer takes PapyrusLock in balanced pairs around DCMTK reads")
codes = re.search(r"enum EPhoto_Interpret\s*\{([^}]+)\}", pix)
if codes is None and "loadNonDICOMImage" in pix:
    # The YBR conversion is in Swift (IsiXImaging), with the three codes it converts
    # at the places they held in the enumeration: YBR_FULL, YBR_FULL_422, YBR_PARTIAL_422.
    ybr = text("Modules/IsiXImaging/Sources/NonDICOM/YBRConversion.swift")
    check("public static let full = 7, full422 = 8, partial422 = 9" in ybr, "the photometric interpretation codes changed")
else:
    check(codes is not None and [c.strip() for c in codes.group(1).split(",")] == [
        "MONOCHROME1", "MONOCHROME2", "PALETTE", "RGB", "HSV", "ARGB", "CMYK", "YBR_FULL", "YBR_FULL_422",
        "YBR_PARTIAL_422", "YBR_RCT", "YBR_ICT", "YUV_RCT", "UNKNOWN_COLOR"], "the photometric interpretation codes changed")
header = text("Horos/Sources/DCMPix.h")
check("- (BOOL) loadDICOMPapyrus;" in header and "func loadDICOMPapyrus() -> Bool" in pix, "-loadDICOMPapyrus left the SDK")
check("- (void) releaseParsedFile;" in header, "-releaseParsedFile left the SDK")
check("loadCustomImageAnnotationsPapyLink:(int)fileNb DCMLink:" in text("Horos/Sources/DCMPix+Annotations.h")
      and '#import "DCMPix+Annotations.h"' in header, "the annotations method left the SDK")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
check('TOOLKITPARSER4' in default_preferences.registered(viewer=False), "the TOOLKITPARSER4 default is gone")
check('objectForKey: @"TOOLKITPARSER4"' in "".join(text(path) for path in dicomfile)
      or ('defaults.object(forKey: ImportSettings.registeredKey) != nil' in "".join(text(path) for path in dicomfile)
          and 'public static let registeredKey = "TOOLKITPARSER4"' in text("Modules/IsiXDICOMFile/Sources/ImportSettings.swift")),
      "DicomFile no longer reads TOOLKITPARSER4")

for failure in failures:
    print("FAIL:", failure)
if failures:
    print(f"{len(failures)} failure(s)")
    raise SystemExit(1)
print("PASS: the Papyrus3 toolkit, the always-NO flag, its fallback, the empty group cache, the C lock wrapper, the "
      "default and the stray extern declarations are gone; PapyrusLock (allocated, balanced around the cache, "
      "annotations and DCMTK reads), the store locks, the colour codes, the SDK methods and TOOLKITPARSER4 remain")
