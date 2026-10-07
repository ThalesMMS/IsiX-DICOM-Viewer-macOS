#!/usr/bin/env python3
"""Two single-slice packages are wired: arm64 by default, x86_64 by choice per release build.

Config.xcconfig keeps arm64 as the default and no longer excludes x86_64; the
release script builds the slice it is asked for and audits that only it is
present; the development and App Store builds stay arm64. Plugins and helpers
are diagnosed against the slice of the running process before they are loaded
or launched.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(path, signature):
    source = path.read_bytes().decode('latin1')
    at = 0
    while True:
        at = source.find(signature, at)
        if at < 0:
            return ''
        brace = source.find('{', at)
        semi = source.find(';', at)
        if brace >= 0 and (semi < 0 or brace < semi):
            break
        at += len(signature)
    depth, index = 0, brace
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
        index += 1
    return ''


config = (root / 'Config.xcconfig').read_text(encoding='utf-8')
swift = (root / 'Horos/Sources/HorosArchitectureAudit.swift').read_text(encoding='utf-8')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
manager = source_path('PluginManager')  # Swift
xml = source_path('XMLController')  # Swift

release = (root / 'script/build_release.sh').read_text(encoding='utf-8')
development = (root / 'script/build_and_run.sh').read_text(encoding='utf-8')
appstore = (root / 'script/build_appstore.sh').read_text(encoding='utf-8')

check(re.search(r'^ARCHS = arm64$', config, re.M) is not None, 'Config.xcconfig must keep ARCHS = arm64 as the default')
check(re.search(r'^EXCLUDED_ARCHS\[sdk=macosx\*\] = i386 ppc ppc64$', config, re.M) is not None,
      'Config.xcconfig must exclude only i386 and PowerPC, so a release build may choose x86_64')
check('Apple Silicon only' not in config, 'Config.xcconfig must not say the product is Apple Silicon only')
check('x86_64' in config and 'HOROS_RELEASE_ARCH' in config and 'universal' in config.lower(),
      'Config.xcconfig must explain the separate x86_64 package and the absence of a universal one')
check('MACOSX_DEPLOYMENT_TARGET = 26.0' in config,
      'deployment target must match the macOS 26 minimum')
check('DEVELOPMENT_TEAM = TPT6TVH8UY' not in config,
      'do not copy the donor DEVELOPMENT_TEAM')

# The release script chooses one slice per build, arm64 by default.
check('HOROS_RELEASE_ARCH:-arm64' in release, 'build_release.sh must default to arm64')
check(re.search(r'arm64\|x86_64\)', release) is not None, 'build_release.sh must accept only arm64 or x86_64')
check('ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO' in release, 'build_release.sh must pass the chosen slice to xcodebuild')
check('ARCHS=arm64' not in release, 'build_release.sh must not fix ARCHS=arm64')
check('--expect-arch "$ARCH"' in release, 'the package audit must expect the chosen slice')
check('build/Release/$ARCH' in release or '/Release/$ARCH' in release, 'each slice must have its own output folder')
check('release-audit-$ARCH.json' in release, 'the audit report must carry the slice')
check('build-release-$ARCH.log' in release and 'release-signing-$ARCH.log' in release,
      'the build and signing logs must carry the slice')
check('build/$ARCH' in release, 'the x86_64 build must keep its own derived data, dependencies included')
check('canal App Store' in release, 'build_release.sh must refuse an x86_64 App Store build')
# Development and App Store builds stay arm64.
check('ARCHS=' not in development and 'HOROS_RELEASE_ARCH' not in development,
      'build_and_run.sh must keep the arm64 default of Config.xcconfig')
check('ARCHS=arm64 ONLY_ACTIVE_ARCH=YES' in appstore, 'build_appstore.sh must keep its arm64 archive')

check('@objc(HorosArchitectureAudit)' in swift, 'Swift auditor must stay @objc')
check('pluginDiagnosisAtPath:' in swift, 'plugins are diagnosed by path')
check('helperDiagnosisAtPath:' in swift, 'helpers are diagnosed by path')
check('not launched under Rosetta' in swift, 'Intel helpers must not use Rosetta as the product path')
check('#if arch(arm64)' in swift and '#elseif arch(x86_64)' in swift,
      'the auditor must take the slice of the running process')
check('excludedSlices = ["i386", "ppc", "ppc64"]' in swift, 'only i386 and PowerPC are excluded slices')
check('HorosArchitectureAudit.swift in Sources' in pbx, 'auditor must be in the Horos target')

load = body(manager, 'class func loadPluginBundle(_ path: String!)')
check('HorosArchitectureAudit.pluginDiagnosis(at:' in load, 'loadPluginBundle must consult HorosArchitectureAudit before NSBundle')
bundle_at = load.find('Bundle(path:')
diag_at = load.find('pluginDiagnosis(at:')
check(diag_at >= 0 and (bundle_at < 0 or diag_at < bundle_at),
      'Intel-only plugins must be named before NSBundle opens them')
check('Incompatible' in load, 'Intel-only plugins remain Incompatible, not silently skipped')

install = body(manager, 'class func installPlugin(fromPath path: String!)')
check('HorosArchitectureAudit.pluginDiagnosis(at:' in install, 'install must refuse Intel-only plugins before touching the install')
# -preflightAndReturnError: is sent by PluginManagerCAPIPreflightBundle (PluginManager+CAPI.m).
preflight_at = install.find('PluginManagerCAPIPreflightBundle(')
install_diag = install.find('pluginDiagnosis(at:')
check(install_diag >= 0 and (preflight_at < 0 or install_diag < preflight_at),
      'install must diagnose architecture before NSBundle preflight')

verify = body(xml, 'public func verify(_ sender: Any?)')
check('helperDiagnosis(at:' in verify, 'DICOM validator must consult helperDiagnosis before launch')
task_at = verify.find('HorosRunBoundedTask')
help_at = verify.find('helperDiagnosis(at:')
check(help_at >= 0 and (task_at < 0 or help_at < task_at),
      'do not launch an Intel leftover under Rosetta; diagnose first')
check('dciodvfy' in verify, 'the validator command must remain; do not delete it to pass the audit')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: arm64 default and x86_64 by release build, one slice audited per package, plugin diagnosis before load, validator command kept')
