#!/usr/bin/env python3
"""Coming back to the session does not stop the main thread.

With fast user switching, the application slept four seconds on the main
thread every time its session became active again, before looking at anything:
also with "run the listener only in the active session" off, the factory
setting, where nothing had been stopped and nothing was started afterwards.

What must stay true:

- no sleep in the handler;
- a session whose listener was not stopped, and is not to be restarted,
  returns at once;
- otherwise the wait for the other session to give up the ports is a delayed
  block, the session stays inactive for its readers until then, and a session
  that resigned again meanwhile drops the restart.

Leaving the session stops the listener in this order: abort the listeners,
abort the DICOM processes, then wait for each listener to leave its loop, which
it does within the second its server waits for an association. Nothing is sent
to the listener's own port: a C-ECHO there found the port already closed and
held the main thread until the connection timed out. Quitting the application
aborts the listeners too, and waits for their threads to end before exit()
destroys the DCMTK loggers they read.

AppController is Swift: its part is read in the Swift spelling.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

failures = []
controller = source_text('AppController')


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


handler = body(controller, 'func switchHandler(')
check(handler, 'switchHandler not found')
check('Thread.sleep' not in handler and 'usleep' not in handler, 'the session handler still sleeps')

at = handler.find('NSWorkspace.sessionDidBecomeActiveNotification')
check(at > 0, 'the handler does not look at the session becoming active')
resigned, active = handler[:at], handler[at:]

# Leaving the session: the listener is stopped, and the session marked, only on request.
stop = re.search(r'if UserDefaults\.standard\.bool\(forKey: "RunListenerOnlyIfActive"\) \{(.*?)\n            \}', resigned, re.S)
check(stop and 'killDICOMListenerWait(true)' in stop.group(1) and 'isSessionInactive = true' in stop.group(1),
      'the listener is not stopped, or the session not marked inactive, under the setting alone')

# Coming back: nothing to wait for unless a listener was stopped or is to be started.
guard = active.find('guard isSessionInactive || UserDefaults.standard.bool(forKey: "RunListenerOnlyIfActive") else { return }')
delayed = active.find('DispatchQueue.main.asyncAfter(deadline: .now() + AppController.sessionPortHandover)')
check(guard > 0, 'a session with nothing stopped does not return at once')
check(delayed > guard > 0, 'the wait for the ports is not a delayed block after the early return')
check('isSessionInactive = false' not in active[:delayed],
      'the session is marked active before its listeners are started')
later = active[delayed:]
check(re.search(r'sessionSwitches == awaited else \{ return \}.*isSessionInactive = false.*restartSTORESCP\(\)', later, re.S),
      'the delayed block does not check the switch, mark the session active and start the listeners, in that order')
check(handler.count('sessionSwitches += 1') == 2, 'each switch of the session is not counted')
check(re.search(r'sessionPortHandover: TimeInterval = 4\b', controller), 'the port handover is no longer four seconds')

# Leaving the session: abort, then wait for the loop to end; no C-ECHO to wake it.
stopping = body(controller, 'public func killDICOMListenerWait(_ w: Bool)')
check(stopping, 'killDICOMListenerWait not found')
check('QueryController.echo' not in stopping and 'echoServer' not in stopping,
      'the listener stop still sends a C-ECHO to its own port')
order = [stopping.find(step) for step in ('listeners.plain?.abort()', 'listeners.tls?.abort()', 'self.killAllStoreSCU(self)',
                                          'while AppController.listeners().plain?.running()', 'while AppController.listeners().tls?.running()',
                                          'dcmtkQRSCP = nil')]
check(all(at > 0 for at in order) and order == sorted(order),
      'the listeners are not aborted, the processes stopped and the loops awaited, in that order')
server = (root / 'Horos/Sources/HorosQueryRetrieveServer.mm').read_bytes().decode('latin1')
check('if (!ASC_associationWaiting(network, 1)) return EC_Normal;' in body(server, 'OFCondition HorosQueryRetrieveServer::waitForAssociation('),
      'the listener no longer reads the abort within a second of waiting')
scp = (root / 'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_bytes().decode('latin1')
check(re.search(r'while\(!_abort\)\s*\{.*?if\( _abort == NO\)\s*cond = localSCP->waitForAssociation', scp, re.S),
      'the listener loop does not look at the abort before each wait')
quitting = body(controller, 'func finishTermination(_ sender: Any!)')
check('AppController.stopListeners(before: Date(timeIntervalSinceNow: 10))' in quitting, 'quitting no longer stops the listeners')
# exit() destroys DCMTK's static loggers: a listener thread still in its
# one-second wait for an association crashed reading them. Quitting waits for
# the listener threads to end, not for a fixed pause shorter than that wait.
check('Thread.sleep(forTimeInterval: 0.5)' not in quitting
      and 0 <= quitting.find('stopListeners(') < quitting.find('NSApp.terminate('),
      'quitting reaches exit() without waiting for the listener threads to end')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('ok')
