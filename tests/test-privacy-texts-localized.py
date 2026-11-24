#!/usr/bin/env python3
"""What the system shows when it asks for a permission, and where the application says the permission is given.

The requests of the system for Automation, the local network and removable
volumes show the reason Info.plist gives; it was in English in every language.
The texts of the application that send the user to System Settings named it, in
some catalogs, by words the system does not use, so the user looked for a
window that has another name.

The names below are the ones macOS gives System Settings, Privacy & Security
and Automation in each language of the catalogs.
"""
from pathlib import Path
import json, plistlib, re, subprocess, sys

root = Path(__file__).resolve().parents[1]
failures = []

REASONS = ('NSAppleEventsUsageDescription', 'NSLocalNetworkUsageDescription', 'NSRemovableVolumesUsageDescription')
with open(root / 'Horos/Info.plist', 'rb') as handle:
    english = plistlib.load(handle)
for key in REASONS:
    if 'IsiX DICOM Viewer' not in english.get(key, ''):
        failures.append('Info.plist gives no reason for %s' % key)

catalogs = sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings'))
for catalog in catalogs:
    language = catalog.parent.name
    strings = catalog.with_name('InfoPlist.strings')
    converted = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(strings)], capture_output=True, text=True)
    reasons = json.loads(converted.stdout) if converted.returncode == 0 else {}
    for key in REASONS:
        text = reasons.get(key, '')
        if 'IsiX DICOM Viewer' not in text:
            failures.append('%s gives no reason for %s' % (language, key))
        elif language == 'en.lproj' and text != english.get(key):
            failures.append('%s: the English reason for %s is not the one of Info.plist' % (language, key))
        elif language != 'en.lproj' and text == english.get(key):
            failures.append('%s gives the reason for %s in English' % (language, key))

# System Settings, Privacy & Security, Automation; a language that declines the first lists its forms.
NAMES = {
    'ar': (('إعدادات النظام',), 'الخصوصية والأمن', 'التحكم التلقائي'),
    'de': (('Systemeinstellungen',), 'Datenschutz & Sicherheit', 'Automation'),
    'es': (('Ajustes del Sistema',), 'Privacidad y seguridad', 'Automatización'),
    'fr': (('Réglages Système',), 'Confidentialité et sécurité', 'Automatisation'),
    'hi': (('सिस्टम सेटिंग',), 'गोपनीयता और सुरक्षा', 'ऑटोमेशन'),
    'it-IT': (('Impostazioni di Sistema',), 'Privacy e sicurezza', 'Automazione'),
    'ja-JP': (('システム設定',), 'プライバシーとセキュリティ', 'オートメーション'),
    'ko': (('시스템 설정',), '개인정보 보호 및 보안', '자동화'),
    'pt-BR': (('Ajustes do Sistema',), 'Privacidade e Segurança', 'Automação'),
    'ru': (('Системные настройки', 'Системных настройках'), 'Конфиденциальность и безопасность', 'Автоматизация'),
    # The pane is 隐私与安全性 up to macOS 15 and 隐私与安全 from macOS 26: the first holds both.
    'zh-Hans': (('系统设置',), '隐私与安全', '自动化'),
}
ROW = re.compile(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', re.M)
checked = 0
for catalog in catalogs:
    language = catalog.parent.name[:-len('.lproj')]
    if language == 'en':
        continue
    if language not in NAMES:
        failures.append('%s has no names of System Settings to compare with' % language)
        continue
    settings, privacy, automation = NAMES[language]
    raw = catalog.read_bytes()
    text = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
    for key, value in ROW.findall(text):
        if 'System Settings' not in key:
            continue
        checked += 1
        if not any(name in value for name in settings):
            failures.append('%s names System Settings otherwise: %s' % (language, value[:90]))
        if 'Privacy & Security' in key and privacy not in value:
            failures.append('%s names Privacy & Security otherwise: %s' % (language, value[:90]))
        if '> Automation' in key and automation not in value:
            failures.append('%s names Automation otherwise: %s' % (language, value[:90]))
        # The Hindi catalog wrote the plural the system does not use.
        if language == 'hi' and 'सिस्टम सेटिंग्स' in value:
            failures.append('hi names System Settings otherwise: %s' % value[:90])
if checked < 11 * 11:
    failures.append('only %d texts that name System Settings were found in the catalogs' % checked)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: the three reasons the system shows are in %d languages, and %d texts name System Settings as the system does'
      % (len(catalogs), checked))
