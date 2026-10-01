#!/usr/bin/env python3
"""A session made while a portal page is prepared reaches that page's templates.

The templates read `%Session.…%` from the response's tokens. The tokens were
filled before the page was prepared, and only with a session that already
existed: on the first request of a visitor without a cookie, the session is
made later, when the page stores its paging values in it, so the study list
rendered `printPagesHTML(, , "…")` and the browser stopped on a syntax error.
The connection now hands a session to the tokens when it makes one.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
connection = source_text('WebPortalConnection')
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


start = connection.index('@objc public var session: WebPortalSession! {')
accessor = connection[start:connection.index('private func requestHeader', start)]
getter = accessor[:accessor.index('        set {')]
made = getter.find('self.session = portal?.newSession()')
token = getter.find('response?.tokens.setObject(made, forKey: "Session" as NSString)')
require(made != -1 and token > made, 'a session made by the accessor is not handed to the response\'s tokens')
require(getter.find('response?.setSessionId(sessionValue?.sid)') > token > -1, 'the cookie of a new session is set before the session reaches the tokens')

# A session that exists before the page is prepared still reaches the tokens there.
reply = connection[connection.index('private func replyToHTTPRequestUnguarded()'):]
reply = reply[:reply.index('super.replyToHTTPRequest()')]
require('fillSessionAndUserVariables()' in reply and 'response?.tokens.setObject(session, forKey: "Session" as NSString)' in reply,
        'the session found from the cookie no longer reaches the tokens')
require(reply.index('self.response = WebPortalResponse(webPortalConnection: self)') < reply.index('fillSessionAndUserVariables()'),
        'the response is made after the session is looked for: a session made on login would miss its tokens')

# The values the study list's pager reads are the ones the page stores in the session.
data = source_text('WebPortalConnection+Data')
template = (root / 'Horos/Resources/WebServicesHTML/English/studyList.html').read_text(errors='replace')
for key in ('NumberOfPages', 'Page', 'FetchLimitPerPage', 'NumberOfStudies'):
    require('%%Session.%s%%' % key in template, 'the study list no longer reads Session.%s' % key)
    require('forKey: "%s")' % key in data, 'the study list page no longer stores %s in the session' % key)

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a session made while the page is prepared is in the page\'s tokens, with the pager\'s values')
