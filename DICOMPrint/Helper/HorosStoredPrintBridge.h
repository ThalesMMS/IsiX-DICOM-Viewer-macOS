// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// Part of the Horos fork (https://github.com/ThalesMMS/horos), under LGPLv3.
// Distributed without any warranty; see the GNU Lesser General Public License.

#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int operationStatus;
    int cleanupStatus;
    int releaseStatus;
    int printAccepted;
} HorosStoredPrintResult;

void *HorosStoredPrintOpen(const char *config, const char *logger, const char *printer,
                          unsigned int copies, const char *priority,
                          const char *destination, const char *medium);
HorosStoredPrintResult HorosStoredPrintSend(void *context, const char *filename);
void HorosStoredPrintClose(void *context);

#ifdef __cplusplus
}
#endif
