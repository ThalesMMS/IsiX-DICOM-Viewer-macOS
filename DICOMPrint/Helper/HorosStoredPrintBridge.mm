// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// Part of the Horos fork (https://github.com/ThalesMMS/horos), under LGPLv3.
// Distributed without any warranty; see the GNU Lesser General Public License.

#include "dcmtk/config/osconfig.h"
#include "HorosStoredPrintBridge.h"
#include "dcmtk/dcmpstat/dviface.h"
#include "dcmtk/dcmpstat/dvpssp.h"
#include "dcmtk/dcmpstat/dvpspr.h"
#include "dcmtk/dcmimgle/dcmimage.h"
#include "dcmtk/dcmdata/dcfilefo.h"
#include "dcmtk/oflog/configrt.h"
#include "dcmtk/dcmpstat/dvpsdef.h"
#include <memory>

namespace {
struct PrintContext {
    DVInterface interface;
    OFString printer;
    PrintContext(const char *config, const char *name): interface(config), printer(name) {}
};

int report(const OFCondition &condition, const char *stage) {
    if (condition.good()) return 0;
    OFLOG_ERROR(OFLog::getLogger("horos.print"), stage << ": " << condition.text());
    return 1;
}
}

void *HorosStoredPrintOpen(const char *config, const char *logger, const char *printer,
                          unsigned int copies, const char *priority,
                          const char *destination, const char *medium) {
    if (logger && *logger) dcmtk::log4cplus::PropertyConfigurator::doConfigure(logger);
    else OFLog::configure(OFLogger::INFO_LOG_LEVEL);
    std::unique_ptr<PrintContext> context(new PrintContext(config, printer));
    DVInterface &dvi = context->interface;
    if (report(dvi.setCurrentPrinter(printer), "printer configuration")) return nullptr;
    if (!dvi.getTargetHostname(printer) || !dvi.getTargetAETitle(printer) ||
        !dvi.getTargetPort(printer) || dvi.getTargetUseTLS(printer)) {
        // The native printer configuration uses plain DIMSE. Refuse unsupported
        // transport configuration rather than silently downgrade it.
        report(EC_IllegalCall, "invalid or unsupported printer transport");
        return nullptr;
    }
    if (dvi.getTargetDisableNewVRs(printer)) dcmDisableGenerationOfNewVRs();
    const Sint32 timeout = dvi.getTargetTimeout(printer);
    if (timeout > 0) dcmConnectionTimeout.set(timeout);
    dvi.setPrinterNumberOfCopies(copies);
    dvi.setPrinterPriority(priority);
    dvi.setPrinterFilmDestination(destination);
    dvi.setPrinterMediumType(medium);
    return context.release();
}

HorosStoredPrintResult HorosStoredPrintSend(void *opaque, const char *filename) {
    HorosStoredPrintResult outcome = {0, 0, 0, 0};
    if (!opaque || !filename || !*filename) {
        outcome.operationStatus = report(EC_IllegalCall, "missing Stored Print");
        return outcome;
    }
    PrintContext &context = *static_cast<PrintContext *>(opaque);
    DVInterface &dvi = context.interface;
    const char *printer = context.printer.c_str();
    DVPSStoredPrint &stored = dvi.getPrintHandler();
    DcmFileFormat file;
    OFCondition operation = file.loadFile(OFFilename(filename, OFTrue));
    if (operation.good()) operation = stored.read(*file.getDataset());
    if (operation.bad()) {
        outcome.operationStatus = report(operation, "load Stored Print");
        return outcome;
    }

    DVPSPrintMessageHandler connection;
    unsigned long maxPDU = dvi.getTargetMaxPDU(printer);
    if (!maxPDU || maxPDU > ASC_MAXIMUMPDUSIZE) maxPDU = DEFAULT_MAXPDU;
    operation = connection.negotiateAssociation(nullptr, dvi.getNetworkAETitle(),
        dvi.getTargetAETitle(printer), dvi.getTargetHostname(printer),
        dvi.getTargetPort(printer), dvi.getTargetProtocol(printer), maxPDU,
        dvi.getTargetPrinterSupportsPresentationLUT(printer),
        dvi.getTargetPrinterSupportsAnnotationBoxSOPClass(printer),
        dvi.getTargetImplicitOnly(printer));
    if (operation.bad()) {
        outcome.operationStatus = report(operation, "negotiate printer");
        return outcome;
    }

    const OFBool lutInSession = dvi.getTargetPrinterPresentationLUTinFilmSession(printer);
    // Keep DCMTK's explicit success/warning policy inside its public print APIs.
    if (operation.good()) operation = stored.printSCUgetPrinterInstance(connection);
    if (operation.good()) operation = stored.printSCUpreparePresentationLUT(connection,
        dvi.getTargetPrinterPresentationLUTMatchRequired(printer),
        dvi.getTargetPrinterPresentationLUTPreferSCPRendering(printer),
        dvi.getTargetPrinterSupports12BitTransmission(printer));
    if (operation.good()) operation = dvi.printSCUcreateBasicFilmSession(connection, lutInSession);
    if (operation.good()) operation = stored.printSCUcreateBasicFilmBox(connection, lutInSession);
    for (size_t index = 0; operation.good() && index < stored.getNumberOfImages(); ++index) {
        const char *study = nullptr, *series = nullptr, *instance = nullptr;
        operation = stored.getImageReference(index, study, series, instance);
        if (operation.bad()) break;
        if (!study || !series || !instance) { operation = EC_IllegalCall; break; }
        const char *reference = dvi.getFilename(study, series, instance);
        // releaseDatabase invalidates the pointer returned by getFilename.
        const OFString path = reference ? reference : "";
        dvi.releaseDatabase();
        if (path.empty()) { operation = EC_IllegalCall; break; }
        DicomImage image(path.c_str());
        if (image.getStatus() != EIS_Normal) { operation = EC_IllegalCall; break; }
        operation = stored.printSCUsetBasicImageBox(connection, index, image, OFFalse);
    }
    for (size_t index = 0; operation.good() && index < stored.getNumberOfAnnotations(); ++index)
        operation = stored.printSCUsetBasicAnnotationBox(connection, index);
    if (operation.good()) {
        operation = stored.printSCUprintBasicFilmBox(connection);
        outcome.printAccepted = operation.good();
    }
    outcome.operationStatus = report(operation, "print operation");
    // Match the upstream cleanup sequence, keeping it separate from printing.
    if (operation.good()) outcome.cleanupStatus = report(stored.printSCUdelete(connection), "delete print objects");
    outcome.releaseStatus = report(connection.releaseAssociation(), "release printer");
    return outcome;
}

void HorosStoredPrintClose(void *context) { delete static_cast<PrintContext *>(context); }
