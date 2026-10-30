#!/usr/bin/env python3
"""Exercise the real sender negotiation with SEG, duplicates and full budgets.

The plan of a send's presentation contexts is IsiXDICOMNetwork's
StoragePresentationPlan; it is compiled here as it is, and its contexts go
through DCMTK's ASC_addPresentationContext the way the adapter adds them, so
that a plan DCMTK would refuse fails here. Its equivalence with the
Objective-C++ it replaced is tests/test-store-rules-equivalence.py.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from dcmtk_build import ROOT, dcmtk_flags

MODULE = ROOT / 'Modules/IsiXDICOMNetwork/Sources'
DRIVER = r'''
import Foundation

let SEG = "1.2.840.10008.5.1.4.1.1.66.4"
var out: [String] = []
for n in [1, 64, 65, 128, 129] {
    for combine in [false, true] {
        for preferred in [TransferSyntaxUID.explicitLittleEndian, TransferSyntaxUID.implicitLittleEndian] {
            var classes = [SEG, SEG]
            for i in 1..<n { classes.append("1.2.826.0.1.3680043.8.498.371.\(i)") }
            let original = classes
            let result = StoragePresentationPlan.contexts(preferredTransferSyntax: preferred, required: classes,
                                                          optional: (1...200).map { "1.2.3.\($0)" },
                                                          combineTransferSyntaxes: combine)
            precondition(classes == original)
            switch result {
            case .failure:
                precondition(n > 128, "\(n) classes refused")
                out.append("\(n) refused")
            case .success(let contexts):
                precondition(n <= 128, "\(n) classes accepted")
                precondition(contexts.count <= 128)
                let stride = (!combine && n <= 64 && preferred != TransferSyntaxUID.implicitLittleEndian) ? 2 : 1
                var expected = original
                expected.remove(at: 1)  // the duplicate SEG
                for (index, sopClass) in expected.enumerated() {
                    let offered = contexts[index * stride]
                    precondition(offered.abstractSyntax == sopClass)
                    precondition(offered.identifier == index * stride * 2 + 1)
                    precondition((1...3).contains(offered.transferSyntaxes.count))
                    if n > 64 && preferred != TransferSyntaxUID.implicitLittleEndian { precondition(offered.transferSyntaxes.count == 3) }
                }
                precondition(contexts.allSatisfy { $0.identifier % 2 == 1 && $0.identifier <= 255 })
                for context in contexts {
                    out.append("\(context.identifier) \(context.abstractSyntax) \(context.transferSyntaxes.joined(separator: ","))")
                }
                out.append("--")
            }
        }
    }
}
print(out.joined(separator: "\n"))
'''

ADD = r'''
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmnet/assoc.h>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
int main() {
    T_ASC_Parameters *params = NULL;
    std::string line;
    int sets = 0;
    while (std::getline(std::cin, line)) {
        if (line == "--") { if (params) ASC_destroyAssociationParameters(&params); params = NULL; continue; }
        if (line.find("refused") != std::string::npos) continue;
        if (!params && ASC_createAssociationParameters(&params, ASC_DEFAULTMAXPDU).bad()) return 2;
        std::istringstream fields(line);
        int identifier; std::string sopClass, syntaxes;
        fields >> identifier >> sopClass >> syntaxes;
        std::vector<std::string> list; std::stringstream split(syntaxes); std::string syntax;
        while (std::getline(split, syntax, ',')) list.push_back(syntax);
        std::vector<const char *> pointers; for (auto &s : list) pointers.push_back(s.c_str());
        if (ASC_addPresentationContext(params, identifier, sopClass.c_str(), pointers.data(), (int)pointers.size()).bad()) {
            printf("FAIL: DCMTK refuses context %d of %s\n", identifier, sopClass.c_str());
            return 1;
        }
        sets++;
    }
    printf("DCMTK took %d planned contexts\n", sets);
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-store-negotiation-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', *map(str, sorted(MODULE.glob('*.swift'))), str(folder / 'main.swift'),
                            '-o', str(folder / 'plan')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-3000:])
        print('FAIL: the module does not compile')
        sys.exit(1)
    plan = subprocess.run([str(folder / 'plan')], capture_output=True, text=True, timeout=60)
    if plan.returncode:
        print(plan.stdout[-500:], plan.stderr[-2000:])
        print('FAIL: the plan breaks a rule of the negotiation')
        sys.exit(1)
    (folder / 'add.cc').write_text(ADD)
    subprocess.run(['xcrun', 'clang++', '-std=c++17', str(folder / 'add.cc'), *dcmtk_flags('dcmnet'),
                    '-o', str(folder / 'add')], check=True)
    added = subprocess.run([str(folder / 'add')], input=plan.stdout, capture_output=True, text=True, timeout=60)
    print(added.stdout.strip())
    if added.returncode:
        sys.exit(1)
print('PASS: selected SEG first, no duplicates, optional classes fit, 65/128 classes combine, 129 fail before association')

# Every selected path is reported on; the readable storage objects among them
# decide the presentation contexts, before the association is asked for.
send = (ROOT / 'Horos/Sources/DCMTKStoreSCU.swift').read_text()
files = send[send.index('private func sendFiles('):]
files = files[:files.index('let sender = StoreFileSender(')]
assert 'filesToSend.compactMap { IsiXDCMTKStoreFile.storageSOPClassOfFile(atPath: $0) }' in files
assert files.index('storageSOPClassOfFile') < files.index('try link.open(classes: classes')
association = (ROOT / 'Horos/Sources/DCMTKStoreSCU+Association.swift').read_text()
assert 'optional: IsiXDCMTKUIDs.shortStorageSOPClasses' in association
assert 'proposeOnlyRequired' not in association
adapter = (ROOT / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKStoreSCU.mm').read_text()
check = adapter[adapter.index('+ (NSString *)storageSOPClassOfFileAtPath:'):]
assert 'HorosFindSOPClassAndInstanceInFile(' in check and 'dcmIsaStorageSOPClassUID(' in check
print('PASS: all input paths reach individual reporting; all valid selected storage classes enter negotiation')

initializer = send[send.index('    public init(callingAET:'):send.index('    /// The patient\'s name')]
assert 'fileExists' not in initializer and 'removeObjects(in:' not in initializer
