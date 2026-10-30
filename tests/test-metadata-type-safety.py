#!/usr/bin/env python3
"""Metadata under the wrong value representation was asked for a number.

A DICOM parser gives back a value whose class follows the value representation
the file declares. Asked through the framework the application uses, an object
whose window centre and width are stored as `OB` answers:

    control.dcm
      WindowCenter               NSTaggedPointerString  floatValue=yes
    window-as-bytes.dcm
      WindowCenter               NSConcreteMutableData  floatValue=NO
    geometry-as-bytes.dcm
      ImagePositionPatient       NSConcreteMutableData  floatValue=NO  array[0]=NSConcreteMutableData

`-[DCMPix loadDICOMWithDCMTK]` and the three group loaders beneath it read
thirty attributes as `[[dcmObject attributeValueWithName:@"…"] floatValue]` and
eight more out of arrays. Sending `floatValue` to NSData is an unrecognised
selector: the process dies, and the log the reports carry - `initWithString:nil`,
NSMutableData receiving floatValue - names no attribute.

Every one of those reads now goes through a guard that answers only when the
value can answer for a number, and names the file and the attribute when it
cannot. The attribute is then treated as absent rather than as zero-by-accident.

The reading and its guards are now the IsiXImaging module's
(AttributeValueCoercion, ImageAttributeReader); what is left of DCMPix.m must
still not ask a value for a number around them.
"""
from pathlib import Path
import re
import sys
from sources import class_text

root = Path(__file__).resolve().parents[1]
failures = []
pix = class_text('DCMPix')
code = re.sub(r'//[^\n]*', '', pix)


def body(signature, source):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
        index += 1
    return ''


module = root / 'Modules/IsiXImaging/Sources'
guards = re.sub(r'//[^\n]*', '', (module / 'AttributeValueCoercion.swift').read_text())
reader = re.sub(r'//[^\n]*', '', (module / 'ImageAttributeReader.swift').read_text())


def swift_body(signature, source):
    at = source.find(signature)
    return body(signature, source) if at >= 0 else ''


# --- the guards exist and say what went wrong ---------------------------------
for name, asks in (('static func numberValue(', 'responds(to:'), ('static func number(in values:', 'as? NSNumber')):
    guard = swift_body(name, guards)
    if not guard:
        failures.append('%s is gone, so a value that is not a number is asked for one' % name)
        continue
    if asks not in guard:
        failures.append('%s does not ask whether the value can answer for a number' % name)
    if 'className(' not in guard or 'NSLog' not in guard:
        failures.append('%s does not name what the value actually is' % name)
if 'NSStringFromClass' not in guards:
    failures.append('a refused value is not named by its class')

# --- and nothing reads a number around them -----------------------------------
direct = re.findall(r'\[\[dcmObject attributeValueWithName:@"[A-Za-z0-9]+"\] '
                    r'(?:floatValue|intValue|doubleValue|longValue|integerValue|longLongValue)\]',
                    code)
if direct:
    failures.append('%d attribute(s) are still asked for a number without a guard, starting with '
                    '%s' % (len(direct), direct[0]))

# The group loaders are where the geometry comes from.
for signature, attributes in (
        ('public mutating func readPlane(from item:', ('ImagePositionPatient', 'ImageOrientationPatient')),
        ('public mutating func readPixelDescription(from item:', ('PixelSpacing',))):
    loader = swift_body(signature, reader)
    if not loader:
        failures.append('%s is gone' % signature)
        continue
    if 'Values.number(in:' not in loader and 'readSpacing(' not in loader and 'readCosines(' not in loader:
        failures.append('%s still reads its arrays without a guard' % signature)
    for attribute in attributes:
        if attribute not in loader:
            failures.append('%s no longer reads %s' % (signature, attribute))
for helper in ('mutating func readSpacing(', 'mutating func readCosines('):
    if 'AttributeValueCoercion.number(in:' not in swift_body(helper, reader):
        failures.append('%s reads its values without a guard' % helper)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a metadata value is asked for a number only when it can answer for one, and is named '
      'when it cannot')
