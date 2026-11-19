#!/usr/bin/env python3
"""A preference pane taller than the window shows a vertical scroller.

The settings window grows with the selected pane only up to the screen's
height. The pane is shown in a scroll view that had no vertical scroller, so on
a screen of 1050 points the bottom 165 points of the Locations pane (1083 points
high in a window showing 918) were hidden, reachable only by a scrolling gesture
and with nothing to tell they were there.

PreferencesFlippedView, cut from PreferencesWindowController.swift, is compiled
with a harness that shows a pane 1083 points high in a window 918 points high:
the scroll view must show its vertical scroller (the legacy style, whose
scrollers stay visible), reach the pane's bottom, and hide the scroller for a
pane that fits. With the legacy style the window's content is widened by the
scroller's width, so that the scroller does not cover the pane's right edge.
`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/PreferencesWindowController.swift'
source = (subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode() if revision
          else (root / path).read_text())

start = source.index('final class PreferencesFlippedView: NSView {')
end = source.index('\n}\n', start) + 3
flipped = source[start:end]

if 'func enclosedInScrollView()' not in flipped:
    # The former controller built the scroll view inline, without a vertical scroller.
    inline = source[source.index('let sv = NSScrollView('):source.index('window?.contentView = sv')]
    print('FAIL: the pane\'s scroll view is built in -setCurrentContext:'
          + ('' if 'hasVerticalScroller = true' in inline else ' without a vertical scroller')
          + '; a pane taller than the window hides its bottom')
    sys.exit(1)

main = r'''
import AppKit

_ = NSApplication.shared
var failures: [String] = []

/// A pane `height` points high, 600 wide, shown in a window whose content is `visible` points high.
@MainActor func show(height: CGFloat, visible: CGFloat, style: NSScroller.Style) -> (NSScrollView, NSWindow) {
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
    let flipped = PreferencesFlippedView(frame: pane.frame)
    flipped.translatesAutoresizingMaskIntoConstraints = false
    flipped.addSubview(pane)
    flipped.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "|[pane]|", options: [], metrics: nil, views: ["pane": pane]))
    flipped.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[pane]|", options: [], metrics: nil, views: ["pane": pane]))
    let scrollView = flipped.enclosedInScrollView()
    scrollView.scrollerStyle = style
    let width = PreferencesFlippedView.contentWidth(forPane: NSSize(width: 600, height: height), visibleHeight: visible, scrollerStyle: style)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: visible), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scrollView
    window.layoutIfNeeded()
    scrollView.tile()
    return (scrollView, window)
}

MainActor.assumeIsolated {
    let (tall, tallWindow) = show(height: 1083, visible: 918, style: .legacy)
    if !tall.hasVerticalScroller || tall.verticalScroller == nil || tall.verticalScroller!.isHidden {
        failures.append("a pane 1083 points high in a window showing 918 has no visible vertical scroller")
    }
    let documentHeight = tall.documentView?.frame.height ?? 0
    if documentHeight < 1083 { failures.append("the scroll view's document is \(documentHeight) points high, not the pane's 1083") }
    tall.contentView.scroll(to: NSPoint(x: 0, y: documentHeight - tall.contentView.bounds.height))
    tall.reflectScrolledClipView(tall.contentView)
    if tall.contentView.documentVisibleRect.maxY < 1083 - 0.5 {
        failures.append("scrolled to the end, the pane shows down to \(tall.contentView.documentVisibleRect.maxY), not 1083")
    }
    if tall.contentView.bounds.width < 600 - 0.5 {
        failures.append("beside a legacy scroller the pane shows \(tall.contentView.bounds.width) of its 600 points")
    }
    _ = tallWindow

    let (short, shortWindow) = show(height: 400, visible: 918, style: .legacy)
    if let scroller = short.verticalScroller, !scroller.isHidden {
        failures.append("a pane that fits the window shows a vertical scroller")
    }
    _ = shortWindow

    let widths = [PreferencesFlippedView.contentWidth(forPane: NSSize(width: 600, height: 1083), visibleHeight: 918, scrollerStyle: .overlay),
                  PreferencesFlippedView.contentWidth(forPane: NSSize(width: 600, height: 400), visibleHeight: 918, scrollerStyle: .legacy)]
    if widths != [600, 600] { failures.append("the content is widened (\(widths)) where no scroller takes room") }
}
for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-pane-scroller-') as tmp:
    p = Path(tmp)
    (p / 'Flipped.swift').write_text('import AppKit\n\n' + flipped)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(p / 'Flipped.swift'), str(p / 'main.swift'),
                            '-o', str(p / 'harness')], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-3000:])
        print('FAIL: PreferencesFlippedView does not compile with the harness')
        sys.exit(1)
    run = subprocess.run([str(p / 'harness')], capture_output=True, text=True, timeout=120)
    print(run.stdout, end='')
    if run.returncode:
        if 'FAIL:' not in run.stdout:
            print(f'FAIL: the harness stopped with status {run.returncode}: {run.stderr[-600:]}')
        sys.exit(1)

print('PASS: a pane taller than the window shows a vertical scroller and reaches its bottom; a pane that fits shows none')
