#!/usr/bin/env python3
"""Every native DIMSE client uses the application address policy; listener is dual-stack.
Actual network exchanges are in test-dimse-ip-family.py.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
# DCMTKVerifySCU.mm was in this list and in no target: C-ECHO is DCMTKQueryNode's.
# The query nodes and the send reach DCMTK through their adapter, whose
# association both use; the listener's C-MOVE sub-association is the adapter's too.
for name in ('Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.mm', 'Adapters/DCMTK/IsiXDCMTKMoveContext.mm'):
    source = (root / 'Horos/Sources' / name).read_text(encoding='latin1')
    assert 'HorosDIMSESetPeerAddress(' in source, name
    assert 'HorosDIMSERequestAssociation(' in source, name
    assert 'sprintf(peerHost,' not in source and 'sprintf(dstHostNamePlusPort,' not in source, name
assert 'IsiXDCMTKAssociation(parameters:' in (root / 'Horos/Sources/DCMTKStoreSCU+Association.swift').read_text()
policy = (root / 'Horos/Sources/HorosDIMSEAssociation.h').read_text()
assert 'hints.ai_family = AF_UNSPEC' in policy
assert 'answer = answer->ai_next' in policy
assert "host.front() == '[' && host.back() == ']'" in policy
assert "address.find_last_of(':')" in policy
assert 'condition.code() != DULC_TCPINITERROR' in policy
# The listener is the DCMTK adapter's.
listener = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.mm').read_text()
assert 'dcmIncomingProtocolFamily.set(ASC_AF_UNSPEC)' in listener
upstream = (root / 'DCMTK/dcmnet/libsrc/dul.cc').read_text()
assert 'IPV6_V6ONLY' in upstream and 'ASC_AF_UNSPEC' in upstream
print('PASS: all clients use checked dual-stack addresses and TCP-only retries; the native listener selects both IP families')
