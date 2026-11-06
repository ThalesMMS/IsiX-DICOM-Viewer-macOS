#!/usr/bin/env python3
"""No personal signing identifier is versioned, and the override still reaches the build."""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import os, plistlib, re, shutil, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []

# 1. An Apple team identifier is ten uppercase alphanumerics. None may be
#    committed anywhere the build reads.
team = re.compile(r'\b(?![A-Z]{10}\b)[A-Z0-9]{10}\b')
# Vendored dependencies carry their upstream projects; only this project's own
# build files are in scope.
vendored = ('VTK/', 'ITK/', 'DCMTK/', 'OpenSSL/', 'OpenJPEG/',
            'Papyrus3/')
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files'], text=True).split('\n')
for name in tracked:
    if not name.endswith(('.xcconfig', '.pbxproj', '.plist', '.entitlements')):
        continue
    if name.startswith(vendored):
        continue
    text = (root / name).read_bytes().decode('latin1')
    for line in text.split('\n'):
        if line.lstrip().startswith(('//', '#', '<!--')):
            continue
        for m in re.finditer(r'(DEVELOPMENT_TEAM|TeamIdentifier\w*|com\.apple\.application-identifier)\s*[=>:]\s*"?([^;"\n<]*)', line):
            value = m.group(2).strip()
            if team.fullmatch(value):
                failures.append('%s: %s is a committed team identifier (%s)' % (name, m.group(1), value))

# 2. The default has to be empty so a checkout without credentials resolves.
config = (root / 'Config.xcconfig').read_text()
if not re.search(r'^HOROS_DEVELOPMENT_TEAM\s*=\s*$', config, re.M):
    failures.append('Config.xcconfig: HOROS_DEVELOPMENT_TEAM no longer defaults to empty')
if not re.search(r'^DEVELOPMENT_TEAM\s*=\s*\$\(HOROS_DEVELOPMENT_TEAM\)\s*$', config, re.M):
    failures.append('Config.xcconfig: DEVELOPMENT_TEAM no longer follows HOROS_DEVELOPMENT_TEAM')
if '#include? "Config.local.xcconfig"' not in config:
    failures.append('Config.xcconfig: the untracked local override is no longer included')

# 3. That local file must stay untracked.
ignored = subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', 'Config.local.xcconfig'])
if ignored.returncode != 0:
    failures.append('.gitignore: Config.local.xcconfig would be committed')
if not (root / 'Config.local.xcconfig.example').exists():
    failures.append('Config.local.xcconfig.example is missing, so the override is undocumented')

# 4. Every target has to follow the variable rather than carrying its own team.
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
own = [v for v in re.findall(r'DEVELOPMENT_TEAM = ([^;]+);', project)
       if '$(HOROS_DEVELOPMENT_TEAM)' not in v]
if own:
    failures.append('project.pbxproj: targets carrying their own team: %s' % sorted(set(own)))

if failures:
    print('FAIL:')
    for f in failures:
        print(' ', f)
    sys.exit(1)

# 6. Every executable that ends up inside the bundle has to be signed, or an
#    archive containing it cannot be notarised. Xcode signs the bundle, its
#    frameworks and its embedded bundles; a bare executable copied by Copy Bundle
#    Resources is data to it, so the application target signs those itself.
phase = re.search(r'CED88262125064F70085A861 /\* CodeSigning \*/ = \{(.*?)\n\t\t\};',
                  project, re.S)
if not phase:
    failures.append('project.pbxproj: the CodeSigning phase is gone')
else:
    body = phase.group(1).encode().decode('unicode_escape')
    if 'codesign' not in body:
        failures.append('project.pbxproj: the CodeSigning phase signs nothing')
    if 'alwaysOutOfDate = 1' not in phase.group(1):
        failures.append('project.pbxproj: the CodeSigning phase would be skipped on a rebuild')
    # It walks a directory tree signing what it finds, so an unset build
    # variable must not let that tree become "/".
    if 'TARGET_BUILD_DIR' not in body or 'UNLOCALIZED_RESOURCES_FOLDER_PATH' not in body:
        failures.append('project.pbxproj: the CodeSigning phase does not name the resources folder')
    if 'run it from Xcode' not in body:
        failures.append('project.pbxproj: the CodeSigning phase does not refuse an empty build directory')
    # EXPANDED_CODE_SIGN_IDENTITY_NAME is a display name codesign cannot look up.
    if 'EXPANDED_CODE_SIGN_IDENTITY_NAME' in body:
        failures.append('project.pbxproj: the CodeSigning phase signs with a display name')
    if 'CODE_SIGNING_ALLOWED' not in body:
        failures.append('project.pbxproj: the CodeSigning phase ignores CODE_SIGNING_ALLOWED')

# The same gap exists in the local development bundle, which is re-signed after
# its identifier is changed; codesign --deep does not reach these either.
launcher = (root / 'script/build_and_run.sh').read_text()
if 'Contents/Resources" -type f -perm -u+x' not in launcher or 'codesign' not in launcher:
    failures.append('script/build_and_run.sh: the helpers in Resources are not signed')

# 7. If a bundle has been built, every Mach-O in it has to carry a signature,
#    must be something this product minimum still needs, and must find in the
#    bundle every Swift library it loads that the macOS of that minimum does not
#    have. HorosPlatformPolicy owns both the minimum and what it implies for the
#    bundle, so ask it.
def swiftRuntime(name):
    return name.startswith('libswift') and name.endswith('.dylib')


def machO(path):
    with open(path, 'rb') as handle:
        return handle.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
                                  b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def machOFiles(bundle):
    return [path for path in bundle.rglob('*')
            if path.is_file() and not path.is_symlink() and machO(path)]


# The load commands dyld takes a library from. Only the weak one may name a
# library that is not there: the process starts without it.
loadKinds = ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
             'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB')


def loadCommands(path):
    """For each architecture of `path`: its CPU type, whether it is an
    executable, the libraries it loads as (load command, install name) and the
    folders of its LC_RPATH commands.

    otool -L tells a weak load apart only in passing and does not say where
    @rpath leads; the load commands themselves say both. The header is read in
    numbers, because the words otool has for its fields are not always one each.
    """
    listing = subprocess.run(['otool', '-arch', 'all', '-hl', str(path)],
                             capture_output=True, text=True).stdout
    slices = []
    for text in listing.split('\nMach header\n')[1:]:
        lines = text.split('\n')
        header = lines[1].split() if len(lines) > 1 else []
        if len(header) < 5:
            continue
        loads, rpaths, command = [], [], None
        for line in lines[2:]:
            line = line.strip()
            if line.startswith('cmd '):
                command = line[4:]
                continue
            # A name may hold spaces: that of a framework old plugins link does.
            entry = re.fullmatch(r'(name|path) (.*) \(offset \d+\)', line)
            if not entry:
                continue
            if entry.group(1) == 'name' and command in loadKinds:
                loads.append((command, entry.group(2)))
            elif entry.group(1) == 'path' and command == 'LC_RPATH':
                rpaths.append(entry.group(2))
        slices.append((header[1], header[4] == '2', loads, rpaths))
    return slices


def executableOf(wrapper):
    """The executable the bundle `wrapper` names in its Info.plist, or None."""
    try:
        name = plistlib.loads((wrapper / 'Contents/Info.plist').read_bytes()).get('CFBundleExecutable')
    except Exception:
        return None
    return wrapper / 'Contents/MacOS' / name if name else None


# Every configuration's product counts, not just the one most recently built by
# hand: an incremental products directory keeps what the current build no longer
# produces, and whether that orphan happens to be signed depends on when each
# configuration was last built.
bundles = [bundle for bundle in (root / 'build/Development/HorosDevelopment.app',
                                 root / 'build/Build/Products/Debug/IsiX DICOM Viewer.app',
                                 root / 'build/Build/Products/Release/IsiX DICOM Viewer.app')
           if bundle.is_dir()]
# The policy is asked about the Swift libraries the bundles really carry, and
# about the runtime itself either way: its answer for a library the minimum
# does call for must never be the answer it gives for everything.
embedded = sorted({path.name for bundle in bundles for path in bundle.rglob('libswift*.dylib')
                   if path.is_file() and not path.is_symlink()} | {'libswiftCore.dylib'})
# It is asked as well about the Swift libraries the code in the bundles loads,
# wherever from: the one a build stopped embedding is in no bundle to be found.
loadedSwift = {reference.rsplit('/', 1)[-1]
               for bundle in bundles for path in machOFiles(bundle)
               for cpu, isExecutable, loads, rpaths in loadCommands(path)
               for command, reference in loads}
loadedSwift = {name for name in loadedSwift if swiftRuntime(name)}

policyTool = []


def askPolicy(names, minimum='product'):
    """The policy's answers for a product that starts at macOS `minimum`, the
    product's own when none is named: whether such a product embeds the Swift
    runtime itself, what the policy takes each sample name for, which of
    `names` the product may carry, the minimum answered for, and the
    back-deployment libraries the policy lists with the macOS that has each.
    Five None when it does not answer.
    """
    driver = """
import Foundation

@main struct Check {
    static func main() {
        let named = CommandLine.arguments[1]
        let minimum = named == "product" ? HorosPlatformPolicy.productMinimumDisplay() : named
        let embeds = HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(productMinimum: minimum)
        print(embeds ? "embeds" : "bare")
        print("minimum", minimum, separator: "\\t")
        for name in ["libswift_Concurrency.dylib", "libswiftCore.dylib", "Horos", "libgdcmMSFF.dylib"] {
            print("kind", name, HorosPlatformPolicy.embeddedFileIsSwiftRuntime(name) ? "swift" : "other",
                  separator: "\\t")
        }
        for name in CommandLine.arguments.dropFirst(2) {
            let may = HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: name, productMinimum: minimum)
            print("may", name, may ? "needed" : "orphan", separator: "\\t")
        }
        for (name, since) in HorosPlatformPolicy.swiftBackDeploymentLibraryInOSSince {
            print("since", name, since.display, separator: "\\t")
        }
    }
}
"""
    if not policyTool:
        # Compiled once and asked once for each minimum there is to judge at;
        # the folder is in the TMPDIR this test removes when it exits.
        path = Path(tempfile.mkdtemp(prefix='horos-signing-policy-'))
        (path / 'Check.swift').write_text(driver)
        build = subprocess.run(
            ['xcrun', 'swiftc', '-parse-as-library',
             str(root / 'Horos/Sources/HorosPlatformPolicy.swift'),
             str(path / 'Check.swift'), '-o', str(path / 'check')],
            capture_output=True, text=True)
        policyTool.append(None if build.returncode else path / 'check')
    if policyTool[0] is None:
        return None, None, None, None, None
    run = subprocess.run([str(policyTool[0]), minimum] + list(names), capture_output=True, text=True)
    if run.returncode:
        return None, None, None, None, None
    lines = run.stdout.splitlines()
    records = [line.split('\t') for line in lines[1:]]
    kinds = {record[1]: record[2] for record in records if record[0] == 'kind'}
    needed = {record[1]: record[2] == 'needed' for record in records if record[0] == 'may'}
    answered = [record[1] for record in records if record[0] == 'minimum']
    since = {record[1]: record[2] for record in records if record[0] == 'since'}
    return lines[0] == 'embeds', kinds, needed, answered[0] if answered else None, since

# The back-deployment libraries the policy lists are asked about too, whatever
# has been built: the rule that a bundle carries the one its code loads is
# tried further down on bundles made for it, which no build has to have left.
asked = sorted(set(embedded) | loadedSwift | set(askPolicy([])[4] or {}))
embedsSwiftRuntime, classification, minimumNeeds, productMinimum, listed = askPolicy(asked)
if classification is None:
    failures.append('HorosPlatformPolicy does not answer what the bundle may embed')
    embedsSwiftRuntime = False
    classification = {}
    minimumNeeds = {}
    productMinimum = '(unknown)'
    listed = {}
elif classification != {'libswift_Concurrency.dylib': 'swift', 'libswiftCore.dylib': 'swift',
                        'Horos': 'other', 'libgdcmMSFF.dylib': 'other'}:
    failures.append('HorosPlatformPolicy no longer recognises the Swift runtime by name: %s'
                    % classification)
elif sorted(minimumNeeds) != asked:
    failures.append('HorosPlatformPolicy did not answer for every Swift library in the bundles: %s'
                    % sorted(minimumNeeds))
if embedsSwiftRuntime or minimumNeeds.get('libswiftCore.dylib'):
    failures.append('the product minimum fell below macOS 10.14.4; this check needs revisiting')


def signature(path):
    """What codesign shows of the signature of `path`, or None when it has none.

    codesign names the kind only of an ad hoc signature ("Signature=adhoc"); of
    one made with an identity it shows the size ("Signature size=4442"). Looking
    for "Signature=" alone took for unsigned whatever Apple or a Developer ID
    had signed: the toolchain's own libraries, which a build with
    CODE_SIGNING_ALLOWED=NO copies as they are, and the whole of a bundle signed
    for distribution, inside which no signature was then checked at all.
    """
    shown = subprocess.run(['codesign', '-dv', str(path)], capture_output=True, text=True)
    if shown.returncode != 0 or not re.search(r'^Signature(=| size=)', shown.stderr, re.M):
        return None
    return shown.stderr


def loadedFromBundle(path):
    """Names of the libraries `path` loads from beside itself, not from the macOS."""
    listing = subprocess.run(['otool', '-L', str(path)], capture_output=True, text=True).stdout
    names = set()
    for line in listing.split('\n'):
        if not line.startswith('\t'):
            continue
        reference = line.strip().rsplit(' (compatibility', 1)[0]
        if reference.startswith(('@rpath/', '@executable_path/', '@loader_path/')):
            names.add(reference.rsplit('/', 1)[1])
    return names


def audit(bundle, minimum, needs):
    """What is wrong in `bundle` for a product that starts at macOS `minimum`.

    `needs` is the policy's answer for that minimum: of the Swift libraries, the
    ones a macOS that old does not have. The result counts the Mach-O files,
    says whether their signatures were checked, and lists in words, each naming
    its file, what is unsigned, what is an orphan and what is missing; `carried`
    has, for each load the bundle does satisfy, the file that loads, the library
    and the file found.
    """
    # A bundle built with CODE_SIGNING_ALLOWED=NO is unsigned all the way through
    # on purpose, so there are no signatures to check inside it. The linker still
    # puts an ad hoc signature on the arm64 executable, so that is not a sign
    # that codesign ever ran. Orphans are checked either way: a file the current
    # build no longer produces is an orphan whether or not anything was signed,
    # and the Debug product is normally built unsigned by script/build_and_run.sh
    # -- which is exactly where the orphan this check was written for sat.
    outer = signature(bundle)
    signed = outer is not None and 'linker-signed' not in outer
    files = machOFiles(bundle)
    found = {'files': len(files), 'signed': signed,
             'unsigned': [], 'orphans': [], 'missing': [], 'carried': []}
    # otool lists a library's own name first, so what loads a library is asked
    # of every file but the library itself.
    loaded = set()
    for path in files:
        loaded |= loadedFromBundle(path) - {path.name}
    for path in files:
        if signed and signature(path) is None:
            found['unsigned'].append('%s is unsigned' % path.relative_to(bundle))
        if not swiftRuntime(path.name):
            continue
        # An embedded Swift library is back-deployment support. One for a macOS
        # this product no longer targets is, signed or not, left over from an
        # older deployment target: Xcode removes neither, and re-signs neither.
        # One the minimum does call for -- the library for Span, below macOS
        # 26 -- is there for the code that loads it, and is as much of a
        # leftover when no file in the bundle does.
        if not needs.get(path.name, False):
            found['orphans'].append('%s is a Swift runtime this product minimum does not need'
                                    % path.relative_to(bundle))
        elif path.name not in loaded:
            found['orphans'].append('%s is a Swift runtime nothing in the bundle loads'
                                    % path.relative_to(bundle))

    # The other way round: a Swift library the macOS of the minimum does not
    # have, and code in the bundle cannot start without, has to be in the
    # bundle, where that code looks for it. The macOS has the library for Span
    # in /usr/lib/swift from 26 on, so a build that stopped embedding it still
    # launches on the Mac that made it, passes every check of what the bundle
    # does hold, and does not launch on macOS 15.
    #
    # The policy's answer to "may the bundle carry it" is the answer here too.
    # It is yes exactly while the minimum is below the macOS that has the
    # library, and that is when a load of it finds nothing outside the bundle.
    # Where dyld looks is read from the binary: @loader_path is its folder,
    # @executable_path the folder of the executable of its process, and @rpath
    # each LC_RPATH folder of the binary and, for a library, of the executable
    # that loads it. A folder outside the bundle counts for nothing, whatever it
    # holds on this Mac: at this minimum the macOS does not have the library,
    # and a build directory is on one Mac only.
    whole = Path(os.path.realpath(bundle))
    application = executableOf(bundle)
    commands = {path: loadCommands(path) for path in files}

    def process(path):
        """The executable of the process the library `path` is loaded into."""
        for parent in path.parents:
            if parent == bundle:
                break
            if parent.suffix in ('.app', '.appex', '.xpc') and executableOf(parent):
                return executableOf(parent)
        return application

    def place(text, loader, executable):
        for prefix, folder in (('@loader_path', loader), ('@executable_path', executable)):
            if text == prefix or text.startswith(prefix + '/'):
                return folder / text[len(prefix) + 1:]
        return Path(text)

    def within(candidate):
        """`candidate` from the top of the bundle, or None when it is outside."""
        real = Path(os.path.realpath(candidate))
        return str(real.relative_to(whole)) if whole in real.parents else None

    for path in files:
        for cpu, isExecutable, loads, rpaths in commands[path]:
            executable = path if isExecutable else process(path)
            started = executable.parent if executable else bundle / 'Contents/MacOS'
            for command, reference in loads:
                name = reference.rsplit('/', 1)[-1]
                if command == 'LC_LOAD_WEAK_DYLIB' or not needs.get(name, False):
                    continue
                if reference.startswith('@rpath/'):
                    tail = reference[len('@rpath/'):]
                    places = [place(rpath, path.parent, started) / tail for rpath in rpaths]
                    if not isExecutable and executable is not None:
                        for otherCPU, _, _, others in commands.get(executable) or loadCommands(executable):
                            if otherCPU == cpu:
                                places += [place(rpath, started, started) / tail for rpath in others]
                else:
                    places = [place(reference, path.parent, started)]
                places = [candidate for candidate in places if within(candidate)]
                held = [candidate for candidate in places if candidate.is_file() and machO(candidate)]
                if held:
                    entry = (str(path.relative_to(bundle)), name, within(held[0]))
                    if entry not in found['carried']:
                        found['carried'].append(entry)
                    continue
                message = ('%s loads %s, which macOS %s does not have, and the bundle does not carry it '
                           'where that binary looks for it (%s): it does not start on macOS %s'
                           % (path.relative_to(bundle), reference, minimum,
                              ', '.join(sorted({within(candidate) for candidate in places}))
                              or 'nowhere inside the bundle', minimum))
                if message not in found['missing']:
                    found['missing'].append(message)
    return found


audited = []
for bundle in bundles:
    # Two of the three are called IsiX DICOM Viewer.app; name them by configuration.
    label = '%s/%s' % (bundle.parent.name, bundle.name)
    found = audit(bundle, productMinimum, minimumNeeds)
    audited.append((bundle, found))
    failures += ['%s: %s' % (label, message)
                 for message in found['unsigned'] + found['orphans'] + found['missing']]
    if found['files'] == 0:
        failures.append('%s: no Mach-O files found, so nothing was checked' % label)
    else:
        print('%s: %d Mach-O files, %d unsigned, %d orphaned Swift runtime, '
              '%d Swift runtime missing for macOS %s (%d loaded from the bundle)%s'
              % (label, found['files'], len(found['unsigned']), len(found['orphans']),
                 len(found['missing']), productMinimum, len(found['carried']),
                 '' if found['signed'] else ' (built without signing, signatures not checked)'))

# The rule about a missing library says nothing of a bundle that has everything,
# which is every bundle a working build leaves. So it is made to speak, each
# run, about bundles that lack something.
def expect(condition, what):
    if not condition:
        failures.append('control: ' + what)


def verdict(bundle, minimum, needs):
    """The libraries `bundle` is found to carry, and what it is refused for."""
    found = audit(bundle, minimum, needs)
    return sorted({entry[1] for entry in found['carried']}), found['missing'], found['orphans']


# The library the controls are about is one the policy lists that the macOS of
# the product minimum does not have. `later` is the macOS that has it, at which
# the same bundles are judged the other way round.
subject = next((name for name in sorted(listed) if minimumNeeds.get(name)), None)
if subject is None:
    print('macOS %s has every Swift library the policy lists, so no bundle can lack one'
          % productMinimum)
else:
    later = listed[subject]
    laterNeeds = askPolicy(asked, later)[2] or {}
    expect(laterNeeds.get(subject) is False,
           'the policy does not say that macOS %s has %s' % (later, subject))

    with tempfile.TemporaryDirectory(prefix='horos-signing-made-') as folder:
        # Bundles of one executable and at most two libraries, linked for this:
        # the verdict turns on how a load command is written, and the linker
        # writes it weak, through an rpath or with a path, as asked.
        folder = Path(folder)
        (folder / 'main.c').write_text('int main(void) { return 0; }\n')
        (folder / 'stub.c').write_text('int stub(void) { return 0; }\n')
        linked = []

        def link(output, arguments):
            output.parent.mkdir(parents=True, exist_ok=True)
            run = subprocess.run(['xcrun', 'clang', '-o', str(output)] + arguments,
                                 capture_output=True, text=True, cwd=str(folder))
            linked.append(run.returncode == 0)
            return str(output)

        byRpath = '@rpath/' + subject
        byPath = '@executable_path/../Elsewhere/' + subject
        libraries = {reference: link(folder / 'libraries' / folderName / subject,
                                     ['-dynamiclib', '-install_name', reference, 'stub.c'])
                     for folderName, reference in (('rpath', byRpath), ('path', byPath))}

        def made(case, reference, rpaths, holds=None, weak=False, through=False):
            """A bundle whose executable loads `reference` and searches `rpaths`,
            with the library in its folder `holds`. `through` puts a library of
            the bundle's own, with no rpath, between the executable and the load.
            A bundle is of use only if the load is written in it as asked."""
            bundle = folder / case / 'Made.app'
            contents = bundle / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Made'}))
            if holds:
                (contents / holds).mkdir(parents=True)
                shutil.copy(libraries[reference], str(contents / holds / subject))
            load = [('-Wl,-weak_library,' if weak else '') + libraries[reference]]
            loader = contents / 'MacOS/Made'
            if through:
                loader = contents / 'Frameworks/libmade.dylib'
                load = [link(loader, ['-dynamiclib', '-install_name', '@rpath/libmade.dylib', 'stub.c'] + load)]
            link(contents / 'MacOS/Made', ['main.c'] + load + ['-Wl,-rpath,' + rpath for rpath in rpaths])
            linked.append(('LC_LOAD_WEAK_DYLIB' if weak else 'LC_LOAD_DYLIB', reference)
                          in [written for cpu, isExecutable, loads, _ in loadCommands(loader)
                              for written in loads])
            return bundle

        frameworks = '@executable_path/../Frameworks'
        system = '/usr/lib/swift'
        carrying = made('carrying', byRpath, [system, frameworks], 'Frameworks')
        lacking = made('lacking', byRpath, [system, frameworks])
        weak = made('weak', byRpath, [system, frameworks], weak=True)
        unsearched = made('unsearched', byRpath, [system, frameworks], 'Elsewhere')
        searched = made('searched', byRpath, [system, '@loader_path/../Elsewhere'], 'Elsewhere')
        outside = made('outside', byRpath, [system, str(Path(libraries[byRpath]).parent)])
        pointed = made('pointed', byPath, [], 'Elsewhere')
        astray = made('astray', byPath, [frameworks], 'Frameworks')
        through = made('through', byRpath, [frameworks], 'Frameworks', through=True)
        throughLacking = made('through-lacking', byRpath, [frameworks], through=True)
        expect(all(linked), 'the bundles the rule about a missing library is tried on were not linked as asked')

        if all(linked):
            sound = len(failures)
            now = (productMinimum, minimumNeeds)
            judged = verdict(carrying, *now)
            expect(judged == ([subject], [], []),
                   'a bundle with %s where its executable looks is not passed: %s' % (subject, judged))
            judged = verdict(lacking, *now)
            expect(not judged[0] and len(judged[1]) == 1
                   and judged[1][0].startswith('Contents/MacOS/Made loads @rpath/%s, ' % subject)
                   and 'macOS %s' % productMinimum in judged[1][0]
                   and '(Contents/Frameworks/%s)' % subject in judged[1][0],
                   'a bundle without %s is not refused in the name of its executable, of the library '
                   'and of the minimum: %s' % (subject, judged))
            judged = verdict(weak, *now)
            expect(judged == ([], [], []),
                   'a weak load of an absent %s is taken for one the process needs: %s' % (subject, judged))
            judged = verdict(unsearched, *now)
            expect(not judged[0] and len(judged[1]) == 1,
                   'a %s in a folder its executable does not search is taken for found: %s' % (subject, judged))
            judged = verdict(searched, *now)
            expect(judged == ([subject], [], []),
                   'a %s in another folder its executable does search is not found: %s' % (subject, judged))
            judged = verdict(outside, *now)
            expect(not judged[0] and len(judged[1]) == 1 and 'nowhere inside the bundle' in judged[1][0],
                   'a %s that is only outside the bundle is taken for carried: %s' % (subject, judged))
            judged = verdict(pointed, *now)
            expect(judged == ([subject], [], []),
                   'a %s loaded by a path from the executable is not found: %s' % (subject, judged))
            judged = verdict(astray, *now)
            expect(not judged[0] and len(judged[1]) == 1
                   and '(Contents/Elsewhere/%s)' % subject in judged[1][0],
                   'a %s loaded by a path is looked for through the rpaths: %s' % (subject, judged))
            judged = verdict(through, *now)
            expect(judged == ([subject], [], []),
                   'a library is not given the rpaths of the executable that loads it: %s' % (judged,))
            judged = verdict(throughLacking, *now)
            expect(len(judged[1]) == 1 and judged[1][0].startswith('Contents/Frameworks/libmade.dylib loads '),
                   'a library of the bundle that loads an absent %s is not named: %s' % (subject, judged))
            # From the macOS that has the library on, the verdicts change sides:
            # nothing is missing, and the copy is the orphan it was before.
            judged = verdict(lacking, later, laterNeeds)
            expect(judged == ([], [], []),
                   'at macOS %s a bundle without %s is refused: %s' % (later, subject, judged))
            judged = verdict(carrying, later, laterNeeds)
            expect(not judged[0] and not judged[1] and len(judged[2]) == 1
                   and judged[2][0].startswith('Contents/Frameworks/%s is a Swift runtime this' % subject),
                   'at macOS %s the %s in a bundle is not an orphan: %s' % (later, subject, judged))
            if len(failures) == sound:
                print('bundles made for it: one without %s is refused at macOS %s unless the load is weak, '
                      'one with it is passed only where its executable looks, and neither is refused from '
                      'macOS %s on' % (subject, productMinimum, later))

    # And about the product itself: a clone of the first built bundle that
    # carries the library, judged as it is and then without it. A clone, because
    # nothing under build/ is this test's to alter.
    built = next(((bundle, found) for bundle, found in audited
                  if not found['missing'] and any(entry[1] == subject for entry in found['carried'])), None)
    if built is None:
        print('no built bundle loads %s from itself, so the rule was tried only on bundles made for it'
              % subject)
    else:
        bundle, original = built
        sound = len(failures)
        loaders =sorted({entry[0] for entry in original['carried'] if entry[1] == subject})
        copies = sorted({entry[2] for entry in original['carried'] if entry[1] == subject})
        with tempfile.TemporaryDirectory(prefix='horos-signing-clone-') as folder:
            clone = Path(folder) / bundle.name
            copied = subprocess.run(['cp', '-c', '-R', str(bundle), str(clone)], capture_output=True)
            expect(copied.returncode == 0, 'the clone of %s was not made' % bundle.name)
            if copied.returncode == 0:
                untouched = audit(clone, productMinimum, minimumNeeds)
                expect(untouched == original,
                       'the clone of %s is not judged as the bundle is: %s' % (bundle.name, untouched))
                judged = verdict(clone, later, laterNeeds)
                expect(not judged[1] and any(subject in message for message in judged[2]),
                       'at macOS %s the %s of %s is not an orphan: %s' % (later, subject, bundle.name, judged))
                for copy in copies:
                    (clone / copy).unlink()
                without = audit(clone, productMinimum, minimumNeeds)
                expect(len(without['missing']) == len(loaders)
                       and all(any(message.startswith(loader + ' loads ') and subject in message
                                   and 'macOS %s' % productMinimum in message
                                   for message in without['missing']) for loader in loaders),
                       'the clone of %s without %s is not refused for %s: %s'
                       % (bundle.name, subject, ', '.join(loaders), without['missing']))
                expect(without['orphans'] == original['orphans'] and without['unsigned'] == original['unsigned'],
                       'taking %s out of the clone of %s changed another verdict: %s'
                       % (subject, bundle.name, without))
                judged = verdict(clone, later, laterNeeds)
                expect(not judged[1],
                       'at macOS %s the clone of %s without %s is refused: %s'
                       % (later, bundle.name, subject, judged))
                if len(failures) == sound:
                    print('%s/%s: a clone without %s is refused at macOS %s for %s, and is not from macOS %s on'
                          % (bundle.parent.name, bundle.name, subject, productMinimum, ', '.join(loaders), later))

if failures:
    print('FAIL:')
    for f in failures:
        print(' ', f)
    sys.exit(1)

# 5. And the override has to actually reach the build settings, both ways.
def resolved(extra=None, local=None):
    path = root / 'Config.local.xcconfig'
    wrote = False
    try:
        if local is not None:
            path.write_text('HOROS_DEVELOPMENT_TEAM = %s\n' % local)
            wrote = True
        command = ['xcodebuild', '-project', str(root / 'Horos.xcodeproj'), '-target', 'Horos',
                   '-configuration', 'Debug', '-showBuildSettings']
        if extra:
            command.append(extra)
        out = subprocess.run(command, capture_output=True, text=True, cwd=str(root)).stdout
        found = re.search(r'^\s+DEVELOPMENT_TEAM = (.*)$', out, re.M)
        return found.group(1).strip() if found else ''
    finally:
        if wrote:
            path.unlink()

if (root / 'Config.local.xcconfig').exists():
    print('SKIP: a Config.local.xcconfig is present; not disturbing it')
else:
    default, command_line, from_file = resolved(), resolved('HOROS_DEVELOPMENT_TEAM=ABCDE12345'), resolved(local='FGHIJ67890')
    if default:
        print('FAIL: a checkout with no override resolves a team: %r' % default); sys.exit(1)
    if command_line != 'ABCDE12345':
        print('FAIL: the command line override did not reach the build: %r' % command_line); sys.exit(1)
    if from_file != 'FGHIJ67890':
        print('FAIL: Config.local.xcconfig did not reach the build: %r' % from_file); sys.exit(1)

print('PASS: no team identifier is committed, the default resolves empty, both the command '
      'line and the untracked local config reach DEVELOPMENT_TEAM, and every executable in '
      'the bundles that exist is signed and finds in its bundle the Swift libraries the '
      'macOS of the product minimum does not have')
