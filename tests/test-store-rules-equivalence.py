#!/usr/bin/env python3
"""The send and the listener's C-MOVE follow the rules the Objective-C++ followed.

DCMTKStoreSCU.mm and HorosDICOMMoveContext.mm decided, inline, which transfer
syntax a send proposes and with what quality, which presentation contexts it
asks for, when a file is converted before it goes out, which send setting
matches the listener's preferred syntax, and which syntaxes the C-MOVE
sub-operations offer. Those rules are IsiXDICOMNetwork's now (StoreRules.swift).
This compiles the old code, from the revision that still has those files,
against the Debug build's DCMTK, and compares, through DCMTK's own transfer
syntax table:

- every send setting (and two unknown ones): the network syntax and quality;
- every E_TransferSyntax DCMTK knows as the listener's syntax: the setting;
- the presentation contexts of each network syntax for batches of 0 to 129
  storage classes, duplicates included, with and without combined syntaxes
  and optional classes: identifiers, classes and syntaxes, or the refusal;
- the conversion of a file in each syntax DCMTK knows, for each syntax the
  peer may accept (or none) and each network syntax: none, decompression,
  compression, and whether the log warns of a recompression;
- the move sub-operations' syntaxes, with and without DontSupportJPEGForCSMove.

Exits 2 without the Debug build's DCMTK, or when the history does not reach a
revision with the Objective-C++ (a shallow clone).
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402
import history_reference  # noqa: E402

STORE, MOVE, SEND = 'Horos/Sources/DCMTKStoreSCU.mm', 'Horos/Sources/HorosDICOMMoveContext.mm', 'Horos/Sources/SendController.h'
reference = history_reference.before_removal(STORE)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + STORE],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: the history does not reach a revision with ' + STORE)
    sys.exit(2)


def old(path):
    return history_reference.show(reference, path).decode('latin1')


def between(text, start, end):
    at = text.index(start)
    return text[at:text.index(end, at)]


def braces(text, start):
    """From `start` to the brace that closes the first one after it."""
    at = text.index(start)
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    raise ValueError(start)


flags = dcmtk_flags('dcmnet')
store, move, send = old(STORE), old(MOVE), old(SEND)
codes = braces(send, 'enum TransferSyntaxCodes') + ';'
setting_switch = braces(store, 'switch (_transferSyntax)')
listener = braces(store, '+ (int) sendSyntaxForListenerSyntax: (int) listenerSyntax')
listener = listener.replace('+ (int) sendSyntaxForListenerSyntax: (int) listenerSyntax', 'static int old_listener(int listenerSyntax)')
contexts = between(store, 'static OFBool\nisaListMember(', '//static int')
deflated = between(store, 'DcmXfer filexfer(dcmff.getDataset()->getOriginalXfer());', '/************* do on the fly')
conversion = between(store, ' if (presId != 0)', 'if (status)\n')
move_syntaxes = between(move, 'const char* transferSyntaxes[ 10]', 'for (i=0; i<numberOfDcmLongSCUStorageSOPClassUIDs')
move_syntaxes = move_syntaxes.replace('[[NSUserDefaults standardUserDefaults] boolForKey: @"DontSupportJPEGForCSMove"]', 'withoutJPEG')

OLD = r'''
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmnet/assoc.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/ofstd/oflist.h>
#include <cstdio>
#include <string>
#include <vector>
#include "HorosDCMTKCompatibility.h"
#define YES OFTrue
#define NO OFFalse

@@CODES@@

struct StoreSendContext {
    E_TransferSyntax opt_networkTransferSyntax = EXS_LittleEndianExplicit;
    int opt_Quality = 90;
    OFBool opt_proposeOnlyRequiredPresentationContexts = OFFalse;
    OFBool opt_combineProposedTransferSyntaxes = OFFalse;
};
static void errmsg(const char *, ...) {}

@@CONTEXTS@@

@@LISTENER@@

static int decision;
static OFBool decompressFile(DcmFileFormat, const char *, char *) { decision = 1; return OFTrue; }
static OFBool compressFile(StoreSendContext &, DcmFileFormat, const char *, char *) { decision = decision == 3 ? 3 : 2; return OFTrue; }

static std::string uid(E_TransferSyntax ts) { return DcmXfer(ts).getXferID(); }

// The conversion of a file in `file` for `network`, the peer having accepted
// `accepted` (EXS_Unknown: no context accepted in the network syntax).
static void convert(E_TransferSyntax file, E_TransferSyntax accepted, E_TransferSyntax network)
{
    StoreSendContext context;
    context.opt_networkTransferSyntax = network;
    DcmFileFormat dcmff;
    const char *fname = "";
    char outfname[16] = "";
    DcmXfer filexfer(file);
    @@DEFLATED@@
    DcmXfer preferredXfer(context.opt_networkTransferSyntax);
    OFBool status = NO;
    T_ASC_PresentationContextID presId = accepted == EXS_Unknown ? 0 : 1;
    DcmXfer proposedTransfer(accepted == EXS_Unknown ? EXS_LittleEndianImplicit : accepted);
    decision = 0;
#define printf(...) (decision = 3)
    @@CONVERSION@@
#undef printf
    printf("CONVERT %d %d %d %d %s\n", (int)file, (int)accepted, (int)network, decision, filexfer.getXferID());
}

int main()
{
    // DCMTK's transfer syntaxes, and what each holds.
    std::vector<E_TransferSyntax> known;
    for (int value = 0; value < 120; value++) {
        DcmXfer xfer((E_TransferSyntax)value);
        if (xfer.getXfer() == EXS_Unknown) continue;
        known.push_back((E_TransferSyntax)value);
        printf("XFER %d %s %d %d %d\n", value, xfer.getXferID(), xfer.usesNativeFormat() ? 1 : 0,
               xfer.usesEncapsulatedFormat() ? 1 : 0, xfer.isPixelDataCompressed() ? 1 : 0);
    }
    DcmXfer unknown(EXS_Unknown);
    printf("UNKNOWN %d %d %d\n", unknown.usesNativeFormat() ? 1 : 0, unknown.usesEncapsulatedFormat() ? 1 : 0,
           unknown.isPixelDataCompressed() ? 1 : 0);
    for (int i = 0; i < numberOfDcmShortSCUStorageSOPClassUIDs; i++) printf("SHORT %s\n", dcmShortSCUStorageSOPClassUIDs[i]);

    // The send settings.
    std::vector<E_TransferSyntax> networks;
    for (int _transferSyntax = -1; _transferSyntax <= 18; _transferSyntax++) {
        StoreSendContext context;
        @@SETTINGS@@
        printf("SETTING %d %s %d\n", _transferSyntax, uid(context.opt_networkTransferSyntax).c_str(), context.opt_Quality);
        bool seen = false;
        for (auto n : networks) seen = seen || n == context.opt_networkTransferSyntax;
        if (!seen) networks.push_back(context.opt_networkTransferSyntax);
    }

    // The listener's syntax.
    for (int value = -1; value < 120; value++) printf("LISTENER %d %s %d\n", value, uid((E_TransferSyntax)value).c_str(), old_listener(value));

    // The presentation contexts.
    const int sizes[] = {0, 1, 2, 3, 63, 64, 65, 100, 128, 129};
    for (auto network : networks) for (int size : sizes) for (int flags = 0; flags < 4; flags++) {
        StoreSendContext context;
        context.opt_networkTransferSyntax = network;
        context.opt_combineProposedTransferSyntaxes = (flags & 1) ? OFTrue : OFFalse;
        context.opt_proposeOnlyRequiredPresentationContexts = (flags & 2) ? OFTrue : OFFalse;
        OFList<OFString> classes;
        for (int i = 0; i < size; i++) {
            // Short-list classes, fake ones, and a repeat every seventh.
            if (i % 7 == 6) classes.push_back(classes.front());
            else if (i % 3 == 0) classes.push_back(dcmShortSCUStorageSOPClassUIDs[i % numberOfDcmShortSCUStorageSOPClassUIDs]);
            else classes.push_back(OFString("1.2.826.0.1.3680043.8.498.1485.") + std::to_string(i).c_str());
        }
        T_ASC_Parameters *params = NULL;
        ASC_createAssociationParameters(&params, ASC_DEFAULTMAXPDU);
        OFCondition result = addStoragePresentationContexts(context, params, classes);
        printf("PLAN %s %d %d", uid(network).c_str(), size, flags);
        if (result.bad()) printf(" refused\n");
        else {
            printf("\n");
            for (int i = 0; i < ASC_countPresentationContexts(params); i++) {
                T_ASC_PresentationContext pc;
                ASC_getPresentationContext(params, i, &pc);
                printf("CONTEXT %d %s", pc.presentationContextID, pc.abstractSyntax);
                for (int s = 0; s < pc.transferSyntaxCount; s++) printf("%c%s", s ? ',' : ' ', pc.proposedTransferSyntaxes[s]);
                printf("\n");
            }
        }
        ASC_destroyAssociationParameters(&params);
    }

    // The conversions.
    std::vector<E_TransferSyntax> files = known;
    files.push_back(EXS_Unknown);
    for (auto network : networks) for (auto file : files) {
        convert(file, EXS_Unknown, network);
        for (auto accepted : known) convert(file, accepted, network);
    }

    // The move sub-operations.
    for (int withoutJPEG = 0; withoutJPEG < 2; withoutJPEG++) {
        @@MOVE@@
        printf("MOVE %d", withoutJPEG);
        for (int i = 0; i < numTransferSyntaxes; i++) printf("%c%s", i ? ',' : ' ', transferSyntaxes[i]);
        printf("\n");
    }
    return 0;
}
'''
program = (OLD.replace('@@CODES@@', codes).replace('@@CONTEXTS@@', contexts).replace('@@LISTENER@@', listener)
           .replace('@@DEFLATED@@', deflated.replace('DcmXfer filexfer(dcmff.getDataset()->getOriginalXfer());', ''))
           .replace('@@CONVERSION@@', conversion).replace('@@SETTINGS@@', setting_switch)
           .replace('@@MOVE@@', move_syntaxes))

DRIVER = r'''
import Foundation

struct Xfer { let value: Int; let uid: String; let traits: TransferSyntaxTraits }
var xfers: [Int: Xfer] = [:]
var short: [String] = []
var out: [String] = []
let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n").map(String.init)
var networks: [String] = []
for line in lines {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    switch f[0] {
    case "XFER":
        xfers[Int(f[1])!] = Xfer(value: Int(f[1])!, uid: f[2],
                                 traits: TransferSyntaxTraits(native: f[3] == "1", encapsulated: f[4] == "1", pixelDataCompressed: f[5] == "1"))
    case "SHORT": short.append(f[1])
    case "SETTING":
        let syntax = StoreSendSyntax.network(forSetting: Int(f[1])!)
        out.append("SETTING \(f[1]) \(syntax.transferSyntax) \(syntax.quality)")
        if !networks.contains(syntax.transferSyntax) { networks.append(syntax.transferSyntax) }
    case "LISTENER":
        out.append("LISTENER \(f[1]) \(f[2]) \(StoreSendSyntax.setting(forListenerTransferSyntax: f[2]))")
    case "PLAN":
        let network = f[1], size = Int(f[2])!, flags = Int(f[3])!
        var classes: [String] = []
        for i in 0..<size {
            if i % 7 == 6 { classes.append(classes[0]) }
            else if i % 3 == 0 { classes.append(short[i % short.count]) }
            else { classes.append("1.2.826.0.1.3680043.8.498.1485.\(i)") }
        }
        switch StoragePresentationPlan.contexts(preferredTransferSyntax: network, required: classes, optional: short,
                                                proposeOnlyRequired: flags & 2 != 0, combineTransferSyntaxes: flags & 1 != 0) {
        case .failure: out.append("PLAN \(network) \(size) \(flags) refused")
        case .success(let contexts):
            out.append("PLAN \(network) \(size) \(flags)")
            for c in contexts { out.append("CONTEXT \(c.identifier) \(c.abstractSyntax) \(c.transferSyntaxes.joined(separator: ","))") }
        }
    case "CONVERT":
        let network = xfers[Int(f[3])!]!.uid
        var file = xfers[Int(f[1])!] ?? Xfer(value: -1, uid: "", traits: unknownTraits)
        if file.traits.native && network == TransferSyntaxUID.deflatedExplicitLittleEndian {
            file = xfers.values.first { $0.uid == TransferSyntaxUID.deflatedExplicitLittleEndian }!
        }
        let accepted = Int(f[2])! == -1 ? nil : xfers[Int(f[2])!]!.traits
        let code: Int
        switch StoreConversion.of(fileSyntax: file.uid, file: file.traits, accepted: accepted, networkSyntax: network) {
        case .none: code = 0
        case .decompress: code = 1
        case .compress(let warns): code = warns ? 3 : 2
        }
        out.append("CONVERT \(f[1]) \(f[2]) \(f[3]) \(code) \(file.uid)")
    case "MOVE":
        out.append("MOVE \(f[1]) \(MoveSubOperationSyntaxes.proposed(withoutJPEG: f[1] == "1").joined(separator: ","))")
    default: break
    }
}
print(out.joined(separator: "\n"))
'''

MODULE = ROOT / 'Modules/IsiXDICOMNetwork/Sources'
with tempfile.TemporaryDirectory(prefix='isix-store-rules-') as temporary:
    folder = Path(temporary)
    (folder / 'old.cc').write_text(program)
    built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-w', str(folder / 'old.cc'), *flags,
                            '-o', str(folder / 'old')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the old rules do not compile against the build\'s DCMTK')
        sys.exit(1)
    ran = subprocess.run([str(folder / 'old')], capture_output=True, text=True, timeout=60)
    if ran.returncode:
        print(ran.stderr[-2000:])
        print('FAIL: the old rules did not run')
        sys.exit(1)
    (folder / 'old.txt').write_text(ran.stdout)
    # The unknown syntax's traits, as DCMTK gives them, for the module's side.
    traits = next(line for line in ran.stdout.splitlines() if line.startswith('UNKNOWN ')).split()[1:]
    (folder / 'main.swift').write_text(DRIVER.replace(
        'unknownTraits', 'TransferSyntaxTraits(native: %s, encapsulated: %s, pixelDataCompressed: %s)'
        % tuple('true' if value == '1' else 'false' for value in traits)))
    built = subprocess.run(['xcrun', 'swiftc', *map(str, sorted(MODULE.glob('*.swift'))), str(folder / 'main.swift'),
                            '-o', str(folder / 'module')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-3000:])
        print('FAIL: the module does not compile with the driver')
        sys.exit(1)
    new = subprocess.run([str(folder / 'module'), str(folder / 'old.txt')], capture_output=True, text=True, timeout=60)
    if new.returncode:
        print(new.stderr[-2000:])
        print('FAIL: the module driver did not run')
        sys.exit(1)

before = [line for line in ran.stdout.splitlines() if not line.startswith(('XFER ', 'SHORT ', 'UNKNOWN '))]
after = new.stdout.splitlines()
failures = []
if len(before) != len(after):
    failures.append('%d results before, %d now' % (len(before), len(after)))
for was, now in zip(before, after):
    if was != now:
        failures.append('before: %s\n        now: %s' % (was, now))
        if len(failures) > 20:
            break
kinds = {}
for line in before:
    kinds[line.split(' ')[0]] = kinds.get(line.split(' ')[0], 0) + 1
for kind, least in (('SETTING', 20), ('LISTENER', 100), ('PLAN', 100), ('CONTEXT', 1000), ('CONVERT', 10000), ('MOVE', 2)):
    if kinds.get(kind, 0) < least:
        failures.append('only %d %s results were compared' % (kinds.get(kind, 0), kind))
for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: %s as the Objective-C++ of %s had them' % (', '.join('%d %s' % (count, kind.lower()) for kind, count in sorted(kinds.items())),
                                                      reference[:12]))
