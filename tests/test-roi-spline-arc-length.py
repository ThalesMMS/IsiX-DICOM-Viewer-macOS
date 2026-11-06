#!/usr/bin/env python3
"""Compare sampled production splines with numerical integration of their cubics.

The spline is IsiXROI's (ROISpline.swift): ROISpline.pieces answers the cubics
ROISpline.smooth samples. The length of the sampled outline, with square and
with anisotropic pixels, open and closed, is within 0.01 mm of the integral of
the cubics (Simpson's rule, refined until it no longer moves).
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

DRIVER = r'''
import CoreGraphics
import Foundation
import IsiXROI

func speed(_ t: Double, _ x: (a: Double, b: Double, c: Double, d: Double), _ y: (a: Double, b: Double, c: Double, d: Double),
           _ sx: Double, _ sy: Double) -> Double {
    hypot(sx * (x.b + 2 * x.c * t + 3 * x.d * t * t), sy * (y.b + 2 * y.c * t + 3 * y.d * t * t))
}

func arc(_ piece: ROISpline.Piece, _ sx: Double, _ sy: Double, _ n: Int) -> Double {
    let step = piece.length / Double(n)
    var sum = 0.0
    for i in 0...n {
        sum += (i == 0 || i == n ? 1 : i % 2 == 1 ? 4 : 2) * speed(Double(i) * step, piece.x, piece.y, sx, sy)
    }
    return sum * step / 3
}

let points = [CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 22), CGPoint(x: 20, y: 7), CGPoint(x: 26, y: 22), CGPoint(x: 5, y: 5)]
for closed in [false, true] {
    for anisotropic in [false, true] {
        let outline = Array(points.prefix(closed ? 5 : 4))
        let sx = anisotropic ? 0.5 : 1, sy = anisotropic ? 2.0 : 1
        guard let pieces = ROISpline.pieces(outline, scale: 5) else { fatalError("no cubics") }
        let reference = pieces.reduce(0) { $0 + arc($1, sx, sy, 8192) }
        let fine = pieces.reduce(0) { $0 + arc($1, sx, sy, 16384) }
        let sampled = ROISpline.smooth(outline, scale: 5).points
        precondition(sampled.count > 4)
        var measured = 0.0
        for i in 1..<sampled.count {
            measured += hypot(sx * Double(sampled[i].x - sampled[i - 1].x), sy * Double(sampled[i].y - sampled[i - 1].y))
        }
        print(String(format: "closed=%d anisotropic=%d sampled=%.9f mm integral=%.9f mm error=%.9f mm",
                     closed ? 1 : 0, anisotropic ? 1 : 0, measured, fine, abs(measured - fine)))
        precondition(abs(reference - fine) < 1e-8)
        precondition(abs(measured - fine) < 0.01)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-spline-arc-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(DRIVER)
    module = isix_modules.module_flags('IsiXROI', p / 'module')
    subprocess.run(['xcrun', 'swiftc', str(p / 'main.swift'), *module, '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
