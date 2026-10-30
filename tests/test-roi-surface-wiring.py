#!/usr/bin/env python3
"""ROI volume reconstruction asks Swift before VTK and the radio stores tags."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def strip(text):
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def body(source, signature):
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


# ROIVolumeView is Swift: the surface comes from its generateActor(for:...).
view = (root / 'Horos/Sources/ROIVolumeView.swift').read_text(encoding='utf-8')
live = strip(view)
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
helper = root / 'Horos/Sources/ROISurfaceAlgorithm.swift'

if not helper.is_file():
    failures.append('Horos/Sources/ROISurfaceAlgorithm.swift is missing')
if 'ROISurfaceAlgorithm.swift' not in project:
    failures.append('project.pbxproj does not compile ROISurfaceAlgorithm.swift')
mapper = body(live, 'static func generateActor(')
if not mapper:
    failures.append('generateActor(for:...) is gone')
else:
    resolve_at = mapper.find('ROISurfaceAlgorithm.resolvePreference(')
    reason_at = mapper.find('ROISurfaceAlgorithm.unavailabilityReason(')
    consulted = max(resolve_at, reason_at)
    switch_at = mapper.find('switch')
    if consulted < 0:
        failures.append('generateActor(for:...) does not consult ROISurfaceAlgorithm before VTK')
    elif switch_at < 0 or consulted > switch_at:
        failures.append('generateActor(for:...) must resolve the preference before the VTK switch')
    if 'return nil' not in mapper:
        failures.append('an unavailable algorithm must return nil instead of running Iso Contour')
    default = body(mapper, 'default:')
    if default and 'isoContourActor' in default:
        failures.append('the default arm still runs Iso Contour, so Power Crust is silently remapped')

for match in re.finditer(r'set\(0,\s*forKey:\s*"UseDelaunayFor3DRoi"\)', view):
    window = view[max(0, match.start() - 280):match.start()]
    if 'shouldRewritePreference(afterFailure:' not in window:
        failures.append('a catch still rewrites UseDelaunayFor3DRoi to Iso without asking Swift')

for locale in ('en', 'ja-JP'):
    xib = (root / f'Horos/Resources/{locale}.lproj/ROIVolume.xib').read_text(encoding='utf-8')
    if 'name="selectedTag" keyPath="values.UseDelaunayFor3DRoi"' not in xib:
        failures.append(f'{locale} ROIVolume.xib radio does not bind selectedTag to UseDelaunayFor3DRoi')
    if 'name="selectedIndex" keyPath="values.UseDelaunayFor3DRoi"' in xib:
        failures.append(f'{locale} ROIVolume.xib still binds selectedIndex, so Power Crust writes 0')
    for title, tag in (('Power Crust', '2'), ('Delaunay', '1'), ('Iso Contour', '0')):
        cell = re.search(
            r'<buttonCell type="radio" title="%s"[^>]*>' % re.escape(title), xib)
        if not cell:
            failures.append(f'{locale} ROIVolume.xib is missing the {title} radio')
        elif f'tag="{tag}"' not in cell.group(0):
            failures.append(f'{locale} {title} radio does not have tag="{tag}"')

if failures:
    print('FAIL:', *failures, sep='\n', file=sys.stderr)
    sys.exit(1)
print('PASS: generateActor asks Swift first; radio stores tags; failure does not rewrite Iso')
