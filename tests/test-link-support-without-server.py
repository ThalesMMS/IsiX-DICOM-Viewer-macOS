#!/usr/bin/env python3
"""The links run without the XML-RPC server, and only the server opens a port.

One switch used to turn on both the isix://, horos:// and osirix:// links and
the server of the network. A link reaches the application as an Apple Event
and its method runs in the process, so the links have a switch of their own
and the interface that carries the methods out opens no port: the port is the
network server's, made only while the server is turned on.

Read from the sources: who opens the port, what a link reads, what the launch
makes with each switch, where the settings of before are brought over, and the
two boxes of the Listener pane in each of its languages. The rule of the
migration and the registered values have their own tests in IsiXPreferences.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def read(relative):
    return (root / relative).read_text(encoding='utf-8')


def without_comments(text):
    return '\n'.join(line for line in text.split('\n') if not line.lstrip().startswith('//'))


# --- the interface opens no port; the network server does --------------------
interface = without_comments(read('Horos/Sources/XMLRPCInterface.swift'))
server = without_comments(read('Horos/Sources/XMLRPCNetworkServer.swift'))
check('XMLRPCListener(' not in interface and 'xmlrpcServerPort' not in interface,
      'the interface a link calls opens the port of the XML-RPC server again')
check('XMLRPCListener(port: port, https: https)' in server and 'listener.stop()' in server,
      'the network server no longer opens and closes the port')
check('[weak interface]' in server, 'the network server retains the interface it answers through')
openers = sorted(path.name for path in (root / 'Horos/Sources').glob('*.swift')
                 if 'XMLRPCListener(port:' in without_comments(path.read_text(encoding='utf-8')))
check(openers == ['XMLRPCNetworkServer.swift'], 'the port of the XML-RPC server is opened in %s' % ', '.join(openers))

# --- the launch: the port only with the server -------------------------------
lifecycle = without_comments(read('Horos/Sources/ApplicationLifecycle.swift'))
makers = [match.start() for match in re.finditer(r'XMLRPCNetworkServer\(interface:', lifecycle)]
check(len(makers) == 1, 'the network server is made in %d places of the lifecycle' % len(makers))
if makers:
    before = lifecycle[:makers[0]]
    branch = before[before.rindex('if preferences[NetworkPreferences.'):]
    check(branch.startswith('if preferences[NetworkPreferences.xmlrpcServer] {'), 'the network server is not made under the switch of the server')
    check('else if preferences[NetworkPreferences.linkSchemeSupport]' not in branch, 'the switch of the links makes the network server')
    check('ProtectedMode.isActive' in branch, 'protected mode no longer skips the XML-RPC server')
after = lifecycle[makers[0]:] if makers else ''
links_only = after[:after.index('processGraph.applicationMenus')] if 'processGraph.applicationMenus' in after else ''
check(re.search(r'\} else if preferences\[NetworkPreferences\.linkSchemeSupport\] \{\s*_ = requestInterface\(\)\s*\}', links_only),
      'with the links on and the server off, the launch no longer makes the interface alone')
request_interface = lifecycle[lifecycle.index('func requestInterface() -> XMLRPCInterface? {'):]
request_interface = request_interface[:request_interface.index('\n    }\n')]
check('!ProtectedMode.isActive' in request_interface and 'XMLRPCNetworkServer' not in request_interface,
      'the interface of the links is made in protected mode, or brings the network server with it')
check('xmlrpcNetworkServer = nil' in lifecycle, 'the port is not closed as the application ends')

# --- a link reads its own switch and never the server's ----------------------
handler = without_comments(read('Horos/Sources/ExternalRequestHandler.swift'))
check('if !preferences[NetworkPreferences.linkSchemeSupport] {' in handler, 'a link is not held by the switch of the links')
check('NetworkPreferences.xmlrpcServer' not in handler.replace('NetworkPreferences.xmlrpcServerShowsFailureAlerts', ''),
      'a link reads or writes a setting of the XML-RPC server')
check('LinkRequest(server: controller.lifecycle.requestInterface(),' in handler,
      'a link no longer asks the lifecycle for the interface, which is made when the links are turned on')
check('XMLRPCAccessPolicy' not in handler, 'the alert of a link still describes who the server answers')
startup = without_comments(read('Horos/Sources/LinkSchemeStartupCheck.swift'))
check('preferences[NetworkPreferences.linkSchemeSupport]' in startup and 'NetworkPreferences.xmlrpcServer' not in startup,
      'the check of who opens the schemes reads the switch of the server')

# --- the settings of before are brought over before a link is read -----------
setup = without_comments(read('Horos/Sources/ApplicationPreferencesSetup.swift'))
register = setup[setup.index('static func register() {'):]
register = register[:register.index('\n    }\n')]
check('migrateLinkSupport()' in register and register.index('migrateLinkSupport()') < register.index('DatabaseFirstUse.prepare'),
      'the switch of the links is not stored as the preferences are registered')
migrate = setup[setup.index('private static func migrateLinkSupport() {'):]
migrate = migrate[:migrate.index('\n    }\n')]
check(migrate.index('XMLRPCServerAccess.migrateLegacyPreferences(in: preferences)') < migrate.index('LinkSupportMigration.writes('),
      'the scope of the two former switches is not stored before the links are brought over')
check('preferences.persistentDomain(forName: $0)' in migrate and 'preferences[NetworkPreferences.xmlrpcServer]' not in migrate,
      'the migration reads what a launch was given as an argument, not what the user stored')

# --- the pane: two boxes, in every language ----------------------------------
xibs = [root / 'Preference Panes/OSIListenerPreferencePane' / lproj / 'OSIListenerPreferencePanePref.xib' for lproj in ('Base.lproj', 'ja-JP.lproj')]
xibs += sorted((root / 'Horos/Resources').glob('*.lproj/OSIListenerPreferencePanePref.xib'))
check(len(xibs) == 10, 'the Listener pane has %d nibs' % len(xibs))
SERVER_ONLY = {'values.httpXMLRPCServerHTTPS', 'values.httpXMLRPCServerAccessScope', 'values.httpXMLRPCServerAllowedAddresses',
               'values.httpXMLRPCServerDoNotRespond'}
EITHER = {'values.XMLRPCWithPOD', 'values.CloseAllWindowsBeforeXMLRPCOpen', 'values.bringOsiriXToFrontAfterReceivingMessage',
          'values.httpXMLRPCServerWaitForStudy', 'values.httpXMLRPCServerShowFailureAlerts'}
titles = {}
for xib in xibs:
    name = str(xib.relative_to(root))
    tree = ET.parse(xib)
    parents = {child: parent for parent in tree.iter() for child in parent}
    bound = {}
    for binding in tree.iter('binding'):
        control = parents[parents[binding]]
        bound.setdefault(control, {})[binding.get('name')] = binding.get('keyPath')
    by_value = {}
    for control, bindings in bound.items():
        key = bindings.get('value') or bindings.get('selectedTag')
        if key:
            by_value.setdefault(key, []).append((control, bindings))
    links = by_value.get('values.LinkSchemeSupport', [])
    servers = by_value.get('values.httpXMLRPCServer', [])
    check(len(links) == 1 and len(servers) == 1, '%s: %d boxes of the links and %d of the server' % (name, len(links), len(servers)))
    if len(links) != 1 or len(servers) != 1:
        continue
    (link, link_bindings), (box, server_bindings) = links[0], servers[0]
    check('enabled' not in link_bindings and 'enabled' not in server_bindings, '%s: one switch dims the other' % name)
    link_title, server_title = link.find('buttonCell').get('title'), box.find('buttonCell').get('title')
    check('isix://' in link_title and 'horos://' in link_title and 'osirix://' in link_title, '%s: the box of the links does not name the three schemes' % name)
    check('XML-RPC' in server_title and 'URL' not in server_title, '%s: the box of the server still names the URL support: %s' % (name, server_title))
    titles.setdefault(link_title, []).append(name)
    # Both in the box that holds the port, the links above the server.
    check(parents[link] is parents[box], '%s: the two boxes are not in the same view' % name)
    link_frame, server_frame = link.find('rect'), box.find('rect')
    check(float(link_frame.get('y')) >= float(server_frame.get('y')) + float(server_frame.get('height')), '%s: the box of the links is not above the server\'s' % name)
    height = float(parents[parents[link]].find('rect').get('height'))
    check(float(link_frame.get('y')) + float(link_frame.get('height')) <= height, '%s: the box of the links is outside its view' % name)
    for key in SERVER_ONLY:
        for control, bindings in by_value.get(key, []):
            check(bindings.get('enabled') == 'values.httpXMLRPCServer', '%s: %s does not follow the server' % (name, key))
        check(key in by_value, '%s: no control bound to %s' % (name, key))
    for key in EITHER:
        for control, bindings in by_value.get(key, []):
            check('enabled' not in bindings, '%s: %s follows one switch in the nib; the pane enables it with either' % (name, key))
        check(key in by_value, '%s: no control bound to %s' % (name, key))
check(len(titles) == 10, 'the box of the links is not written in each language: %d titles in 10 nibs' % len(titles))

pane = without_comments(read('Preference Panes/OSIListenerPreferencePane/OSIListenerPreferencePanePref.swift'))
for key in ('xmlrpcWithPACSOnDemand', 'closeAllWindowsBeforeXMLRPCOpen', 'bringOsiriXToFrontAfterReceivingMessage',
            'xmlrpcServerWaitForStudy', 'xmlrpcServerShowsFailureAlerts'):
    check('NetworkPreferences.controllerKeyPath(NetworkPreferences.%s)' % key in pane, 'the pane no longer enables %s with either switch' % key)
check('setRequestOptions(enabled: serverOn || defaults.bool(forKey: NetworkPreferences.linkSchemeSupport.name)' in pane,
      'the options of the requests are not enabled with the links or the server')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the interface opens no port, the server opens it under its own switch, a link reads the switch of the links, '
      'the settings of before are brought over at registration, and the ten nibs have the two boxes')
