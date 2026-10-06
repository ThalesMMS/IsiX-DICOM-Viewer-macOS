#!/usr/bin/env python3
"""object_probe.compile_command skips logged commands whose inputs are gone.

compile_command looks for the clang command xcodebuild logged for a source file
in the configuration's text log, then in the other logs in build/logs, then in
the activity logs and finally in its own cache, and took the newest command it
found. Logs outlive the intermediates they name: a command from an older or
cleaned build (a clean-check folder, say) cites a response file (`@....resp`)
and a precompiled header that have since been deleted, and every `--revision`
recompile then failed inside clang with "no such file".

The fix checks what the command reads -- response files and their contents,
`-include` (the prefix header, resolved to its .pch/.gch as clang does),
`-include-pch`, `-ivfsoverlay`, `-isysroot`, module maps and header maps --
and passes over a command that names a missing file, falling through to the
next log, the activity logs or the cache. When nothing usable is left the error
says to rebuild the configuration, and a stale command is never cached.

Everything here is synthetic, in a temporary directory: no build is needed.

    python3 tests/test-object-probe-stale-command.py            # the working tree
    python3 tests/test-object-probe-stale-command.py REV        # tools/object_probe.py at REV

Against a revision from before the stale-command skip, these checks must fail.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "Nitrogen/Sources/Probe.mm"
failures = []


def check(condition, message):
    print(("PASS: " if condition else "FAIL: ") + message)
    if not condition:
        failures.append(message)


def load_object_probe(revision, work):
    if revision is None:
        path = ROOT / "tools/object_probe.py"
    else:
        path = work / "object_probe.py"
        path.write_bytes(subprocess.run(["git", "-C", str(ROOT), "show", f"{revision}:tools/object_probe.py"],
                                        check=True, capture_output=True).stdout)
    spec = importlib.util.spec_from_file_location("object_probe_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def command(root, build, *, resp, pch, marker):
    """A clang line shaped like xcodebuild's, for SOURCE, under a Debug build folder."""
    objects = f"{build}/Intermediates.noindex/Horos.build/Debug/Horos.build/Objects-normal/arm64"
    return (f"    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang "
            f"-x objective-c++ -D{marker}=1 @{resp} -include {pch} -MMD -MT dependencies "
            f"-MF {objects}/Probe.d -c {root / SOURCE} -o {objects}/Probe.o")


def write_log(path, lines, age):
    path.write_text("\n".join(["CompileC Probe.o", *lines, ""]))
    stamp = 1_700_000_000 - age  # older logs first, as sorted by mtime
    os.utime(path, (stamp, stamp))


def chosen(argv):
    return next((item for item in argv if item.startswith(("-D", "LookupError"))), argv)


def cache_of(root):
    return root / "build/logs/compile-commands/Debug" / (SOURCE.replace("/", "__") + ".txt")


def fixture(work, name):
    root = work / name
    (root / SOURCE).parent.mkdir(parents=True)
    (root / SOURCE).write_text("int probe;\n")
    (root / "build/logs").mkdir(parents=True)
    # The current build: its response file and its PCH exist. xcodebuild names
    # the prefix header in -include; only prefix.pch.gch is on disk.
    current = root / "build/Build"
    resp = current / "Intermediates.noindex/Horos.build/Debug/Horos.build/Objects-normal/arm64/aa-common-args.resp"
    resp.parent.mkdir(parents=True)
    hmap = current / "Intermediates.noindex/Horos.build/Debug/Horos.build/Horos-project-headers.hmap"
    hmap.write_bytes(b"hmap")
    resp.write_text(f"-std=c++11 -iquote {hmap} -I{hmap}\n")
    pch = current / "Intermediates.noindex/PrecompiledHeaders/SharedPrecompiledHeaders/111/prefix.pch"
    pch.parent.mkdir(parents=True)
    (pch.parent / "prefix.pch.gch").write_bytes(b"gch")
    good = command(root, current, resp=resp, pch=pch, marker="CURRENT")
    # A cleaned build: same shape, nothing of it left on disk.
    gone = root / "build/clean-check/Build"
    stale = command(root, gone, resp=f"{gone}/Intermediates.noindex/Horos.build/Debug/Horos.build/"
                                     f"Objects-normal/arm64/bb-common-args.resp",
                    pch=f"{gone}/Intermediates.noindex/PrecompiledHeaders/SharedPrecompiledHeaders/222/prefix.pch",
                    marker="STALE")
    return root, good, stale


def run(probe, work):
    # 1. The configuration's text log has nothing for the file (an incremental
    #    build); an older log holds the current command and a newer one a stale
    #    command from a cleaned build. The stale one must not be chosen.
    root, good, stale = fixture(work, "fallback")
    write_log(root / "build/logs/build-and-run.log", ["    /usr/bin/true nothing compiled"], age=0)
    write_log(root / "build/logs/debug-main.log", [good], age=300)
    write_log(root / "build/logs/clean-check.log", [stale], age=100)
    try:
        argv = probe.compile_command(SOURCE, "Debug", root=root)
    except LookupError as error:
        argv = [f"LookupError: {error}"]
    check("-DCURRENT=1" in argv and "-DSTALE=1" not in argv,
          f"a newer command naming a deleted .resp and PCH is passed over for the usable one (chose {chosen(argv)})")
    check(cache_of(root).is_file() and "-DCURRENT=1" in cache_of(root).read_text(),
          "the command cached is the usable one")

    # 2. The same stale command in the configuration's own text log also yields
    #    to a usable one further down the search.
    root, good, stale = fixture(work, "own-log")
    write_log(root / "build/logs/build-and-run.log", [stale], age=0)
    write_log(root / "build/logs/debug-main.log", [good], age=300)
    try:
        argv = probe.compile_command(SOURCE, "Debug", root=root)
    except LookupError as error:
        argv = [f"LookupError: {error}"]
    check("-DCURRENT=1" in argv, f"a stale command in the configuration's own log is not used (chose {chosen(argv)})")

    # 3. Only stale commands: the error says to rebuild, and nothing is cached.
    root, _, stale = fixture(work, "only-stale")
    write_log(root / "build/logs/build-and-run.log", [stale], age=0)
    try:
        argv = probe.compile_command(SOURCE, "Debug", root=root)
        message = None
    except LookupError as error:
        message = str(error)
    check(message is not None and "rebuild Debug" in message and "bb-common-args.resp" in message,
          f"with only stale commands the error names a missing file and asks for a rebuild ({message})")
    check(not cache_of(root).exists(), "a stale command is not written to the cache")

    # 4. A stale command already in the cache is not trusted either.
    root, _, stale = fixture(work, "stale-cache")
    cache_of(root).parent.mkdir(parents=True)
    cache_of(root).write_text(stale.strip())
    try:
        probe.compile_command(SOURCE, "Debug", root=root)
        message = None
    except LookupError as error:
        message = str(error)
    check(message is not None and "rebuild Debug" in message, f"a stale cached command is refused ({message})")

    # 5. A response file that exists but names a deleted header map is stale too.
    root, good, _ = fixture(work, "stale-hmap")
    resp = next((root / "build/Build").rglob("aa-common-args.resp"))
    next((root / "build/Build").rglob("*.hmap")).unlink()
    write_log(root / "build/logs/build-and-run.log", [good], age=0)
    try:
        probe.compile_command(SOURCE, "Debug", root=root)
        message = None
    except LookupError as error:
        message = str(error)
    check(message is not None and ".hmap" in message,
          f"a header map missing from inside {resp.name} makes the command stale ({message})")


def main():
    revision = sys.argv[1] if len(sys.argv) > 1 else None
    with tempfile.TemporaryDirectory(prefix="object-probe-stale-") as directory:
        work = Path(directory)
        probe = load_object_probe(revision, work)
        run(probe, work)
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
