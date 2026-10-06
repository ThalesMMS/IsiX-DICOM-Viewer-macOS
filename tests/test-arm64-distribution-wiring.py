#!/usr/bin/env python3
"""arm64-only publication is declared, plugins are diagnosed before load, helpers are not Rosetta."""
from pathlib import Path
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

check('ARCHS = arm64' in config, 'Config.xcconfig must keep ARCHS = arm64')
check('EXCLUDED_ARCHS[sdk=macosx*] = x86_64 i386 ppc ppc64' in config,
      'Config.xcconfig must exclude Intel and PowerPC slices')
check('arm64 or x86_64' not in config, 'Config.xcconfig must not promise an Intel product')
check('Apple Silicon only' in config or 'arm64-only' in config.lower() or 'Apple Silicon' in config,
      'Config.xcconfig must say the product is Apple Silicon')
check('MACOSX_DEPLOYMENT_TARGET = 26.0' in config,
      'deployment target must match the macOS 26 minimum')
check('DEVELOPMENT_TEAM = TPT6TVH8UY' not in config,
      'do not copy the donor DEVELOPMENT_TEAM')

check('@objc(HorosArchitectureAudit)' in swift, 'Swift auditor must stay @objc')
check('pluginDiagnosisAtPath:' in swift, 'plugins are diagnosed by path')
check('helperDiagnosisAtPath:' in swift, 'helpers are diagnosed by path')
check('not launched under Rosetta' in swift, 'Intel helpers must not use Rosetta as the product path')
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
print('PASS: arm64-only Config, plugin diagnosis before load, validator command kept')
