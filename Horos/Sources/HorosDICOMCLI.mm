// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
// Licensed under the GNU Lesser General Public License, version 3.
#import "HorosDICOMCLI.h"
#include <dcmtk/config/osconfig.h>
#include "HorosDCMTKSeekableInput.h"
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcpath.h>
#include <dcmtk/dcmdata/dcistrmz.h>
#include <dcmtk/ofstd/ofcmdln.h>
#include <dcmtk/ofstd/ofstd.h>
#include <vector>
#include <string>
#include <mutex>
#include <limits>
#include <memory>
#include <climits>
#include <cstring>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

namespace {
struct Option { const char *name; const char *alias; int values; };
// These are the host facade's historical options, not the dcmodify application's
// implementation. Parsing, dictionary lookup and data operations come from dcmdata.
const Option options[] = {
    {"--help", "-h", 0}, {"--version", "", 0}, {"--debug", "-d", 0},
    {"--verbose", "-v", 0}, {"--ignore-errors", "-ie", 0},
    {"--read-file", "+f", 0}, {"--read-file-only", "+fo", 0}, {"--read-dataset", "-f", 0},
    {"--read-xfer-auto", "-t=", 0}, {"--read-xfer-detect", "-td", 0},
    {"--read-xfer-little", "-te", 0}, {"--read-xfer-big", "-tb", 0}, {"--read-xfer-implicit", "-ti", 0},
    {"--accept-odd-length", "+ao", 0}, {"--assume-even-length", "+ae", 0},
    {"--enable-correction", "+dc", 0}, {"--disable-correction", "-dc", 0},
#ifdef WITH_ZLIB
    {"--bitstream-deflated", "+bd", 0}, {"--bitstream-zlib", "+bz", 0},
#endif
    {"--insert-tag", "-i", 1}, {"--modify-tag", "-m", 1}, {"--modify-all-tags", "-ma", 1},
    {"--erase-tag", "-e", 1}, {"--erase-all-tags", "-ea", 1},
    {"--gen-stud-uid", "-gst", 0}, {"--gen-ser-uid", "-gse", 0}, {"--gen-inst-uid", "-gin", 0},
    {"--no-meta-uid", "-nmu", 0}, {"--write-file", "+F", 0}, {"--write-dataset", "-F", 0},
    {"--write-xfer-same", "+t=", 0}, {"--write-xfer-little", "+te", 0},
    {"--write-xfer-big", "+tb", 0}, {"--write-xfer-implicit", "+ti", 0},
    {"--enable-new-vr", "+u", 0}, {"--disable-new-vr", "-u", 0},
    {"--group-length-recalc", "+g=", 0}, {"--group-length-create", "+g", 0}, {"--group-length-remove", "-g", 0},
    {"--length-explicit", "+le", 0}, {"--length-undefined", "-le", 0},
    {"--padding-retain", "-p=", 0}, {"--padding-off", "-p", 0}, {"--padding-create", "+p", 2}
};
struct Job { std::string option; OFString path, value; };
struct Settings {
    E_FileReadMode read = ERM_autoDetect;
    E_TransferSyntax input = EXS_Unknown, output = EXS_Unknown;
    E_EncodingType length = EET_ExplicitLength;
    E_GrpLenEncoding groups = EGL_recalcGL;
    E_PaddingEncoding padding = EPD_withoutPadding;
    Uint32 filePadding = 0, itemPadding = 0;
    bool dataset = false, ignore = false, metaUID = true;
};
// DCMTK exposes some I/O settings as process globals. Restore the caller's
// settings even on failure, and serialize invocations of this facade.
struct GlobalSettings {
    OFBool detect = dcmAutoDetectDatasetXfer.get(), odd = dcmAcceptOddAttributeLength.get();
    OFBool correction = dcmEnableAutomaticInputDataCorrection.get();
    OFBool unknown = dcmEnableUnknownVRGeneration.get(), text = dcmEnableUnlimitedTextVRGeneration.get();
#ifdef WITH_ZLIB
    OFBool zlib = dcmZlibExpectRFC1950Encoding.get();
#endif
    ~GlobalSettings() {
        dcmAutoDetectDatasetXfer.set(detect); dcmAcceptOddAttributeLength.set(odd);
        dcmEnableAutomaticInputDataCorrection.set(correction);
        dcmEnableUnknownVRGeneration.set(unknown); dcmEnableUnlimitedTextVRGeneration.set(text);
#ifdef WITH_ZLIB
        dcmZlibExpectRFC1950Encoding.set(zlib);
#endif
    }
};

// Parse tags with upstream dictionary support, but retain existing-only
// sequence traversal. Insertion may create a leaf, never a sequence or item.
OFCondition target(DcmItem *root, OFString path, DcmItem *&item, DcmTag &tag) {
    item = root;
    for (;;) {
        if (path.empty()) return EC_IllegalParameter;
        if (path[0] == '(') {
            const size_t close = path.find(')');
            if (close == OFString_npos) return EC_IllegalParameter;
            const OFString numeric = path.substr(1, close - 1);
            unsigned group = 0, element = 0; int consumed = 0;
            if (sscanf(numeric.c_str(), "%x,%x%n", &group, &element, &consumed) != 2 ||
                consumed != (int)numeric.size() || group > 0xffff || element > 0xffff) return EC_IllegalParameter;
        }
        OFCondition result = DcmPath::parseTagFromPath(path, tag);
        if (result.bad()) return result;
        if (path.empty()) return EC_Normal;
        if (path[0] != '[') return EC_IllegalParameter;
        size_t end = path.find(']');
        if (end == OFString_npos || end < 2) return EC_IllegalParameter;
        Uint32 index = 0;
        for (size_t p = 1; p < end; ++p) {
            if (path[p] < '0' || path[p] > '9') return EC_IllegalParameter;
            unsigned digit = path[p] - '0';
            if (index > (std::numeric_limits<Uint32>::max() - digit) / 10) return EC_IllegalParameter;
            index = index * 10 + digit;
        }
        if (end + 1 >= path.size() || path[end + 1] != '.') return EC_IllegalParameter;
        DcmSequenceOfItems *sequence = nullptr;
        result = item->findAndGetSequence(tag, sequence, OFFalse);
        if (result.bad()) return result;
        if (index >= sequence->card()) return EC_TagNotFound;
        item = sequence->getItem(index);
        path.erase(0, end + 2);
    }
}

OFCondition execute(DcmFileFormat &file, const Job &job, bool metaUID) {
    DcmDataset *dataset = file.getDataset();
    DcmItem *item = dataset;
    DcmTag tag;
    OFString value = job.value;
    const bool generate = job.option == "--gen-stud-uid" || job.option == "--gen-ser-uid" || job.option == "--gen-inst-uid";
    if (generate) {
        const bool study = job.option == "--gen-stud-uid", series = job.option == "--gen-ser-uid";
        tag = DcmTag(study ? DCM_StudyInstanceUID : series ? DCM_SeriesInstanceUID : DCM_SOPInstanceUID);
        char uid[100];
        dcmGenerateUniqueIdentifier(uid, study ? SITE_STUDY_UID_ROOT : series ? SITE_SERIES_UID_ROOT : SITE_INSTANCE_UID_ROOT);
        value = uid;
    } else {
        OFString path = job.path;
        if (job.option == "--modify-all-tags") {
            size_t dot = path.rfind('.');
            if (dot != OFString_npos) path.erase(0, dot + 1);
        }
        OFCondition result = target(dataset, path, item, tag);
        if (result.bad()) return result;
    }
    const DcmTagKey key = tag.getTagKey();
    const bool erase = job.option == "--erase-tag" || job.option == "--erase-all-tags";
    const bool all = job.option == "--modify-all-tags" || job.option == "--erase-all-tags";
    // The CLI facade historically permits group 0002 in the dataset, but not
    // command-group insert/modify or invalid private groups. Erasure is unrestricted.
    if (!erase && (key.getGroup() == 0 || !key.hasValidGroup())) return EC_IllegalParameter;
    // modify-all ignores the path prefix; erase-all searches below that prefix.
    if (erase) return item->findAndDeleteElement(key, all, all);
    OFCondition result;
    if (all) {
        DcmStack matches;
        result = dataset->findAndGetElements(key, matches);
        while (result.good() && matches.card()) {
            DcmObject *object = matches.pop();
            result = object->isLeaf() ? static_cast<DcmElement *>(object)->putString(value.c_str()) : EC_IllegalCall;
        }
    } else {
        DcmElement *element = nullptr;
        result = item->findAndGetElement(key, element, OFFalse);
        if (result == EC_TagNotFound && (generate || job.option == "--insert-tag")) {
            // A new private/unknown leaf keeps the legacy UN + empty policy.
            // A known creator-qualified tag can instead use its dictionary VR.
            if (key.isPrivate() && key.getElement() >= 0x1000) {
                OFString creator;
                if (DcmPathProcessor::getPrivateCreator(item, key, creator).good()) {
                    tag.setPrivateCreator(creator.c_str()); tag.lookupVRinDictionary();
                }
            }
            if (tag.getEVR() == EVR_UNKNOWN || tag.getEVR() == EVR_UNKNOWN2B || tag.getEVR() == EVR_UN) {
                tag.setVR(EVR_UN); value.clear();
            }
            result = DcmItem::newDicomElementWithVR(element, tag);
            std::unique_ptr<DcmElement> owner(element);
            if (result.good()) result = element->putString(value.c_str());
            if (result.good()) {
                result = item->insert(element, OFTrue);
                if (result.good()) owner.release();
            }
        } else if (result.good()) result = element->putString(value.c_str());
    }
    if (result.good() && (metaUID || generate)) {
        if (key == DCM_SOPInstanceUID) delete file.getMetaInfo()->remove(DCM_MediaStorageSOPInstanceUID);
        if (key == DCM_SOPClassUID) delete file.getMetaInfo()->remove(DCM_MediaStorageSOPClassUID);
    }
    return result;
}

struct Temporary {
    std::string name;
    explicit Temporary(const std::string &base) {
        std::vector<char> buffer(base.begin(), base.end());
        const char suffix[] = ".horos-XXXXXX";
        buffer.insert(buffer.end(), suffix, suffix + sizeof(suffix));
        int fd = mkstemp(buffer.data());
        if (fd >= 0) { name = buffer.data(); close(fd); }
    }
    ~Temporary() { if (!name.empty()) unlink(name.c_str()); }
};

bool durable(const std::string &path, mode_t mode) {
    int fd = open(path.c_str(), O_RDWR);
    if (fd < 0) return false;
    bool ok = fchmod(fd, mode & 0777) == 0 && fsync(fd) == 0;
    if (close(fd) != 0) ok = false;
    return ok;
}

bool publish(DcmFileFormat &file, const std::string &path, const Settings &s) {
    struct stat info;
    if (lstat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) return false;
    E_TransferSyntax syntax = s.output == EXS_Unknown ? file.getDataset()->getOriginalXfer() : s.output;
    if (!file.canWriteXfer(syntax)) return false;
    bool dataset = s.dataset;
    if (DcmXfer(syntax).usesEncapsulatedFormat() && DcmXfer(syntax).isPixelDataCompressed()) dataset = false;
    Temporary output(path), backup(path + ".bak");
    if (output.name.empty() || backup.name.empty()) return false;
    OFCondition result = file.saveFile(output.name.c_str(), syntax, s.length, s.groups,
        s.padding, s.filePadding, s.itemPadding, dataset ? EWM_dataset : EWM_fileformat);
    if (result.bad() || !durable(output.name, info.st_mode)) return false;
    // Do not move away the source while writing. Publish a complete backup, then
    // atomically replace the original; every earlier failure leaves it untouched.
    if (!OFStandard::copyFile(path.c_str(), backup.name.c_str()) || !durable(backup.name, info.st_mode)) return false;
    if (rename(backup.name.c_str(), (path + ".bak").c_str()) != 0) return false;
    return rename(output.name.c_str(), path.c_str()) == 0;
}

int modify(NSArray *params, NSStringEncoding encoding) {
    if (![params isKindOfClass:[NSArray class]] || params.count == 0 || params.count > INT_MAX) return 1;
    std::vector<std::string> storage;
    const unichar zero = 0;
    NSString *nul = [NSString stringWithCharacters:&zero length:1];
    for (id argument in params) {
        if (![argument isKindOfClass:[NSString class]] || [argument rangeOfString:nul].location != NSNotFound) return 1;
        const char *utf8 = [argument UTF8String];
        if (!utf8) return 1;
        storage.emplace_back(utf8);
    }
    if (storage.size() == 1) {
        printf("DICOM modification: program [options] file...\n");
        return 0;
    }
    std::vector<char *> argv;
    for (auto &argument : storage) argv.push_back(const_cast<char *>(argument.c_str()));
    OFCommandLine command;
    command.addParam("file", "DICOM file", OFCmdParam::PM_MultiOptional);
    for (const Option &option : options)
        command.addOption(option.name, option.alias, option.values, "", "", option.name == std::string("--version") ? OFCommandLine::AF_Exclusive : 0);
    // Mark the registered facade options as checked for DCMTK Debug builds;
    // dispatch below reads options in order rather than using findOption.
    for (const Option &option : options) command.findOption(option.name);
    auto status = command.parseLine((int)argv.size(), argv.data(), OFCommandLine::PF_ExpandWildcards);
    if (status != OFCommandLine::PS_Normal && status != OFCommandLine::PS_ExclusiveOption) return 1;
    if (command.findOption("--version")) {
        printf("DICOM modification / DCMTK %s\n", OFFIS_DCMTK_VERSION);
        return 0;
    }
    if (command.findOption("--help")) {
        printf("DICOM modification: program [options] file...\n");
        for (const Option &option : options) printf("%s %s\n", option.name, option.alias);
        return 0;
    }
    if (command.getParamCount() == 0) return 1;
    Settings s;
    std::vector<Job> jobs;
    bool forcedInput = false;
    if (command.gotoFirstOption()) do {
        OFString option; command.getCurrentOption(option);
        if (option == "--ignore-errors") s.ignore = true;
        else if (option == "--no-meta-uid") s.metaUID = false;
        else if (option == "--read-file") s.read = ERM_autoDetect;
        else if (option == "--read-file-only") s.read = ERM_fileOnly;
        else if (option == "--read-dataset") s.read = ERM_dataset;
        else if (option == "--read-xfer-auto" || option == "--read-xfer-detect") {
            s.input = EXS_Unknown; forcedInput = false; dcmAutoDetectDatasetXfer.set(option == "--read-xfer-detect");
        } else if (option == "--read-xfer-little" || option == "--read-xfer-big" || option == "--read-xfer-implicit") {
            forcedInput = true; dcmAutoDetectDatasetXfer.set(OFFalse);
            s.input = option == "--read-xfer-little" ? EXS_LittleEndianExplicit : option == "--read-xfer-big" ? EXS_BigEndianExplicit : EXS_LittleEndianImplicit;
        } else if (option == "--write-file") s.dataset = false;
        else if (option == "--write-dataset") s.dataset = true;
        else if (option == "--write-xfer-same") s.output = EXS_Unknown;
        else if (option == "--write-xfer-little") s.output = EXS_LittleEndianExplicit;
        else if (option == "--write-xfer-big") s.output = EXS_BigEndianExplicit;
        else if (option == "--write-xfer-implicit") s.output = EXS_LittleEndianImplicit;
        else if (option == "--length-explicit") s.length = EET_ExplicitLength;
        else if (option == "--length-undefined") s.length = EET_UndefinedLength;
        else if (option == "--group-length-recalc") s.groups = EGL_recalcGL;
        else if (option == "--group-length-create") s.groups = EGL_withGL;
        else if (option == "--group-length-remove") s.groups = EGL_withoutGL;
        else if (option == "--padding-off") s.padding = EPD_withoutPadding;
        else if (option == "--padding-retain") s.padding = EPD_noChange;
        else if (option == "--padding-create") {
            OFCmdUnsignedInt f, i;
            if (command.getValueAndCheckMin(f, 0) != OFCommandLine::VS_Normal || command.getValueAndCheckMin(i, 0) != OFCommandLine::VS_Normal || f > UINT32_MAX || i > UINT32_MAX) return 1;
            s.padding = EPD_withPadding; s.filePadding = (Uint32)f; s.itemPadding = (Uint32)i;
        } else if (option == "--accept-odd-length" || option == "--assume-even-length") dcmAcceptOddAttributeLength.set(option == "--accept-odd-length");
        else if (option == "--enable-correction" || option == "--disable-correction") dcmEnableAutomaticInputDataCorrection.set(option == "--enable-correction");
        else if (option == "--enable-new-vr" || option == "--disable-new-vr") {
            dcmEnableUnknownVRGeneration.set(option == "--enable-new-vr"); dcmEnableUnlimitedTextVRGeneration.set(option == "--enable-new-vr");
        }
#ifdef WITH_ZLIB
        else if (option == "--bitstream-deflated" || option == "--bitstream-zlib") dcmZlibExpectRFC1950Encoding.set(option == "--bitstream-zlib");
#endif
        else if (option == "--insert-tag" || option == "--modify-tag" || option == "--modify-all-tags" || option == "--erase-tag" || option == "--erase-all-tags") {
            OFString argument; if (command.getValue(argument) != OFCommandLine::VS_Normal) return 1;
            size_t equal = argument.find('=');
            Job job; job.option = option.c_str(); job.path = argument.substr(0, equal);
            if (equal != OFString_npos) {
                NSString *value = [NSString stringWithUTF8String:argument.substr(equal + 1).c_str()];
                NSData *bytes = [value dataUsingEncoding:encoding allowLossyConversion:NO];
                if (!bytes) return 1;
                if (bytes.length) {
                    if (memchr(bytes.bytes, 0, bytes.length)) return 1;
                    job.value.assign((const char *)bytes.bytes, bytes.length);
                }
            }
            if (job.path.empty()) return 1;
            jobs.push_back(job);
        } else if (option == "--gen-stud-uid" || option == "--gen-ser-uid" || option == "--gen-inst-uid") jobs.push_back({option.c_str(), "", ""});
    } while (command.gotoNextOption());
    if ((forcedInput && s.read != ERM_dataset) || (s.dataset && s.padding != EPD_withoutPadding)) return 1;
    int errors = 0;
    for (int n = 1; n <= command.getParamCount(); ++n) {
        OFString filename; if (command.getParam(n, filename) != OFCommandLine::PVS_Normal) return errors + 1;
        // Keep deferred values backed until the staged save finishes. File
        // input may be deflated; dataset-only input uses the native TS selected
        // by the facade and remains backed directly by the unchanged source.
        HorosDCMTKSeekableInput input;
        DcmFileFormat datasetInput;
        const bool fileInput = s.read != ERM_dataset;
        DcmFileFormat &file = fileInput ? input.fileFormat() : datasetInput;
        OFCondition result = fileInput
            ? input.load(filename.c_str(), [NSTemporaryDirectory() fileSystemRepresentation])
            : file.loadFile(filename.c_str(), s.input, EGL_noChange, DCM_MaxReadLength, s.read);
        Settings output = s;
        if (result.good() && fileInput) {
            OFString syntax;
            file.getMetaInfo()->findAndGetOFString(DCM_TransferSyntaxUID, syntax);
            if (s.read == ERM_fileOnly && (syntax.empty() || DcmXfer(syntax.c_str()).getXfer() == EXS_Unknown))
                result = EC_FileMetaInfoHeaderMissing;
            // The seekable owner's expanded dataset is Explicit LE. Preserve
            // the original deflated output syntax when no conversion was asked.
            if (s.output == EXS_Unknown && syntax == UID_DeflatedExplicitVRLittleEndianTransferSyntax)
                output.output = EXS_DeflatedLittleEndianExplicit;
        }
        if (result.bad()) { ++errors; continue; }
        for (const Job &job : jobs) {
            result = execute(file, job, s.metaUID);
            if (result.bad()) { ++errors; NSLog(@"DICOM CLI operation failed: %s", result.text()); }
        }
        // Retain the facade's cumulative error policy for a multi-file invocation.
        if ((errors == 0 || s.ignore) && !publish(file, filename.c_str(), output)) ++errors;
    }
    return errors;
}
} // namespace

int HorosModifyDICOMCLI(NSArray *params, NSStringEncoding encoding) {
    static std::mutex mutex;
    std::lock_guard<std::mutex> lock(mutex);
    GlobalSettings restore;
    @try {
        try { return modify(params, encoding); }
        catch (...) { return 1; }
    } @catch (NSException *exception) {
        NSLog(@"DICOM CLI arguments failed: %@", exception.name);
        return 1;
    }
}
