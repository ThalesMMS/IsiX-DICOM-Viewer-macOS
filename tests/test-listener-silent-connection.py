#!/usr/bin/env python3
"""A connection that sends nothing costs the listener that connection only.

ASC_receiveAssociation accepts a connection and reads its first PDU on the
calling thread, for as long as the ACSE timeout. Called from the loop that
accepts, a peer that connected and stayed silent kept every other peer, and a
request to stop the listener, waiting for about half a minute.

What must stay true:

- the accepting loop takes the connection and returns: it neither reads from it
  nor calls ASC_receiveAssociation;
- the association request is awaited on a thread of its own, in short waits
  that see a stop, up to the ACSE timeout, and a silent peer is closed and
  logged;
- the socket is handed to DCMTK under the lock that also covers the start of an
  acceptor network, since DCMTK reads one process-wide variable in both;
- the association limit is checked and the association started as one step;
- the server is not destroyed while a connection is still being read.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
server = (root / 'Horos/Sources/HorosQueryRetrieveServer.mm').read_text()
scp = (root / 'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_bytes().decode('latin1')
failures = []


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ''


def check(condition, message):
    if not condition:
        failures.append(message)


loop = body(server, 'OFCondition HorosQueryRetrieveServer::waitForAssociation(')
check(loop, 'waitForAssociation not found')
check('ASC_receiveAssociation(' not in loop.replace('// Only take the connection here. ASC_receiveAssociation', ''),
      'the accepting loop reads the association request itself')
check('accept(DUL_networkSocket(network->network)' in loop, 'the accepting loop does not take the connection')
check('poll(' not in loop and 'recv(' not in loop, 'the accepting loop waits on the connection')
check('detachNewThreadWithBlock' in loop and 'receiveAssociation(network, descriptor' in loop,
      'the association request is not read on a thread of its own')
check('HorosMaximumUnreadConnections' in loop and 'close(descriptor)' in loop,
      'unread connections are not bounded')
check(loop.find('++processes_->receiving') < loop.find('detachNewThreadWithBlock') < loop.find('--processes_->receiving'),
      'a connection being read is not counted for its whole thread')

receive = body(server, 'void HorosQueryRetrieveServer::receiveAssociation(')
check(receive, 'receiveAssociation not found')
wait = receive[:receive.find('ASC_receiveAssociation(')]
check('poll(&waiting, 1, 250)' in wait and 'processes_->stopping' in wait and 'options_.acse_timeout_' in wait,
      'the wait for the first bytes is not bounded or does not see a stop')
check('close(descriptor)' in wait and 'sent nothing' in wait, 'a silent peer is not closed and logged')
adopt = receive[receive.find('HorosDICOMAdoptedSocketMutex()'):receive.find('HorosDIMSEValidateAssociationPDU')]
check(adopt.find('dcmExternalSocketHandle.set(descriptor)') < adopt.find('ASC_receiveAssociation(')
      < adopt.find('dcmExternalSocketHandle.set(DCMNET_INVALID_SOCKET)'),
      'the socket is not handed to DCMTK and withdrawn under the lock')
start = receive[receive.find('processes_->startMutex'):]
check('processes_->active.load() >= maximum' in start and 'HorosStartAssociationTask(' in start,
      'the association limit and the start are not one step')

destructor = body(server, 'HorosQueryRetrieveServer::~HorosQueryRetrieveServer()')
check('processes_->receiving.load()' in destructor, 'the server can be destroyed while a connection is being read')

network = scp.find('ASC_initializeNetwork(NET_ACCEPTORREQUESTOR')
check(network > 0 and 'HorosDICOMAdoptedSocketMutex()' in scp[network - 200:network],
      'the acceptor network starts outside the adopted-socket lock')

if failures:
    raise SystemExit('FAIL: ' + '; '.join(failures))
print('PASS: the accepting loop only accepts; requests are read per connection, bounded and stoppable')
