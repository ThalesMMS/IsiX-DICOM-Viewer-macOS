#!/usr/bin/env python3
"""Surface Rendering hands each surface the options the settings sheet asked for.

Source checks of the two defects, run on the checkout and on the revision before
the fix, where they must fail:

  * -[SRController renderSurfaces] and -renderFusionSurfaces: every
    changeActor/BchangeActor call passes _shouldDecimate as the decimation option
    and _shouldSmooth as the smoothing option (the second surface passed
    _shouldDecimate for both);
  * -[SRView changeActor:...] and -BchangeActor:...: the smoother reads what the
    steps before it produced (previousOutput), never a decimation filter, which
    does not exist when decimation is off (the fusion read BisoDeci[ actor]).

The controller and the view are Swift now (SRController.swift, SRView.swift),
and the surfaces' pipeline is the VTK adapter's (-[IsiXVTKIsoSurfaceSource
surfaceAtValue:...], which both surfaces and the fused ones go through): the
checkout is checked in that spelling, an earlier revision in Objective-C.

The behaviour in the app - triangles, smoothing, parity between surfaces and no
crash - is checked by tools/measure-native-sr-surfaces.py --check-only.

    python3 tests/test-sr-surface-options.py                  # the checkout, and efb2b0cef must fail
    python3 tests/test-sr-surface-options.py --revision REV   # the source at REV only
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = "Horos/Sources/SRController.mm"
VIEW = "Horos/Sources/SRView.mm"
SWIFT_CONTROLLER = "Horos/Sources/SRController.swift"
SWIFT_VIEW = "Horos/Sources/SRView.swift"
ADAPTER = "Horos/Sources/Adapters/VTK/IsiXVTKSceneActors.mm"
BEFORE_FIX = "efb2b0cef"


def source(path, revision):
    if revision is None:
        return (ROOT / path).read_bytes().decode("latin-1")
    shown = subprocess.run(["git", "-C", str(ROOT), "show", f"{revision}:{path}"], capture_output=True)
    if shown.returncode:
        raise LookupError(shown.stderr.decode(errors="replace").strip())
    return shown.stdout.decode("latin-1")


def without_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def method_body(text, signature):
    """The braces of the first method whose declaration line matches `signature`."""
    match = re.search(signature, text)
    if not match:
        raise LookupError(f"no method matching {signature!r}")
    start = text.index("{", match.end())
    depth = 0
    for index in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise LookupError(f"unbalanced method {signature!r}")


def calls(body, selector):
    """The arguments of each `[view <selector> :a :b ...]` message, as stripped expressions."""
    found = []
    for match in re.finditer(r"\[\s*view\s+" + selector + r"\s*(:.*?)\]\s*;", body, flags=re.S):
        found.append([part.strip() for part in match.group(1).split(":")[1:]])
    return found


def check_controller(text, problems):
    text = without_comments(text)
    for method, selector in (("renderSurfaces", "changeActor"), ("renderFusionSurfaces", "BchangeActor")):
        body = method_body(text, r"-\s*\(void\)\s*" + method + r"\b")
        messages = calls(body, selector)
        if len(messages) != 2:
            problems.append(f"{method}: expected two {selector} calls, found {len(messages)}")
            continue
        for surface, arguments in enumerate(messages):
            if len(arguments) != 11:
                problems.append(f"{method}, surface {surface}: {len(arguments)} arguments")
                continue
            if arguments[7] != "_shouldDecimate":
                problems.append(f"{method}, surface {surface}: decimation option {arguments[7]!r}")
            if arguments[9] != "_shouldSmooth":
                problems.append(f"{method}, surface {surface}: smoothing option {arguments[9]!r}")


def check_view(text, problems):
    text = without_comments(text)
    for method, prefix in (("changeActor", "iso"), ("BchangeActor", "Biso")):
        body = method_body(text, r"-\s*\(void\)\s*" + method + r"\s*:\s*\(long\)")
        block = re.search(r"if\s*\(\s*useSmooth\s*\)\s*\{(.*?)\}", body, flags=re.S)
        if not block:
            problems.append(f"{method}: no smoothing block")
            continue
        inputs = re.findall(prefix + r"Smoother\[\s*actor\]\s*->\s*(SetInput\w*)\s*\((.*?)\)\s*;", block.group(1), flags=re.S)
        if len(inputs) != 1:
            problems.append(f"{method}: expected one smoother input, found {inputs}")
            continue
        call, argument = inputs[0][0], inputs[0][1].strip()
        if call != "SetInputData" or argument != "previousOutput":
            problems.append(f"{method}: the smoother reads {call}({argument}), not what the previous step produced")
        if re.search(prefix + r"Deci\[", block.group(1)):
            problems.append(f"{method}: the smoothing block reads the decimation filter")


def swift_arguments(text, call):
    """The arguments of each `call(` in `text`, split at the commas outside brackets."""
    found = []
    for match in re.finditer(re.escape(call) + r"\(", text):
        depth, start, parts = 1, match.end(), []
        index = start
        while depth:
            character = text[index]
            if character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
            elif character == "," and depth == 1:
                parts.append(text[start:index].strip())
                start = index + 1
            index += 1
        parts.append(text[start:index - 1].strip())
        found.append(parts)
    return found


def check_swift(problems):
    controller = without_comments(source(SWIFT_CONTROLLER, None))
    for method, call in (("renderSurfaces", "view.changeActor"), ("renderFusionSurfaces", "view.BchangeActor")):
        body = method_body(controller, r"func\s+" + method + r"\(\)")
        messages = swift_arguments(body, call)
        if len(messages) != 2:
            problems.append(f"{method}: expected two {call} calls, found {len(messages)}")
            continue
        for surface, arguments in enumerate(messages):
            if len(arguments) != 11:
                problems.append(f"{method}, surface {surface}: {len(arguments)} arguments")
                continue
            if arguments[7] != "shouldDecimate":
                problems.append(f"{method}, surface {surface}: decimation option {arguments[7]!r}")
            if arguments[9] != "shouldSmooth":
                problems.append(f"{method}, surface {surface}: smoothing option {arguments[9]!r}")
    view = without_comments(source(SWIFT_VIEW, None))
    built = swift_arguments(view, "source.surface")
    if len(built) != 1 or built[0][2:6] != ["decimate: useDecimate", "reduction: Double(decimateVal)",
                                            "smooth: useSmooth", "iterations: smoothVal"]:
        problems.append(f"SRView builds its surfaces with {built}")
    adapter = without_comments(source(ADAPTER, None))
    body = method_body(adapter, r"-\s*\(IsiXVTKActor \*\)surfaceAtValue:")
    block = re.search(r"if\s*\(\s*smooth\s*\)\s*\{(.*?)\}", body, flags=re.S)
    if not block:
        problems.append("surfaceAtValue: no smoothing block")
    else:
        inputs = re.findall(r"smoother->(SetInput\w*)\((.*?)\);", block.group(1))
        if inputs != [("SetInputData", "previous")]:
            problems.append(f"surfaceAtValue: the smoother reads {inputs}, not what the previous step produced")
        if "decimation" in block.group(1):
            problems.append("surfaceAtValue: the smoothing block reads the decimation filter")


def problems_at(revision):
    problems = []
    if revision is None:
        check_swift(problems)
        return problems
    check_controller(source(CONTROLLER, revision), problems)
    check_view(source(VIEW, revision), problems)
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    arguments = parser.parse_args()
    problems = problems_at(arguments.revision)
    label = arguments.revision or "checkout"
    for problem in problems:
        print(f"FAIL ({label}): {problem}")
    if arguments.revision:
        return 1 if problems else 0
    # The checks have to see the defects where they were.
    try:
        before = problems_at(BEFORE_FIX)
    except LookupError as error:
        print(f"{BEFORE_FIX} not compared: {error}")
        before = None
    if before is not None:
        expected = ("renderSurfaces, surface 1: smoothing option '_shouldDecimate'",
                    "BchangeActor: the smoother reads SetInputConnection(BisoDeci[ actor]->GetOutputPort()), "
                    "not what the previous step produced")
        for message in expected:
            if message not in before:
                problems.append(f"the check does not see the defect at {BEFORE_FIX}: {message!r} not in {before}")
                print(f"FAIL: the check does not see the defect at {BEFORE_FIX}: {message!r}")
        unexpected = [p for p in before if p not in expected and "reads the decimation filter" not in p]
        if unexpected:
            problems.append(f"unexpected findings at {BEFORE_FIX}: {unexpected}")
            print(f"FAIL: unexpected findings at {BEFORE_FIX}: {unexpected}")
    if not problems:
        print("ok: every surface gets its own options, and the smoothers read the previous step")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
