#!/usr/bin/env python3
"""A sheet is ended while it still has a parent, so its completion handler runs.

Once a sheet has been ordered out, -[NSWindow sheetParent] answers nil, and
`[sheet.sheetParent endSheet:sheet ...]` (Swift `sheet.sheetParent?.endSheet`)
sends nothing: the handler given to -beginSheet:completionHandler: never runs
and the parent keeps a sheet that was never ended. The drop of a series on a
viewer (Image Fusion, Resample...) and the slice interval sheet before a 3D
viewer did nothing for that reason. -[NSWindow orderOutAndEndSheetWithReturnCode:]
(Nitrogen/Sources/NSWindow+N2.swift) reads the parent before ordering out.

Two checks:

  * the sources: no method orders a window out (or closes it) and then ends it
    through its sheetParent, in any source folder, whatever lies between them;
  * compiled: -endBlendingType:, taken from ViewerController+Blending.swift
    into a stand-in ViewerController with the NSWindow helpers, ends a real
    sheet begun as -[ViewerController completeDragOperation:] begins it, and
    the handler receives the blending type of the button, also for the
    segmented RGB control.

    python3 tests/test-sheet-ending.py              # the checkout; b327fec23 must fail
    python3 tests/test-sheet-ending.py --revision R # the sources at R only
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: E402,F401  (TMPDIR of the test's own)
import tempfile  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BEFORE_FIX = "b327fec23"
BLENDING = "Horos/Sources/ViewerController+Blending.swift"
WINDOW = "Nitrogen/Sources/NSWindow+N2.swift"
# Sheets that ended through their sheetParent after being ordered out, by key
# (file, method, window) as found at BEFORE_FIX. The control has to find at
# least these, among them the two whose handler does the work.
MUST_FIND_BEFORE = {
    ("Horos/Sources/ViewerController+Blending.swift", "endBlendingType", "blendingTypeWindow"),
    ("Horos/Sources/ViewerController.m", "endThicknessInterval", "ThickIntervalWindow"),
}
MINIMUM_BEFORE = 42


def git(*arguments):
    done = subprocess.run(["git", "-C", str(ROOT), *arguments], capture_output=True)
    if done.returncode:
        raise LookupError(done.stderr.decode(errors="replace").strip())
    return done.stdout


def source(path, revision):
    raw = (ROOT / path).read_bytes() if revision is None else git("show", f"{revision}:{path}")
    return raw.decode("utf-8" if path.endswith(".swift") else "latin-1")


def candidates(revision):
    found = subprocess.run(["git", "-C", str(ROOT), "grep", "-l", "-e", "sheetParent",
                            *([revision] if revision else []), "--", "*.m", "*.mm", "*.swift"],
                           capture_output=True, text=True)
    if found.returncode not in (0, 1):
        raise LookupError(found.stderr.strip())
    paths = [line.split(":", 1)[1] if revision else line for line in found.stdout.splitlines()]
    return [path for path in paths if path]


def without_comments(text):
    """Comments and string literals blanked, newlines kept, so offsets and line
    numbers stay those of the file."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        elif text[i] in "\"'":
            quote, j = text[i], i + 1
            while j < n and text[j] != quote and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


ENDS = re.compile(
    r"\[\s*(?P<objc>[A-Za-z_][\w.]*?)\s*\.\s*sheetParent\s+endSheet\s*:"
    r"|\[\s*\[\s*(?P<bracket>[A-Za-z_][\w.]*?)\s+sheetParent\s*\]\s+endSheet\s*:"
    r"|(?P<swift>[A-Za-z_][\w.]*?)[?!]?\s*\.\s*sheetParent\s*[?!]?\s*\.\s*endSheet\s*\(")
METHOD = re.compile(r"^[ \t]*[-+][ \t]*\(|\bfunc\s+\w+", re.M)
ALIAS = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*NSWindow[?!]?\s*)?=\s*([A-Za-z_][\w.]*)[?!]?\s*(?=[,{\n])"
                   r"|\bNSWindow\s*\*\s*(\w+)\s*=\s*([A-Za-z_][\w.]*)\s*;")


def key(receiver):
    """The window a receiver names: `self.horos_blendingTypeWindow`,
    `blendingTypeWindow` and `_blendingTypeWindow` are one window."""
    last = receiver.split(".")[-1]
    last = re.sub(r"^horos_", "", last)
    return last.lstrip("_")


def method_name(text, start):
    declaration = text[start:text.find("\n", start)]
    swift = re.search(r"\bfunc\s+(\w+)", declaration)
    if swift:
        return swift.group(1)
    objc = re.search(r"\)\s*(\w+)", declaration)
    return objc.group(1) if objc else "?"


def findings(path, text):
    """(path, method, window, line of the hide, line of the end) for every end
    through sheetParent that a hide of the same window precedes in the method."""
    plain = without_comments(text)
    starts = [match.start() for match in METHOD.finditer(plain)]
    found = []
    for end in ENDS.finditer(plain):
        receiver = end.group("objc") or end.group("bracket") or end.group("swift")
        start = max([s for s in starts if s < end.start()], default=0)
        body = plain[start:end.start()]
        names = {key(receiver)}
        for alias in ALIAS.finditer(body):
            name, value = (alias.group(1), alias.group(2)) if alias.group(1) else (alias.group(3), alias.group(4))
            if key(name) in names or key(value) in names:
                names |= {key(name), key(value)}
        hides = []
        for hide in re.finditer(r"\[\s*([A-Za-z_][\w.]*)\s+(?:orderOut|close|performClose)\b"
                                r"|([A-Za-z_][\w.]*)[?!]?\s*\.\s*(?:orderOut|close|performClose)\s*\(", body):
            if key(hide.group(1) or hide.group(2)) in names:
                hides.append(hide)
        if hides:
            line = lambda offset: plain.count("\n", 0, offset) + 1
            found.append((path, method_name(plain, start), key(receiver),
                          line(start + hides[0].start()), line(end.start())))
    return found


def scan(revision):
    found = []
    for path in candidates(revision):
        found += findings(path, source(path, revision))
    return found


# -- compiled: -endBlendingType: on a real sheet -------------------------------

def top_level(text, signature):
    start = text.find(signature)
    if start < 0:
        raise LookupError(f"no {signature!r}")
    return text[start:text.index("\n}\n", start) + 3]


def member(text, signature):
    start = text.find(signature)
    if start < 0:
        raise LookupError(f"no {signature!r}")
    return text[start:text.index("\n    }\n", start) + 7]


HARNESS = r'''import AppKit

%(window)s

%(helpers)s

final class ViewerController: NSObject {
    var horos_blendingTypeWindow: NSWindow?
    var received: [Int32] = []
    @objc(blendingSheetDidEnd:returnCode:contextInfo:)
    func blendingSheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        received.append(returnCode)
    }
}

extension ViewerController {
%(end)s
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
parent.orderFront(nil)
let viewer = ViewerController()
var failures: [String] = []

// Begun as -completeDragOperation: begins it, ended by a button of the sheet
// (Image Fusion 1, Resample 11, Cancel 0) or by the segmented RGB control
// (its tag 4 plus the selected segment).
func check(_ sender: NSControl, expect: Int32, _ label: String) {
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    viewer.horos_blendingTypeWindow = sheet
    viewer.received = []
    let ran = expectation()
    parent.beginSheet(sheet) { returnCode in
        viewer.blendingSheetDidEnd(sheet, returnCode: Int32(returnCode.rawValue), contextInfo: nil)
        ran.fulfilled = true
    }
    pump { parent.attachedSheet === sheet }
    viewer.endBlendingType(sender)
    pump { ran.fulfilled && parent.attachedSheet == nil }
    if viewer.received != [expect] { failures.append("\(label): the handler received \(viewer.received), not [\(expect)]") }
    if parent.attachedSheet != nil { failures.append("\(label): the parent keeps an attached sheet") }
    if sheet.isVisible { failures.append("\(label): the sheet is still on screen") }
}

final class Flag { var fulfilled = false }
func expectation() -> Flag { Flag() }
func pump(until done: () -> Bool) {
    let limit = Date(timeIntervalSinceNow: 5)
    while !done() && Date() < limit { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
}

let fusion = NSButton(); fusion.tag = 1
check(fusion, expect: 1, "Image Fusion")
let resample = NSButton(); resample.tag = 11
check(resample, expect: 11, "Resample")
let rgb = NSSegmentedControl(labels: ["R", "G", "B"], trackingMode: .selectOne, target: nil, action: nil)
rgb.tag = 4; rgb.selectedSegment = 2
check(rgb, expect: 6, "RGB")
let cancel = NSButton(); cancel.tag = 0
check(cancel, expect: 0, "Cancel")

if failures.isEmpty { print("ok") } else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
'''


def compiled_problems(revision):
    if shutil.which("xcrun") is None:
        return None
    blending = source(BLENDING, revision)
    window = source(WINDOW, revision)
    window = window[window.index("public extension NSWindow"):]
    helpers = top_level(blending, "fileprivate func objcImplementation(") + "\n" + \
        top_level(blending, "fileprivate func objcSendInteger(")
    end = member(blending, "    @objc(endBlendingType:)")
    folder = Path(tempfile.mkdtemp())
    (folder / "main.swift").write_text(HARNESS % {"window": window, "helpers": helpers, "end": end})
    build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-o", str(folder / "harness"), str(folder / "main.swift")],
                           capture_output=True, text=True, timeout=300)
    if build.returncode:
        return [f"the harness does not compile: {build.stderr.strip()[-2000:]}"]
    run = subprocess.run([str(folder / "harness")], capture_output=True, text=True, timeout=120)
    return [line[len("FAIL: "):] for line in run.stdout.splitlines() if line.startswith("FAIL: ")] or \
        ([] if run.returncode == 0 else [f"the harness exited {run.returncode}: {run.stderr.strip()[-500:]}"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    arguments = parser.parse_args()
    revision = arguments.revision
    label = revision or "checkout"
    problems = []

    for path, method, window, hide, end in scan(revision):
        problems.append(f"{path}:{end}: {method} ends {window} through sheetParent after hiding it at line {hide}")
    compiled = compiled_problems(revision)
    if compiled is None:
        print("skipped: needs xcrun (swiftc) for the sheet harness")
        return 2
    problems += [f"endBlendingType: {problem}" for problem in compiled]
    for problem in problems:
        print(f"FAIL ({label}): {problem}")
    if revision:
        return 1 if problems else 0

    # The checks have to see the defect where it was.
    try:
        before = scan(BEFORE_FIX)
        before_compiled = compiled_problems(BEFORE_FIX)
    except LookupError as error:
        print(f"{BEFORE_FIX} not compared: {error}")
        before = before_compiled = None
    if before is not None:
        control = []
        keys = {(path, method, window) for path, method, window, _, _ in before}
        for missing in sorted(MUST_FIND_BEFORE - keys):
            control.append(f"the scan does not see {missing} at {BEFORE_FIX}")
        if len(before) < MINIMUM_BEFORE:
            control.append(f"the scan sees {len(before)} sites at {BEFORE_FIX}, fewer than {MINIMUM_BEFORE}")
        if not before_compiled or not any("the handler received []" in p for p in before_compiled):
            control.append(f"the harness does not see the handler fail at {BEFORE_FIX}: {before_compiled}")
        for problem in control:
            print(f"FAIL: {problem}")
        problems += control
        if not control:
            print(f"control: {BEFORE_FIX} has {len(before)} sites and the harness fails there "
                  f"({len(before_compiled)} findings)")
    if not problems:
        print("ok: every sheet is ended through its parent before it is hidden; "
              "-endBlendingType: hands the handler its blending type")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
