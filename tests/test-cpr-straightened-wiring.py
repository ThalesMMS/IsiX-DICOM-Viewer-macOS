#!/usr/bin/env python3
"""Straightened CPR after a centerline is gated in Swift and does not block drawRect."""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path
failures = []


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


def check(condition, message):
    if not condition:
        failures.append(message)


swift = (root / 'Horos/Sources/CPRStraightenedGeneration.swift').read_text(encoding='utf-8')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
# CPRStraightenedView is Swift since #824.
view = source_path('CPRStraightenedView')
generator = source_path('CPRGenerator')
# CPRController is Swift since #825.
controller = source_path('CPRController')
# CPRView is Swift since #825.
wrapper = source_path('CPRView')
path = (root / 'Horos/Sources/CurvedMPRPath.swift').read_text(encoding='utf-8')

check('HorosCPRStraightenedSession' in swift, 'Swift helper must stay @objc HorosCPRStraightenedSession')
check('beginGenerationWithPixelsWide:' in swift, 'generation starts through the Swift session')
check('self-intersecting loop' in swift, 'loops are a named recoverable diagnosis')
check('curve too short' in swift, 'short curves are a named recoverable diagnosis')
check('generation cancelled; markings kept' in swift, 'cancel keeps the red-point markings')
check('CPRStraightenedGeneration.swift in Sources' in pbx, 'the helper must be in the Horos target')
check('class CurvedMPRPathSession' in path, 'the #31 drawing session stays')

send = body(view, 'private dynamic func _sendNewRequest()')
check('CPRStraightenedSession' in send or 'horosStraightenedSession()' in send,
      '_sendNewRequest must consult the Swift generation gate')
check('beginGeneration(pixelsWide:' in send, '_sendNewRequest must begin through Swift')
check('synchronousRequestVolume' not in send,
      'drawRect must not wait on synchronousRequestVolume after the centerline')
check('runUntilAllRequestsAreFinished' not in send,
      'drawRect must not spin the generator run loop after the centerline')
check('requestVolume(request)' in send, 'valid curves still request an asynchronous straightened volume')

abandon = body(view, 'func generator(_ generator: CPRGenerator, didAbandonRequest request: CPRGeneratorRequest)')
check('curvedPath' not in abandon or 'clearPath' not in abandon,
      'abandoning a request must not clear the centerline')

cancel_view = body(view, 'func cancelStraightenedGeneration()')
check('cancelOutstandingRequests' in cancel_view, 'Escape cancel must cancel in-flight fill operations')
check('.cancel' in cancel_view or 'cancel]' in cancel_view, 'the Swift session cancel must run')
check('clearPath' not in cancel_view, 'cancel must keep the red-point markings')
check('setVolumeData' not in cancel_view and 'volumeData =' not in cancel_view,
      'cancel must not replace the original volume')

gen_cancel = body(generator, 'func cancelOutstandingRequests()' if generator.suffix == '.swift' else '- (void)cancelOutstandingRequests')
check('isExecuting' in gen_cancel or 'cancel]' in gen_cancel or '.cancel()' in gen_cancel,
      'the generator must cancel running straightened operations, not only queued ones')

key = body(controller, 'func keyDown(with theEvent: NSEvent)')
check('cancelStraightenedGeneration' in key, 'Escape must cancel a long straightened generation')

wrapper_cancel = body(wrapper, 'func cancelStraightenedGeneration()')
check('_straightenedView' in wrapper_cancel, 'CPRView must forward cancel to the straightened view')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: straightened generation is gated, async, and cancellable without dropping markings')
