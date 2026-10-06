#!/usr/bin/env python3
"""Delegates prepare toolbar items after plugins, without undoing earlier toolbar fixes."""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []


def text(relative):
    return (root / relative).read_bytes().decode('latin1')


def require(condition, message):
    if not condition:
        failures.append(message)


delegates = (
    'Horos/Sources/VRController.mm',
    'Horos/Sources/SRController.mm',
)
for path in delegates:
    require('HorosToolbarPolicy prepareItem' in text(path),
            '%s does not prepare toolbar items after plugins' % path)
    source = text(path)
    require('NSToolbarSpaceItemIdentifier' not in source,
            '%s names the AppKit Space directly instead of through ToolbarPolicy' % path)
    require('HorosToolbarPolicy.spaceItemIdentifier' in source
            and 'HorosToolbarPolicy spaceItemForIdentifier' in source,
            '%s does not offer the policy Space and load a saved Horos Space' % path)
    require('HorosToolbarPolicy adoptToolbar' in source,
            '%s does not adopt its toolbar once attached' % path)
# MPRController, XMLController, the orthogonal MPR and PET-CT viewers,
# CPRController and the endoscopy viewer are Swift.
for name in ('MPRController', 'XMLController', 'OrthogonalMPRViewer', 'OrthogonalMPRPETCTViewer',
             'CPRController', 'EndoscopyViewer'):
    swift = sources.source_text(name)
    require('ToolbarPolicy.prepare(toolbarItem)' in swift,
            '%s does not prepare toolbar items after plugins' % name)
    require('NSToolbarItem.Identifier.space.rawValue' not in swift and '.space,' not in swift
            and 'NSToolbarSpaceItemIdentifier' not in swift,
            '%s names the AppKit Space directly instead of through ToolbarPolicy' % name)
    require('ToolbarPolicy.spaceItemIdentifier' in swift and 'ToolbarPolicy.spaceItem(for:' in swift,
            '%s does not offer the policy Space and load a saved Horos Space' % name)
    require('ToolbarPolicy.adopt(toolbar:' in swift,
            '%s does not adopt its toolbar once attached' % name)

# The database window's toolbar delegate is Swift
# (BrowserController+Toolbar.swift), and the viewer's
# (ViewerController+Toolbar.swift): the same checks, in the Swift spelling of
# +[HorosToolbarPolicy ...] (the Swift class is ToolbarPolicy).
for name in ('BrowserController+Toolbar', 'ViewerController+Toolbar'):
    swift_delegate = sources.source_text(name)
    swift_path = sources.source_path(name).relative_to(root)
    require('ToolbarPolicy.prepare(' in swift_delegate,
            '%s does not prepare toolbar items after plugins' % swift_path)
    require('NSToolbarSpaceItemIdentifier' not in swift_delegate
            and re.search(r'\.space\b', swift_delegate) is None,
            '%s names the AppKit Space directly instead of through ToolbarPolicy' % swift_path)
    require('ToolbarPolicy.spaceItemIdentifier' in swift_delegate
            and 'ToolbarPolicy.spaceItem(for:' in swift_delegate,
            '%s does not offer the policy Space and load a saved Horos Space' % swift_path)
    require('ToolbarPolicy.adopt(toolbar:' in swift_delegate,
            '%s does not adopt its toolbar once attached' % swift_path)

viewer = text('Horos/Sources/ViewerController.m')
# What stays of the viewer in Objective-C must not bring the native Space back.
require('NSToolbarSpaceItemIdentifier' not in viewer,
        'Horos/Sources/ViewerController.m names the AppKit Space directly instead of through ToolbarPolicy')
# Fullscreen is the image alone: the whole screen, with the detached panel put away
# on entering and never raised over the image.
require('fullscreenContentRectOnScreen: [self.window.screen frame]]' in viewer and 'reservingPanelHeight' not in viewer,
        'custom fullscreen does not take the whole screen')
fullscreen = viewer[viewer.index('-(IBAction) fullScreenMenu:(id) sender'):viewer.index('- (BOOL) FullScreenON')]
require('[toolbarPanel.window orderOut: self]' in fullscreen and 'toolbarPanelLevelWhenFullScreen' not in viewer,
        'fullscreen keeps the detached toolbar over the image')
require('shouldKeepDetachedToolbarVisibleWhenFullScreen: FullScreenOn' in viewer,
        'the toolbar panel is shown again while fullscreen is on')
require('setStripAboveImage: slider.superview collapsed: YES' in fullscreen and 'setStripAboveImage: slider.superview collapsed: NO restoringHeight: previousSliderStripHeight' in fullscreen,
        'fullscreen leaves the image slider strip over the image, or does not give it back')
panel = (root / 'Horos/Sources/ToolbarPanel.swift').read_text()
require(panel.count('ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen:') == 3,
        'the detached panel can come back by itself while its viewer is in fullscreen')
panel_window = (root / 'Horos/Sources/ToolBarNSWindow.swift').read_text()
order_out = panel_window[panel_window.index('public override func orderOut'):panel_window.index('public override func animationResizeTime')]
require('v?.toolbarPanel?.window !== self || !frontViewerKeepsPanel' in order_out and 'if let v = v, frontViewerKeepsPanel' in order_out
        and 'shouldKeepDetachedToolbarVisible(whenFullScreen: v?.fullScreenON() ?? false)' in order_out,
        'the panel of the front viewer refuses to leave when that viewer goes fullscreen')
vr = text('Horos/Sources/VRController.mm')
require('imageSize.width > 32' not in vr,
        'VR still normalizes icons before plugins have replaced the item')

# ToolbarPanelController is Swift (ToolbarPanel.swift).
panel = sources.source_text('ToolbarPanel')
require('toolbarDidChange' in panel,
        'the detached panel does not remasure when the toolbar is customized')

project = text('Horos.xcodeproj/project.pbxproj')
require('ToolbarPolicy.swift' in project,
        'ToolbarPolicy.swift is not in the Horos target')

require((root / 'Horos/Sources/HorosCellSlider.swift').exists(),
        'HorosCellSlider is missing')
require((root / 'Horos/Sources/ViewerReferenceLines.swift').exists(),
        'ViewerReferenceLines is missing')

for catalog in ('Horos/Resources/es.lproj/Localizable.strings',
                'Horos/Resources/it-IT.lproj/Localizable.strings'):
    require((root / catalog).exists(), '%s disappeared' % catalog)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: viewer, VR, MPR, SR and database toolbars prepare after plugins; '
      'cell sliders and reference lines preserved; ES/IT catalogs untouched')
