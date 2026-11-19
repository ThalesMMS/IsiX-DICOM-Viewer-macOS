#!/usr/bin/env python3
"""A click on a tool of the orthogonal viewers' palette chooses that tool.

The «Mouse button function» palette of the orthogonal MPR window and of the
orthogonal PET-CT window is a matrix whose cells carry the tool in their tag;
its action is changeTool:, which a menu item also sends, with the tool in its
own tag. The tag of the matrix itself is 0, the window level tool. The action
must ask any matrix for its selected cell: the nibs make the palette of a
subclass of NSMatrix, and an action that only knew a matrix of that exact
class read the tag of the matrix, so every click chose window level.

The text of changeTool(_:) of both viewers, with the helper it reads the tag
through, is compiled as it is into an object that records the tool it is asked
to set. The senders are the palette of each window's own nib, compiled and
loaded with the class the nib names, each cell clicked in turn; a plain
NSMatrix; another subclass of NSMatrix; and a menu item.

`<git revision>` as an optional argument reads the two viewers from that
revision: that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from copy import deepcopy
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
# viewer source, its nib, the id of the palette in the nib
VIEWERS = (
    ('OrthogonalMPRViewer', 'OrthogonalMPR', '62'),
    ('OrthogonalMPRPETCTViewer', 'PETCT', '39'),
)
CLASS = 'IsiXTipMatrix'


def source_of(name):
    relative = f'Horos/Sources/{name}.swift'
    if revision is None:
        return (root / relative).read_text(encoding='utf-8')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def block(text, start, what):
    """The declaration that begins at `start`, to its closing brace."""
    begin = text.index(start)
    depth = 0
    for index in range(text.index('{', begin), len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[begin:index + 1]
    sys.exit(f'{what}: the declaration does not end')


def harness(name):
    text = source_of(name)
    action = block(text, '    @IBAction @objc(changeTool:)', f'{name} changeTool')
    helper = block(text, 'private func tagOf(', f'{name} tagOf')
    return f'''
import AppKit

{helper}

@MainActor
final class {name}Probe: NSObject, ToolProbe {{
    var chosen: [Int16] = []
    func setCurrentTool(_ tool: ToolMode) {{ chosen.append(tool.rawValue) }}

{action}
}}
'''


MAIN = r'''
import AppKit

/// The tools, as the C enumeration reaches Swift: a raw value that may fail.
struct ToolMode: RawRepresentable {
    let rawValue: Int16
    init?(rawValue: Int16) { self.rawValue = rawValue }
}

@MainActor
protocol ToolProbe: NSObject {
    var chosen: [Int16] { get set }
    func changeTool(_ sender: Any!)
}

/// A matrix of a class of its own, as a nib may ask for.
final class OtherMatrix: NSMatrix {}

@main struct Test {
    @MainActor static func main() {
        _ = NSApplication.shared
        var failures: [String] = []
        let arguments = Array(CommandLine.arguments.dropFirst())
        let probes: [(String, ToolProbe, String)] = [
            ("OrthogonalMPRViewer", OrthogonalMPRViewerProbe(), arguments[0]),
            ("OrthogonalMPRPETCTViewer", OrthogonalMPRPETCTViewerProbe(), arguments[1]),
        ]
        for (name, probe, path) in probes {
            func expect(_ tool: Int16?, _ context: String, _ send: () -> Void) {
                probe.chosen = []
                send()
                let got = probe.chosen
                if got != (tool.map { [$0] } ?? []) {
                    failures.append("\(name): \(context): asked for the tool \(tool.map(String.init) ?? "none"), set \(got)")
                }
            }

            // The palette of the window's own nib, each cell clicked in turn.
            let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
            var top: NSArray?
            guard nib.instantiate(withOwner: nil, topLevelObjects: &top),
                  let palette = (top ?? []).compactMap({ $0 as? NSMatrix }).first else {
                failures.append("\(name): the palette of the nib did not load"); continue
            }
            if type(of: palette) == NSMatrix.self {
                failures.append("\(name): the palette loaded as a plain NSMatrix: the nib's class is not the one under test")
            }
            if palette.tag != 0 || !palette.cells.contains(where: { $0.tag > 0 }) {
                failures.append("\(name): the palette has the tag \(palette.tag) and the cell tags \(palette.cells.map(\.tag))")
            }
            palette.target = probe
            palette.action = NSSelectorFromString("changeTool:")
            for cell in palette.cells {
                expect(Int16(cell.tag), "\(type(of: palette)) of the nib, cell «\(cell.title)» tag \(cell.tag)") {
                    palette.selectCell(withTag: cell.tag)
                    palette.sendAction()
                }
            }

            // Matrices made here: the plain class and another subclass.
            for kind in [NSMatrix.self, OtherMatrix.self] as [NSMatrix.Type] {
                let matrix = kind.init(frame: NSRect(x: 0, y: 0, width: 120, height: 20), mode: .radioModeMatrix,
                                       cellClass: NSButtonCell.self, numberOfRows: 1, numberOfColumns: 3)
                for (index, cell) in matrix.cells.enumerated() { cell.tag = [0, 5, 7][index] }
                for tag in [5, 7, 0] {
                    expect(Int16(tag), "\(kind) made in code, cell tag \(tag)") {
                        matrix.selectCell(withTag: tag)
                        probe.changeTool(matrix)
                    }
                }
            }

            // A menu item carries the tool in its own tag.
            let item = NSMenuItem(title: "Tool", action: nil, keyEquivalent: "")
            item.tag = 6
            expect(6, "menu item with the tag 6") { probe.changeTool(item) }
            item.tag = -1
            expect(nil, "menu item with the tag -1") { probe.changeTool(item) }
            print("\(name): \(palette.cells.count) cells of the nib's \(type(of: palette)), two matrices made in code and a menu item")
        }
        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
            exit(1)
        }
    }
}
'''


def palette_nib(nib_name, identifier, work):
    """The palette alone, with its class and its cells, in a nib of its own."""
    path = root / f'Horos/Resources/en.lproj/{nib_name}.xib'
    source = ET.fromstring(path.read_bytes())
    matrix = source.find(f'.//matrix[@id="{identifier}"]')
    if matrix is None or matrix.get('customClass') != CLASS:
        sys.exit(f'FAIL: {nib_name}.xib: the tool palette ({identifier}) is not a {CLASS} matrix')
    document = ET.Element('document', source.attrib)
    for dependency in source.findall('dependencies'):
        document.append(deepcopy(dependency))
    objects = ET.SubElement(document, 'objects')
    ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='NSObject')
    ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
    ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
    matrix = deepcopy(matrix)
    for node in matrix.iter():
        # The images belong to the application; the action is set by the test.
        for attribute in ('image', 'alternateImage'):
            node.attrib.pop(attribute, None)
        for connection in list(node.findall('connections')):
            node.remove(connection)
    objects.append(matrix)
    xib = work / f'{nib_name}.xib'
    ET.ElementTree(document).write(xib, encoding='utf-8', xml_declaration=True)
    nib = work / f'{nib_name}.nib'
    compiled = subprocess.run(['xcrun', 'ibtool', '--errors', '--compile', str(nib), str(xib)],
                              capture_output=True, text=True)
    if compiled.returncode:
        sys.exit(f'FAIL: {nib_name}.xib: the palette did not compile\n{compiled.stdout}{compiled.stderr}')
    return nib / 'keyedobjects.nib' if nib.is_dir() else nib


with tempfile.TemporaryDirectory(prefix='horos-orthogonal-tool-palette-') as folder:
    work = Path(folder)
    sources = [root / 'Horos/Sources/TipMatrix.swift']
    for name, _, _ in VIEWERS:
        path = work / f'{name}Probe.swift'
        path.write_text(harness(name), encoding='utf-8')
        sources.append(path)
    (work / 'Test.swift').write_text(MAIN, encoding='utf-8')
    sources.append(work / 'Test.swift')
    binary = work / 'test'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-suppress-warnings',
                            *map(str, sources), '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        sys.exit(f'FAIL: the actions did not compile\n{built.stdout}{built.stderr}')
    nibs = [palette_nib(nib_name, identifier, work) for _, nib_name, identifier in VIEWERS]
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        sys.exit(1)

print('PASS: changeTool(_:) of both orthogonal viewers takes the tool from the clicked cell of any matrix')
