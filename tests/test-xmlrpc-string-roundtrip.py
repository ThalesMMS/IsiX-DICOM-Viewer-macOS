#!/usr/bin/env python3
"""#592: production Core Data attributes + N2XMLRPC round-trip via Python's client.

Compile the complete serializer and its real string/data/date dependencies, with
no framework or fixture prerequisites. Neither escaping nor parsing is mocked.

N2XMLRPC and the NSString, NSMutableString and NSData categories it uses are
Swift since #710: their sources are compiled with the driver, under a bridging
header that defines HOROS_BRIDGING_HEADER as the application's does, and the C
functions that stayed Objective-C++ (NSString+N2+CAPI.mm, NSData+N2+CAPI.mm)
are compiled from source beside them.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import xmlrpc.client

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--attribute-source', type=Path,
                    default=ROOT / 'Horos/Sources/XMLRPCOwnedThreadRead.swift')
args = parser.parse_args()
VALUES = ['', 'plain', 'a <b> & c', '\'quoted\' "double"', 'é João Тест 🩻',
          'literal &amp; &lt; &#39; &quot;', '  leading\tand\ntrailing  ']
SHIM = '''#import "Shim.h"
#import "N2XMLRPC.h"
NSString *ProbeResponse(id value, NSUInteger options) {
    return [N2XMLRPC responseWithValue:value options:options];
}
NSString *ProbeRequest(NSString *method, NSArray *arguments) {
    return [N2XMLRPC requestWithMethodName:method arguments:arguments];
}
id ProbeParse(NSString *xml) {
    NSXMLDocument *document = [[[NSXMLDocument alloc] initWithXMLString:xml options:0 error:NULL] autorelease];
    NSXMLNode *value = [[document nodesForXPath:@"*/params/param/value" error:NULL] firstObject];
    return value ? [N2XMLRPC ParseElement:value] : nil;
}
'''
HEADER = '''#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
NSString *ProbeResponse(id value, NSUInteger options);
NSString *ProbeRequest(NSString *method, NSArray *arguments);
id ProbeParse(NSString *xml);
#ifdef __cplusplus
}
#endif
'''
DRIVER = r'''
import Foundation
import CoreData
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let values = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("values.json"))) as! [String]
let model = NSManagedObjectModel()
let entity = NSEntityDescription()
entity.name = "Probe"
entity.managedObjectClassName = "NSManagedObject"
var attributes: [NSAttributeDescription] = values.indices.map {
    let attribute = NSAttributeDescription()
    attribute.name = "case\($0)"
    attribute.attributeType = .stringAttributeType
    return attribute
}
let thumbnail = NSAttributeDescription()
thumbnail.name = "thumbnail"
thumbnail.attributeType = .binaryDataAttributeType
attributes.append(thumbnail)
entity.properties = attributes
model.entities = [entity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
let object = NSManagedObject(entity: entity, insertInto: context)
for (index, value) in values.enumerated() { object.setValue(value, forKey: "case\(index)") }
object.setValue(Data([1, 2, 3]), forKey: "thumbnail")
let attributesOnWire = XMLRPCOwnedThreadRead.dictionary(for: object)
precondition(attributesOnWire["thumbnail"] == nil)
let record: [String: Any] = ["record": attributesOnWire,
                           "nested<&": ["literal&key;": values],
                           "number": 7, "flag": true]
for option in 0...1 {
    let xml = ProbeResponse(record, UInt(option))!
    try xml.write(to: folder.appendingPathComponent("response\(option).xml"), atomically: true, encoding: .utf8)
    guard let decoded = ProbeParse(xml) as? [String: Any] else {
        fatalError("N2XMLRPC generated malformed XML for nested string keys")
    }
    try JSONSerialization.data(withJSONObject: decoded).write(to: folder.appendingPathComponent("native\(option).json"))
}
let request = ProbeRequest("literal<&method", [record])!
try request.write(to: folder.appendingPathComponent("request.xml"), atomically: true, encoding: .utf8)
let external = try String(contentsOf: folder.appendingPathComponent("external.xml"), encoding: .utf8)
let decoded = ProbeParse(external) as! [String: Any]
try JSONSerialization.data(withJSONObject: decoded).write(to: folder.appendingPathComponent("external.json"))
'''

with tempfile.TemporaryDirectory(prefix='horos-xmlrpc-roundtrip-') as temporary:
    work = Path(temporary)
    (work / 'Shim.h').write_text(HEADER)
    (work / 'Shim.mm').write_text(SHIM)
    (work / 'main.swift').write_text(DRIVER)
    (work / 'values.json').write_text(json.dumps(VALUES))
    expected = {'record': {f'case{i}': value for i, value in enumerate(VALUES)},
                'nested<&': {'literal&key;': VALUES}, 'number': 7, 'flag': True}
    (work / 'external.xml').write_text(xmlrpc.client.dumps((expected,), methodname='Probe', allow_none=True))
    sources = [ROOT / 'Nitrogen/Sources' / name for name in ('NSString+N2+CAPI.mm', 'NSData+N2+CAPI.mm')]
    sources += [ROOT / 'Horos/Sources/HorosObjCException.m', work / 'Shim.mm']
    swift_sources = [ROOT / 'Nitrogen/Sources' / name for name in
                     ('N2XMLRPC.swift', 'NSString+N2.swift', 'NSData+N2.swift', 'NSMutableString+N2.swift')]
    (work / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                     '#import "N2Debug.h"\n#import "N2XMLRPC.h"\n#import "NSString+N2.h"\n'
                                     '#import "NSData+N2.h"\n#import "NSMutableString+N2.h"\n'
                                     '#import "HorosObjCException.h"\n#import "Shim.h"\n')
    objects = []
    for source in sources:
        output = work / (source.stem + '.o')
        subprocess.run(['xcrun', 'clang++' if source.suffix == '.mm' else 'clang',
                        '-c', '-w', '-fno-objc-arc', '-I' + str(ROOT / 'Nitrogen/Sources'),
                        '-I' + str(ROOT / 'Horos/Sources'),
                        # The C parts sit beside the Swift, as in the application:
                        # their headers then name the classes instead of importing
                        # the generated interface. The shim uses the interface
                        # N2XMLRPC.h declares without Swift.
                        *([] if source.name == 'Shim.mm' else ['-DHOROS_BRIDGING_HEADER=1']),
                        str(source), '-o', str(output)], check=True)
        objects.append(str(output))
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(work / 'Bridging.h'),
                    '-I', str(ROOT / 'Nitrogen/Sources'), '-I', str(ROOT / 'Horos/Sources'), '-I', str(work),
                    *map(str, swift_sources), str(args.attribute_source), str(work / 'main.swift'),
                    *objects, '-framework', 'Cocoa', '-lc++', '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe'), str(work)], check=True)
    for option in (0, 1):
        decoded, method = xmlrpc.client.loads((work / f'response{option}.xml').read_text())
        assert decoded == (expected,) and method is None, (option, decoded, expected)
        assert json.loads((work / f'native{option}.json').read_text()) == expected
    decoded, method = xmlrpc.client.loads((work / 'request.xml').read_text())
    assert decoded == (expected,) and method == 'literal<&method'
    assert json.loads((work / 'external.json').read_text()) == expected
print('PASS: real Core Data/N2XMLRPC/Python round-trip, typed/untyped strings, nested keys, '
      'literal entities, Unicode and controls; binary attributes excluded')
