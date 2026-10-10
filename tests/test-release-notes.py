#!/usr/bin/env python3
"""The About window's release notes are those of the latest published release.

The Release Notes tab loads the bundled page and then sets in it the notes
GitHub gives for the latest release, fetched apart from the web view. This
compiles the production reader and checks:

1. Only a published release with a name and some notes is read; a draft, a
   pre-release, an empty body or an oversized answer is not, and a release page
   outside this application's releases is replaced by the latest release's.
2. The notes reach the page as escaped text in the few tags the reader writes:
   headings, lists, paragraphs, code, bold and http(s) links. Markup and other
   link schemes in a release's text stay text.
3. A fetch answers once on the main queue, with nothing for an HTTP failure or
   a URL that is not HTTPS.
4. The bundled page has the element the notes are set in, and the About
   window's link is this application's page in every localization.

    python3 tests/test-release-notes.py
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]

code = r'''
import Foundation

final class NotesProtocol: URLProtocol {
    static var responses: [String: (Int, Data)] = [:]
    static var requested: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requested.append(request.url!.path)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        let result = Self.responses[request.url!.path]!
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

// 1
let release: [String: Any] = [
    "name": "IsiX DICOM Viewer 9.8.7", "tag_name": "v9.8.7", "draft": false, "prerelease": false,
    "published_at": "2026-10-10T18:48:41Z",
    "html_url": "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/tag/v9.8.7",
    "body": "Summary of the release.\r\n\r\n### Viewer\r\n\r\n- First\r\n- Second\r\n"]
let notes = ReleaseNotes(json: json(release))!
precondition(notes.title == "IsiX DICOM Viewer 9.8.7" && notes.published != nil)
precondition(notes.page.absoluteString == "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/tag/v9.8.7")
func changed(_ key: String, _ value: Any?) -> Data {
    var copy = release
    copy[key] = value
    return json(copy)
}
precondition(ReleaseNotes(json: changed("draft", true)) == nil && ReleaseNotes(json: changed("prerelease", true)) == nil)
precondition(ReleaseNotes(json: changed("body", " \n")) == nil && ReleaseNotes(json: changed("body", nil)) == nil)
precondition(ReleaseNotes(json: changed("body", String(repeating: "a", count: ReleaseNotes.maximumSize))) == nil)
precondition(ReleaseNotes(json: Data("[1]".utf8)) == nil && ReleaseNotes(json: Data("<html>".utf8)) == nil)
precondition(ReleaseNotes(json: changed("name", ""))!.title == "v9.8.7")
precondition(ReleaseNotes(json: json(release.filter { $0.key != "name" && $0.key != "tag_name" })) == nil)
for elsewhere in ["https://example.invalid/releases/tag/v1", "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS.example.invalid/releases/x",
                  "javascript:alert(1)", ""] {
    precondition(ReleaseNotes(json: changed("html_url", elsewhere))!.page == ReleaseNotes.latestPageURL)
}
precondition(ReleaseNotes(json: changed("published_at", "yesterday"))!.published == nil)
print("PASS: only a published release with a name and notes is read, and its page is one of this application's releases")

// 2
precondition(ReleaseNotes.html(markdown: notes.body) ==
    "<p>Summary of the release.</p>\n<h3>Viewer</h3>\n<ul>\n<li>First</li>\n<li>Second</li>\n</ul>")
let page = notes.html
precondition(page.hasPrefix("<div class=\"content-block\">\n<div class=\"version\">IsiX DICOM Viewer 9.8.7</div> <span class=\"release-date\">"))
precondition(page.hasSuffix("<p><a href=\"https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/tag/v9.8.7\">View this release on GitHub</a></p>\n</div>"))
precondition(ReleaseNotes.html(markdown: "# One\n## Two\nText that\nwraps.\n\n1. First\n2. Second\n   continued\n- Other\n* Kind\nAfter") ==
    "<h3>One</h3>\n<h3>Two</h3>\n<p>Text that wraps.</p>\n<ol>\n<li>First</li>\n<li>Second continued</li>\n</ol>\n<ul>\n<li>Other</li>\n<li>Kind</li>\n</ul>\n<p>After</p>")
precondition(ReleaseNotes.inline("Use `-[A b:]` and **bold `c`**, see [the page](https://example.invalid/a?b=1&c=2).") ==
    "Use <code>-[A b:]</code> and <strong>bold <code>c</code></strong>, see <a href=\"https://example.invalid/a?b=1&amp;c=2\">the page</a>.")
// Nothing a release says becomes markup, and only http(s) links are links.
let hostile = "<script>alert(1)</script> <img src=x onerror=\"y\"> [x](javascript:alert(1)) [y](file:///etc/hosts) `<b>` a ** b & c #not-a-heading 2.x"
let rendered = ReleaseNotes.html(markdown: hostile + "\n\n### <i>h</i>\n- <u>item</u>")
precondition(rendered == "<p>&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=x onerror=&quot;y&quot;&gt; [x](javascript:alert(1)) [y](file:///etc/hosts) "
    + "<code>&lt;b&gt;</code> a ** b &amp; c #not-a-heading 2.x</p>\n<h3>&lt;i&gt;h&lt;/i&gt;</h3>\n<ul>\n<li>&lt;u&gt;item&lt;/u&gt;</li>\n</ul>")
let tags = try! NSRegularExpression(pattern: "<[^>]*>")
let written = Set(tags.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)).map { (rendered as NSString).substring(with: $0.range) })
precondition(written.isSubset(of: ["<p>", "</p>", "<h3>", "</h3>", "<ul>", "</ul>", "<li>", "</li>", "<code>", "</code>"]))
let titled = ReleaseNotes(title: "<b>T</b>", published: nil, body: "x", page: ReleaseNotes.latestPageURL).html
precondition(titled.contains("<div class=\"version\">&lt;b&gt;T&lt;/b&gt;</div>\n<p>x</p>"))
print("PASS: the notes become headings, lists, paragraphs, code, bold and http(s) links; anything else a release says stays text")

// 3
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [NotesProtocol.self]
let session = URLSession(configuration: configuration)
NotesProtocol.responses = ["/latest": (200, json(release)), "/missing": (404, json(release)), "/html": (200, Data("<html>".utf8))]
var answers: [String: ReleaseNotes?] = [:]
for path in ["/latest", "/missing", "/html"] {
    ReleaseNotes.fetch(url: URL(string: "https://fixture.invalid" + path)!, session: session) { notes in
        precondition(Thread.isMainThread && answers[path] == nil)
        answers[path] = notes
    }
}
ReleaseNotes.fetch(url: URL(string: "http://fixture.invalid/latest")!, session: session) { notes in
    precondition(Thread.isMainThread && notes == nil)
    answers["http"] = notes
}
let deadline = Date().addingTimeInterval(10)
while answers.count < 4 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(answers.count == 4 && answers["/latest"]! == notes && answers["/missing"]! == nil && answers["/html"]! == nil)
precondition(NotesProtocol.requested.sorted() == ["/html", "/latest", "/missing"], "a URL that is not HTTPS must not be requested")
precondition(ReleaseNotes.latestURL.absoluteString == "https://api.github.com/repos/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/latest")
precondition(UpdateFeedClient.releaseNotesURL.absoluteString == "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/latest")
session.invalidateAndCancel()
print("PASS: a fetch answers once on the main queue, with nothing for an HTTP failure, another document or a URL that is not HTTPS")
'''

failures = 0


def fail(message):
    global failures
    print('FAIL: ' + message)
    failures += 1


with tempfile.TemporaryDirectory(prefix='horos-release-notes-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(code)
    built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'notes', str(root / 'Horos/Sources/ReleaseNotes.swift'),
                            str(root / 'Horos/Sources/UpdateFeedClient.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        fail('the release notes reader does not build: ' + built.stderr[-3000:])
    else:
        result = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
        print((result.stdout + result.stderr).strip())
        if result.returncode != 0:
            failures += 1

# ---------------------------------------------------------------- 4

page = (root / 'Binaries/Splash/releasenotes.html').read_text(encoding='utf-8')
splash = (root / 'Horos/Sources/SplashScreen.swift').read_text(encoding='utf-8')
if len(re.findall(r'<div id="content">', page)) != 1 or "document.getElementById('content')" not in splash:
    fail('the bundled page has no single "content" element for the notes, or the About window sets them elsewhere')
if not re.search(r'<div class="version">IsiX DICOM Viewer \d+\.\d+\.\d+</div>', page):
    fail('the bundled page does not name the release its notes belong to')
opened = re.findall(r'URL\(string: "([^"]*)"\)', splash)
if opened != ['https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS']:
    fail('the About window\'s link does not open this application\'s page')
nibs = sorted((root / 'Horos/Resources').glob('*.lproj/Splash.xib'))
elsewhere = [nib.parent.name for nib in nibs if 'horosproject.org' in nib.read_text(encoding='utf-8')]
if elsewhere or not nibs:
    fail('Splash.xib still shows the Horos Project\'s address in: ' + ', '.join(elsewhere))
if failures == 0:
    print('PASS: the bundled page takes the notes in its content element, and the %d About nibs link to this application\'s page' % len(nibs))

sys.exit(1 if failures else 0)
