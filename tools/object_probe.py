"""Build probes against the object files the application itself is compiled from.

A slice copied out of a source file proves the slice. Linking the `.o` that
xcodebuild produced for the app proves the shipped code, with the shipped
flags. Two uses share this module:

* functional tests link the app's own object (`app_object`) and exercise it;
* A/B measurements recompile one source file at two git revisions with the
  *exact* command xcodebuild used for it (`compile_command`), so baseline and
  candidate differ only in that file's contents.

Both link with `-undefined dynamic_lookup`; project classes the object names
must still exist at load time, so callers pass stub implementations for them.
"""
from __future__ import annotations

import re
import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# script/build_and_run.sh sets SYMROOT since 8643cac9f, which moved the objects
# out of build/Build. Both layouts are looked at; the newer object wins, so a
# stale one left by an older build is not probed instead of the current one.
INTERMEDIATES = ("build/Intermediates.noindex/Horos.build/{configuration}/Horos.build/Objects-normal/arm64",
                 "build/Build/Intermediates.noindex/Horos.build/{configuration}/Horos.build/Objects-normal/arm64")
LOGS = {"Debug": "build/logs/build-and-run.log", "Release": "build/logs/build-release.log"}


def app_object(name: str, configuration: str = "Debug", root: Path = ROOT) -> Path | None:
    found = [root / layout.format(configuration=configuration) / f"{name}.o" for layout in INTERMEDIATES]
    found = [path for path in found if path.is_file()]
    return max(found, key=lambda path: path.stat().st_mtime) if found else None


def first_app_object(name: str, root: Path = ROOT) -> Path | None:
    for configuration in ("Debug", "Release"):
        found = app_object(name, configuration, root)
        if found:
            return found
    return None


def _commands_in_text_log(log: Path, source: str) -> list[str]:
    found = []
    for line in log.read_text(errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("/") and "/clang " in stripped and any(
                f" -c {spelling} " in f"{stripped} " for spelling in _logged_spellings(source)):
            found.append(stripped)
    return found


def _logged_spellings(source: str) -> tuple[str, ...]:
    # xcodebuild escapes a space in a path with a backslash ("Preference\ Panes"),
    # which is neither the bare path nor shlex's quoting of it.
    return (source, shlex.quote(source), source.replace(" ", "\\ "))


def _commands_in_activity_logs(root: Path, source: str, configuration: str) -> list[str]:
    """Compile commands from xcodebuild's own xcactivitylog records, newest last.

    An incremental build rewrites the text log without the files it did not
    recompile; the activity logs of earlier builds still hold them. They are
    gzipped SLF streams, where a string token is `<length>"<bytes>`.
    """
    import gzip
    logs = sorted((root / "build/logs/Build").glob("*.xcactivitylog"), key=lambda p: p.stat().st_mtime)
    found = []
    markers = [spelling.encode() for spelling in _logged_spellings(source)]
    for log in logs:
        try:
            data = gzip.decompress(log.read_bytes())
        except OSError:
            continue
        for match in re.finditer(rb'(\d+)"', data):
            length = int(match.group(1))
            start = match.end()
            token = data[start:start + length]
            if b"/clang " in token[:400] and any(marker in token for marker in markers) and b" -c " in token:
                text = token.decode(errors="replace").strip()
                if f"/{configuration}/" in text and any(f" -c {spelling} " in f"{text} "
                                                        for spelling in _logged_spellings(source)):
                    found.append(text)
    return found


# Options whose value is a file clang reads: a command naming one that is gone
# was logged by a build whose intermediates have since been cleaned.
_INPUT_OPTIONS = ("-include-pch", "-include", "-ivfsoverlay", "-isysroot", "-fmodule-map-file", "-fmodule-file")
# Header maps are passed as include directories; a missing one is not an error
# to clang, it silently resolves headers another way.
_HEADER_MAP_OPTIONS = ("-I", "-iquote", "-isystem")


def _missing_input(value: str, option: str) -> bool:
    if not value.startswith("/"):
        return False  # relative to xcodebuild's working directory; not checked
    path = Path(value)
    if option == "-include":
        # xcodebuild names the prefix header; clang loads the PCH beside it.
        return not any(Path(value + suffix).exists() for suffix in ("", ".pch", ".gch"))
    return not path.exists()


def missing_inputs(command: str | list[str], _depth: int = 0) -> list[str]:
    """Files a logged clang command reads that no longer exist, response files' contents included."""
    argv = shlex.split(command) if isinstance(command, str) else list(command)
    missing = []
    for index, item in enumerate(argv):
        following = argv[index + 1] if index + 1 < len(argv) else None
        if item.startswith("@"):
            response = Path(item[1:])
            if not response.is_file():
                missing.append(str(response))
            elif _depth < 4:
                missing += missing_inputs(response.read_text(errors="replace"), _depth + 1)
            continue
        if item in _INPUT_OPTIONS and following is not None:
            value = following.rsplit("=", 1)[-1] if item == "-fmodule-file" else following
            if _missing_input(value, item):
                missing.append(value)
            continue
        joined = next((option for option in ("-fmodule-map-file=", "-fmodule-file=", "-ivfsoverlay=")
                       if item.startswith(option)), None)
        if joined:
            value = item[len(joined):].rsplit("=", 1)[-1]
            if _missing_input(value, joined.rstrip("=")):
                missing.append(value)
            continue
        if item in _HEADER_MAP_OPTIONS and following is not None and following.endswith(".hmap"):
            if _missing_input(following, item):
                missing.append(following)
            continue
        joined = next((option for option in _HEADER_MAP_OPTIONS if item.startswith(option) and item != option), None)
        if joined and item.endswith(".hmap") and _missing_input(item[len(joined):], joined):
            missing.append(item[len(joined):])
    return missing


def compile_command(source_relative: str, configuration: str = "Debug", root: Path = ROOT,
                    log: Path | None = None) -> list[str]:
    """The clang invocation xcodebuild logged for one source file, as argv.

    Only a command whose response files, precompiled header, module maps and
    header maps still exist is used: logs outlive the intermediates they name,
    so the newest command found may belong to a build that has been cleaned
    since. Each source is tried in turn until one yields a usable command.

    Index-store, dependency and diagnostics outputs are dropped so recompiling
    never touches the application's build directory; `-c` and `-o` are left for
    the caller to replace.
    """
    source = str(root / source_relative)
    stale: dict[str, list[str]] = {}

    def usable(commands: list[str]) -> list[str]:
        kept = []
        for command in commands:
            missing = missing_inputs(command)
            if missing:
                stale[command] = missing
            else:
                kept.append(command)
        return kept

    candidates = []
    text_log = log or root / LOGS[configuration]
    if text_log.is_file():
        candidates = usable([c for c in _commands_in_text_log(text_log, source) if log or f"/{configuration}/" in c])
    if not candidates and log is None:
        # Any other xcodebuild text log kept under build/logs, newest last.
        for other in sorted((root / "build/logs").glob("*.log"), key=lambda p: p.stat().st_mtime):
            candidates += usable([c for c in _commands_in_text_log(other, source) if f"/{configuration}/" in c])
    if not candidates and log is None:
        candidates = usable(_commands_in_activity_logs(root, source, configuration))
    # Every command found is kept under build/logs/compile-commands: incremental
    # builds rewrite the text log and Xcode rotates its activity logs, so a file
    # not recompiled lately would otherwise have no command at all.
    cache = root / "build/logs/compile-commands" / configuration / (source_relative.replace("/", "__") + ".txt")
    if candidates and log is None:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(candidates[-1])
    elif not candidates and log is None and cache.is_file():
        candidates = usable([cache.read_text()])
    if not candidates:
        where = f"{text_log}" if log else f"{text_log}, the other logs in build/logs, the activity logs or the cache"
        if stale:
            example = next(iter(stale.values()))[0]
            raise LookupError(f"every compile command for {source_relative} in {where} names files that no longer "
                              f"exist (for example {example}); rebuild {configuration} to log a current one")
        raise LookupError(f"no compile command for {source_relative} in {where}; build {configuration} first")
    command = candidates[-1]
    argv = shlex.split(command)
    cleaned = []
    skip = 0
    for index, item in enumerate(argv):
        if skip:
            skip -= 1
            continue
        if item in ("-index-store-path", "-MF", "-MT", "--serialize-diagnostics", "-index-unit-output-path",
                    "-ivfsstatcache"):
            skip = 1
            continue
        if item in ("-MMD", "-c", "-o"):
            if item in ("-c", "-o"):
                skip = 1
            continue
        cleaned.append(item)
    return cleaned


def compile_source(argv: list[str], source: Path, output: Path) -> None:
    subprocess.run(argv + ["-c", str(source), "-o", str(output)], check=True)


def revision_source(source_relative: str, revision: str, destination: Path, root: Path = ROOT) -> Path:
    """Write a file as it was at `revision`, byte for byte (legacy sources are not UTF-8)."""
    data = subprocess.run(["git", "-C", str(root), "show", f"{revision}:{source_relative}"],
                          check=True, capture_output=True).stdout
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return destination


def undefined_project_classes(obj: Path, root: Path = ROOT) -> list[str]:
    """Objective-C classes an object references that the project, not the SDK, defines."""
    symbols = subprocess.run(["nm", "-u", str(obj)], check=True, capture_output=True, text=True).stdout
    names = sorted({m.group(1) for m in re.finditer(r"_OBJC_CLASS_\$_(\w+)", symbols)})
    project = []
    for name in names:
        if name.startswith("NS") or name.startswith("CA") or name.startswith("MTL"):
            continue
        project.append(name)
    return project


def link_probe(probe_source: Path, objects: list[Path], output: Path, *, extra_sources: list[Path] = (),
               frameworks=("Foundation",), optimization="-O2", arc=False, include_dirs=(), defines=()) -> Path:
    argv = ["xcrun", "clang", optimization, "-g0", "-arch", "arm64", "-mmacosx-version-min=26.0"]
    argv += ["-D" + define for define in defines]
    argv += ["-fobjc-arc"] if arc else ["-fno-objc-arc"]
    for directory in include_dirs:
        argv += ["-I", str(directory)]
    argv += [str(probe_source)] + [str(s) for s in extra_sources] + [str(o) for o in objects]
    for framework in frameworks:
        argv += ["-framework", framework]
    # A library among the objects (swift_dylib) is found next to itself.
    for directory in sorted({str(Path(o).parent) for o in objects if str(o).endswith(".dylib")}):
        argv += ["-Wl,-rpath," + directory]
    argv += ["-lc++", "-Wl,-undefined,dynamic_lookup", "-o", str(output)]
    subprocess.run(argv, check=True)
    return output


def swift_dylib(sources: list[Path], objects: list[Path], output: Path, *, bridging_header: Path,
                include_dirs=(), frameworks=("Foundation",)) -> Path:
    """Swift sources of the app and the Objective-C objects they call, as a loadable image.

    The sources are compiled as module Horos, so their @objc names are the application's.
    """
    argv = ["xcrun", "swiftc", "-emit-library", "-O", "-module-name", "Horos", "-target", "arm64-apple-macos26.0",
            "-import-objc-header", str(bridging_header), "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            "-Xlinker", "-install_name", "-Xlinker", f"@rpath/{output.name}", "-lc++"]
    for directory in include_dirs:
        argv += ["-I", str(directory)]
    for framework in frameworks:
        argv += ["-framework", framework]
    argv += [str(s) for s in sources + module_support_sources()] + [str(o) for o in objects] + ["-o", str(output)]
    subprocess.run(argv, check=True)
    return output


def module_support_sources(root: Path = ROOT) -> list[Path]:
    """Swift files of module Horos that every object of it may call.

    The module declares its own NSLog: an application object that logs
    from Swift names Horos.NSLog, which only UnifiedLogNSLog.swift defines.
    """
    source = root / "Horos/Sources/UnifiedLogNSLog.swift"
    return [source] if source.is_file() else []


def link_dylib(obj: Path | list[Path], output: Path, frameworks=("Foundation",)) -> Path:
    """One revision's object (or objects) as a loadable image, for interleaved in-process A/B."""
    objects = obj if isinstance(obj, (list, tuple)) else [obj]
    argv = ["xcrun", "clang", "-dynamiclib", "-arch", "arm64", "-mmacosx-version-min=26.0", *map(str, objects),
            "-install_name", f"@rpath/{output.name}"]
    for framework in frameworks:
        argv += ["-framework", framework]
    argv += ["-lc++", "-Wl,-undefined,dynamic_lookup", "-o", str(output)]
    subprocess.run(argv, check=True)
    return output
