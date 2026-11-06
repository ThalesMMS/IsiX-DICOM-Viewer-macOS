// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// Part of the Horos fork (https://github.com/ThalesMMS/horos), under LGPLv3.
// Distributed without any warranty; see the GNU Lesser General Public License.

#pragma once
#ifdef __cplusplus
extern "C" {
#endif

// The step of a Stored Print that failed, so the app can tell a file it could
// not read from a printer it could not reach and from a printer that refused
// the job.
enum {
    HorosStoredPrintStageNone = 0,
    HorosStoredPrintStageLoad = 1,     // reading the Stored Print or its images
    HorosStoredPrintStageConnect = 2,  // association with the printer
    HorosStoredPrintStageJob = 3       // film session, film box, image boxes or print action
};

typedef struct {
    int operationStatus;
    int cleanupStatus;
    int releaseStatus;
    int printAccepted;
    int failedStage;
    // The last failure status the printer answered with, 0 when it sent none.
    int dimseStatus;
} HorosStoredPrintResult;

void *HorosStoredPrintOpen(const char *config, const char *logger, const char *printer,
                          unsigned int copies, const char *priority,
                          const char *destination, const char *medium);
HorosStoredPrintResult HorosStoredPrintSend(void *context, const char *filename);
void HorosStoredPrintClose(void *context);

#ifdef __cplusplus
}
#endif
