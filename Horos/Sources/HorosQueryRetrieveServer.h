#ifndef HOROS_QUERY_RETRIEVE_SERVER_H
#define HOROS_QUERY_RETRIEVE_SERVER_H

#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmnet/dcasccfg.h>
#include <dcmtk/dcmqrdb/dcmqrdba.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <memory>

class HorosAssociationProcesses;
@class NSString;

// The only AE title the listener's DCMTK configuration names. The user's AE
// title is never written there: see HorosLoadListenerConfiguration.
extern const char* const HorosListenerConfigurationAETitle;

// Writes the configuration DCMTK's Q/R classes read, reads it into config and
// deletes the file. Returns nil, or what went wrong.
NSString* HorosLoadListenerConfiguration(DcmQueryRetrieveConfig& config, int port,
                                         unsigned long maxPDU, int maxAssociations);

// Whether a called AE title names the listener whose AE title is configured:
// leading and trailing spaces are not significant in an AE title, while case
// and the spaces inside it are. An empty configured title matches nothing.
bool HorosListenerAETitleMatches(const char* called, const char* configured);

// Application integration over stock DCMTK. DCMTK owns association/DIMSE
// processing; Horos supplies database access and per-image C-GET selection.
class HorosQueryRetrieveServer
{
public:
    HorosQueryRetrieveServer(const DcmQueryRetrieveConfig& config,
                             const DcmQueryRetrieveOptions& options,
                             const DcmQueryRetrieveDatabaseHandleFactory& factory,
                             const DcmAssociationConfiguration& associations,
                             OFBool secureConnection, const char* aeTitle);
    ~HorosQueryRetrieveServer();

    OFCondition waitForAssociation(T_ASC_Network* network);

private:
    const DcmQueryRetrieveConfig& config_;
    const DcmQueryRetrieveOptions& options_;
    const DcmQueryRetrieveDatabaseHandleFactory& factory_;
    const DcmAssociationConfiguration& associations_;
    OFBool secureConnection_;
    OFString aeTitle_;
    std::unique_ptr<HorosAssociationProcesses> processes_;

    HorosQueryRetrieveServer(const HorosQueryRetrieveServer&) = delete;
    HorosQueryRetrieveServer& operator=(const HorosQueryRetrieveServer&) = delete;
};

#endif
