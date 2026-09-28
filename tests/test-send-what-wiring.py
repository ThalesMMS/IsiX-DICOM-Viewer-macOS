#!/usr/bin/env python3
"""SendController asks Swift before the radio, and SC is not Key Images."""
from pathlib import Path
import re
import sys
from sources import is_swift, source_text

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


def check(condition, message):
    if not condition:
        failures.append(message)


project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
helper = root / 'Horos/Sources/SendWhatFilter.swift'
# SendController is Swift since #716.
source = source_text('SendController')
live = strip(source)
send_xib = (root / 'Horos/Resources/en.lproj/Send.xib').read_text(encoding='utf-8')

check(helper.is_file(), 'Horos/Sources/SendWhatFilter.swift is missing')
check('SendWhatFilter.swift' in project, 'project.pbxproj does not list SendWhatFilter.swift')
check('SendWhatFilter.swift in Sources' in project,
      'SendWhatFilter.swift is not in a Sources build phase')
# Swift in the Horos module sees SendWhatFilter without Horos-Swift.h.
check(is_swift('SendController'), 'SendController is expected in Swift since #716')

init_body = body(live, 'init(files: [Any]!)')
check(init_body, 'initWithFiles: is missing')
check('SendWhatFilter.resolvedIndex(' in init_body,
      'initWithFiles: must resolve lastSendWhat through HorosSendWhatFilter')
check('hasKeyImages' in init_body and 'hasSecondaryCapturesImages' in init_body,
      'initWithFiles: must pass both availability flags to the helper')
check('_keyImageIndex == 1 && self.hasSecondaryCapturesImages() == false' not in source
      and '_keyImageIndex == 1 && !self.hasSecondaryCapturesImages()' not in source,
      'SC must not recede with the Key Images index')

end_body = body(live, 'func endSelectServer(_ sender: Any!)')
check(end_body, 'endSelectServer: is missing')
check('_keyImageIndex == 1' in end_body, 'endSelectServer: must still filter key images at 1')
check('_keyImageIndex == 2' in end_body, 'endSelectServer: must still filter SC at 2')
check('isKeyImage == YES' in end_body, 'key-image filter must stay isKeyImage')
check('modality CONTAINS[c]' in end_body, 'SC filter must stay modality CONTAINS SC')

check('tag="1"' in send_xib and 'tag="2"' in send_xib,
      'Send.xib must keep Key Images tag 1 and Secondary Capture tag 2')
check('Only key images' in send_xib and 'Only Secondary Captures' in send_xib,
      'Send.xib radio labels must stay')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: send what wiring resolves SC as 2, not as Key Images')
