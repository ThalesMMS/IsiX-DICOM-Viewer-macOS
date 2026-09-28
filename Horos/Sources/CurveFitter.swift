/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// Curve fitting class based on the Simplex method described in the article "Fitting Curves to Data" in the May 1984 issue of Byte magazine, pages 340-362.

import Cocoa

private let STRAIGHT_LINE: Int32 = 0, POLY2: Int32 = 1, POLY3: Int32 = 2, POLY4: Int32 = 3, EXPONENTIAL: Int32 = 4,
            POWER: Int32 = 5, LOG: Int32 = 6, RODBARD: Int32 = 7, GAMMA_VARIATE: Int32 = 8, T1_SAT_RELAX: Int32 = 9,
            T2_DEPHASE: Int32 = 10, DIFFUSION: Int32 = 11
private let IterFactor: Int32 = 500

private let alpha = -1.0                // reflection coefficient
private let beta = 0.5                  // contraction coefficient
private let gammaCoefficient = 2.0      // expansion coefficient
private let root2 = 1.414214            // square root of 2

/// The Objective-C name and selectors are those of the former class.
///
/// Where the Objective-C wrote a product added to a term in one expression,
/// clang fused them into one multiply-add; `addingProduct` does the same here,
/// so the fits come out bit for bit as the Debug build of the former class
/// computed them.
@objc(CurveFitter)
public final class CurveFitter: NSObject {
    private var fit: Int32 = 0                              // Number of curve type to fit
    private var xData: UnsafeMutablePointer<Double>?        // x,y data to fit
    private var yData: UnsafeMutablePointer<Double>?
    private var numPoints: Int32 = 0                        // number of data points
    private var numParams: Int32 = 0                        // number of parametres
    private var numVertices: Int32 = 0                      // numParams+1 (includes sumLocalResiduaalsSqrd)
    private var worst: Int32 = 0                            // worst current parametre estimates
    private var nextWorst: Int32 = 0                        // 2nd worst current parametre estimates
    private var best: Int32 = 0                             // best current parametre estimates
    // the simplex (the last element of the array at each vertice is the sum of the square of the residuals)
    private var simp: UnsafeMutablePointer<UnsafeMutablePointer<Double>>?
    private var next: UnsafeMutablePointer<Double>?         // new vertex to be tested
    private var numIter: Int32 = 0                          // number of iterations so far
    private var maxIter: Int32 = 0                          // maximum number of iterations per restart
    private var restarts: Int32 = 0                         // number of times to restart simplex after first soln.
    private var maxError = 0.0                              // maximum error tolerance

    /// -init of NSObject: no data.
    @objc public override init() {
        super.init()
    }

    @objc(initCurveFitterWithXData:andYData:length:)
    public init(curveFitterWithXData xD: UnsafeMutablePointer<Double>!, andYData yD: UnsafeMutablePointer<Double>!, length l: Int32) {
        numPoints = l

        let x = malloc(Int(numPoints) * MemoryLayout<Double>.size)!.assumingMemoryBound(to: Double.self)
        let y = malloc(Int(numPoints) * MemoryLayout<Double>.size)!.assumingMemoryBound(to: Double.self)

        var i: Int32 = 0
        while i < numPoints {
            x[Int(i)] = xD[Int(i)]
            y[Int(i)] = yD[Int(i)]
            i += 1
        }
        xData = x
        yData = y
        super.init()
    }

    deinit {
        if let xData = xData {
            free(xData)
        }

        if let yData = yData {
            free(yData)
        }

        self.freeSimplex()
    }

    /// Frees the simplex and the next vertex, which -initialize allocates for
    /// numVertices vertices.
    private func freeSimplex() {
        if let simp = simp {
            for i in 0..<Int(max(numVertices, 0)) {
                free(simp[i])
            }
            free(simp)
            self.simp = nil
        }

        if let next = next {
            free(next)
            self.next = nil
        }
    }

    @objc(doFit:)
    public func doFit(_ fitType: Int32) {
        if fitType < STRAIGHT_LINE || fitType > DIFFUSION {
            NSException(name: NSExceptionName("CurveFitterException"), reason: "Invalid fit type", userInfo: nil).raise()
        }

        fit = fitType

        self.initialize()

        self.restart(0)

        numIter = 0
        var done = false

        let center = malloc(MemoryLayout<Double>.size * Int(numParams))!.assumingMemoryBound(to: Double.self)  // mean of simplex vertices
        let simp = self.simp!
        let next = self.next!
        let numParams = Int(self.numParams)
        let numVertices = Int(self.numVertices)

        while !done {
            numIter += 1
            for i in 0..<numParams { center[i] = 0.0 }
            // get mean "center" of vertices, excluding worst
            for i in 0..<numVertices where i != Int(worst) {
                for j in 0..<numParams {
                    center[j] += simp[i][j]
                }
            }
            // Reflect worst vertex through centre
            for i in 0..<numParams {
                center[i] /= Double(numParams)
                next[i] = center[i].addingProduct(alpha, simp[Int(worst)][i] - center[i])
            }
            self.sumResiduals(next)
            // if it's better than the best...
            if next[numParams] <= simp[Int(best)][numParams] {
                self.newVertex()
                // try expanding it
                for i in 0..<numParams {
                    next[i] = center[i].addingProduct(gammaCoefficient, simp[Int(worst)][i] - center[i])
                }
                self.sumResiduals(next)
                // if this is even better, keep it
                if next[numParams] <= simp[Int(worst)][numParams] {
                    self.newVertex()
                }
            }
            // else if better than the 2nd worst keep it...
            else if next[numParams] <= simp[Int(nextWorst)][numParams] {
                self.newVertex()
            }
            // else try to make positive contraction of the worst
            else {
                for i in 0..<numParams {
                    next[i] = center[i].addingProduct(beta, simp[Int(worst)][i] - center[i])
                }
                self.sumResiduals(next)
                // if this is better than the second worst, keep it.
                if next[numParams] <= simp[Int(nextWorst)][numParams] {
                    self.newVertex()
                }
                // if all else fails, contract simplex in on best
                else {
                    for i in 0..<numVertices where i != Int(best) {
                        for j in 0..<numVertices {
                            simp[i][j] = beta * (simp[i][j] + simp[Int(best)][j])
                        }
                        self.sumResiduals(simp[i])
                    }
                }
            }

            self.order()

            let rtol = 2 * fabs(simp[Int(best)][numParams] - simp[Int(worst)][numParams])
                / (fabs(simp[Int(best)][numParams]) + fabs(simp[Int(worst)][numParams]) + 0.0000000001)

            if numIter >= maxIter {
                done = true
            } else if rtol < maxError {
                restarts -= 1
                if restarts < 0 {
                    done = true
                } else {
                    self.restart(best)
                }
            }
        }

        free(center)
    }

    /// Initialise the simplex
    ///
    /// -doFit: calls this for every fit. The simplex of the previous fit is
    /// freed first, with the vertex count it was allocated for; it leaked.
    @objc public func initialize() {
        self.freeSimplex()
        // Calculate some things that might be useful for predicting parametres
        numParams = self.getNumParams()
        numVertices = numParams + 1      // need 1 more vertice than parametres,
        let simp = malloc(Int(numVertices) * MemoryLayout<UnsafeMutablePointer<Double>>.size)!
            .assumingMemoryBound(to: UnsafeMutablePointer<Double>.self)
        for i in 0..<Int(numVertices) {
            simp[i] = malloc(Int(numVertices) * MemoryLayout<Double>.size)!.assumingMemoryBound(to: Double.self)
        }
        self.simp = simp
        next = malloc(Int(numVertices) * MemoryLayout<Double>.size)!.assumingMemoryBound(to: Double.self)

        let xData = self.xData!, yData = self.yData!
        let firstx = xData[0]
        let firsty = yData[0]
        let lastx = xData[Int(numPoints) - 1]
        let lasty = yData[Int(numPoints) - 1]
        let xmean = (firstx + lastx) / 2.0
        let slope: Double
        if (lastx - firstx) != 0.0 {
            slope = (lasty - firsty) / (lastx - firstx)
        } else {
            slope = 1.0
        }
        let yintercept = firsty.addingProduct(-slope, firstx)
        maxIter = IterFactor * numParams * numParams  // Where does this estimate come from?
        restarts = 1
        maxError = 1e-9
        switch fit {
        case STRAIGHT_LINE:
            simp[0][0] = yintercept
            simp[0][1] = slope
        case POLY2:
            simp[0][0] = yintercept
            simp[0][1] = slope
            simp[0][2] = 0.0
        case POLY3:
            simp[0][0] = yintercept
            simp[0][1] = slope
            simp[0][2] = 0.0
            simp[0][3] = 0.0
        case POLY4:
            simp[0][0] = yintercept
            simp[0][1] = slope
            simp[0][2] = 0.0
            simp[0][3] = 0.0
            simp[0][4] = 0.0
        case EXPONENTIAL:
            simp[0][0] = 0.1
            simp[0][1] = 0.01
        case POWER:
            simp[0][0] = 0.0
            simp[0][1] = 1.0
        case LOG:
            simp[0][0] = 0.5
            simp[0][1] = 0.05
        case RODBARD:
            simp[0][0] = firsty
            simp[0][1] = 1.0
            simp[0][2] = xmean
            simp[0][3] = lasty
        case T1_SAT_RELAX:
            simp[0][0] = firsty
            simp[0][1] = 1.0
        case T2_DEPHASE:
            simp[0][0] = firsty
            simp[0][1] = 1.0
        case DIFFUSION:
            simp[0][0] = firsty
            simp[0][1] = 0.0005
        case GAMMA_VARIATE:
            //  First guesses based on following observations:
            //  t0 [b] = time of first rise in gamma curve - so use the user specified first limit
            //  tm = t0 + a*B [c*d] where tm is the time of the peak of the curve
            //  therefore an estimate for a and B is sqrt(tm-t0)
            //  K [a] can now be calculated from these estimates
            simp[0][0] = firstx
            let ab = xData[Int(self.getMax(yData))] - firstx
            simp[0][2] = sqrt(ab)
            simp[0][3] = sqrt(ab)
            simp[0][1] = yData[Int(self.getMax(yData))] / (pow(ab, simp[0][2]) * exp(-ab / simp[0][3]))
        default:
            break
        }
    }

    // Restart the simplex at the nth vertex.
    @objc(restart:)
    public func restart(_ n: Int32) {
        let simp = self.simp!
        let numParams = Int(self.numParams)
        let numVertices = Int(self.numVertices)
        // Copy nth vertice of simplex to first vertice
        for i in 0..<numParams {
            simp[0][i] = simp[Int(n)][i]
        }
        self.sumResiduals(simp[0])          // Get sum of residuals^2 for first vertex
        let step = malloc(MemoryLayout<Double>.size * numParams)!.assumingMemoryBound(to: Double.self)
        for i in 0..<numParams {
            step[i] = simp[0][i] / 2.0      // Step half the parametre value
            if step[i] == 0.0 {             // We can't have them all the same or we're going nowhere
                step[i] = 0.01
            }
        }
        // Some kind of factor for generating new vertices
        let p = malloc(MemoryLayout<Double>.size * numParams)!.assumingMemoryBound(to: Double.self)
        let q = malloc(MemoryLayout<Double>.size * numParams)!.assumingMemoryBound(to: Double.self)
        for i in 0..<numParams {
            p[i] = step[i] * (sqrt(Double(numVertices)) + Double(numParams) - 1.0) / (Double(numParams) * root2)
            q[i] = step[i] * (sqrt(Double(numVertices)) - 1.0) / (Double(numParams) * root2)
        }
        // Create the other simplex vertices by modifing previous one.
        for i in 1..<max(numVertices, 1) {
            for j in 0..<numParams {
                simp[i][j] = simp[i - 1][j] + q[j]
            }
            simp[i][i - 1] = simp[i][i - 1] + p[i - 1]
            self.sumResiduals(simp[i])
        }
        // Initialise current lowest/highest parametre estimates to simplex 1
        best = 0
        worst = 0
        nextWorst = 0
        self.order()

        free(p)
        free(q)
        free(step)
    }

    // Get number of parameters for the current fit function.
    @objc public func getNumParams() -> Int32 {
        switch fit {
        case STRAIGHT_LINE: return 2
        case POLY2: return 3
        case POLY3: return 4
        case POLY4: return 5
        case EXPONENTIAL: return 2
        case POWER: return 2
        case LOG: return 2
        case T1_SAT_RELAX: return 2
        case T2_DEPHASE: return 2
        case DIFFUSION: return 2
        case RODBARD: return 4
        case GAMMA_VARIATE: return 4
        default: return 0
        }
    }

    /// Returns "fit" function value for parametres "p" at "x"
    @objc(f:::)
    public func f(_ f: Int32, _ p: UnsafeMutablePointer<Double>!, _ x: Double) -> Double {
        var x = x
        switch f {
        case STRAIGHT_LINE:
            return p[0].addingProduct(p[1], x)
        case POLY2:
            return p[0].addingProduct(p[1], x).addingProduct(p[2] * x, x)
        case POLY3:
            return p[0].addingProduct(p[1], x).addingProduct(p[2] * x, x).addingProduct(p[3] * x * x, x)
        case POLY4:
            return p[0].addingProduct(p[1], x).addingProduct(p[2] * x, x).addingProduct(p[3] * x * x, x)
                .addingProduct(p[4] * x * x * x, x)
        case EXPONENTIAL:
            return p[0] * exp(p[1] * x)
        case T1_SAT_RELAX:
            return p[0] * (1 - exp(-(x / p[1])))
        case T2_DEPHASE:
            return p[0] * exp(-(x / p[1]))
        case DIFFUSION:
            return p[0] * exp(-x * p[1])
        case POWER:
            if x == 0.0 {
                return 0.0
            } else {
                return p[0] * exp(p[1] * log(x)) //y=ax^b
            }
        case LOG:
            if x == 0.0 {
                x = 0.5
            }
            return p[0] * log(p[1] * x)
        case RODBARD:
            let ex: Double
            if x == 0.0 {
                ex = 0.0
            } else {
                ex = exp(log(x / p[2]) * p[1])
            }
            var y = p[0] - p[3]
            y = y / (1.0 + ex)
            return y + p[3]
        case GAMMA_VARIATE:
            if p[0] >= x { return 0.0 }
            if p[1] <= 0 { return -100000.0 }
            if p[2] <= 0 { return -100000.0 }
            if p[3] <= 0 { return -100000.0 }

            let pw = pow((x - p[0]), p[2])
            let e = exp((-(x - p[0])) / p[3])
            return p[1] * pw * e
        default:
            return 0.0
        }
    }

    /// Get the set of parameter values from the best corner of the simplex
    @objc public func getParams() -> UnsafeMutablePointer<Double>! {
        self.order()
        return simp![Int(best)]
    }

    /// Returns residuals array ie. differences between data and curve
    @objc public func getResiduals() -> UnsafeMutablePointer<Double>! {
        let params = self.getParams()
        let residuals = malloc(MemoryLayout<Double>.size * Int(numPoints))!.assumingMemoryBound(to: Double.self)

        for i in 0..<Int(max(numPoints, 0)) {
            residuals[i] = yData![i] - self.f(fit, params, xData![i])
        }

        return residuals
    }

    /* Last "parametre" at each vertex of simplex is sum of residuals
     * for the curve described by that vertex
     */
    @objc public func getSumResidualsSqr() -> Double {
        let sumResidualsSqr = self.getParams()[Int(self.getNumParams())]
        return sumResidualsSqr
    }

    /// SD = sqrt(sum of residuals squared / number of params+1)
    @objc public func getSD() -> Double {
        let sd = sqrt(self.getSumResidualsSqr() / Double(numVertices))
        return sd
    }

    /// Get a measure of "goodness of fit" where 1.0 is best.
    @objc public func getFitGoodness() -> Double {
        var sumY = 0.0
        for i in 0..<Int(max(numPoints, 0)) { sumY += yData![i] }
        let mean = sumY / Double(numVertices)
        var sumMeanDiffSqr = 0.0
        let degreesOfFreedom = numPoints - self.getNumParams()
        var fitGoodness = 0.0
        for i in 0..<Int(max(numPoints, 0)) {
            sumMeanDiffSqr += self.sqr(yData![i] - mean)
        }
        if sumMeanDiffSqr > 0.0 && degreesOfFreedom != 0 {
            fitGoodness = 1.0.addingProduct(-(self.getSumResidualsSqr() / Double(degreesOfFreedom)),
                                            Double(numParams) / sumMeanDiffSqr)
        }

        return fitGoodness
    }

    @objc(sqr:)
    public func sqr(_ d: Double) -> Double { return d * d }

    /// Adds sum of square of residuals to end of array of parameters
    @objc(sumResiduals:)
    public func sumResiduals(_ x: UnsafeMutablePointer<Double>!) {
        let numParams = Int(self.numParams)
        x[numParams] = 0.0
        for i in 0..<Int(max(numPoints, 0)) {
            x[numParams] = x[numParams] + self.sqr(self.f(fit, x, xData![i]) - yData![i])
        }
    }

    /// Keep the "next" vertex
    @objc public func newVertex() {
        for i in 0..<Int(max(numVertices, 0)) {
            simp![Int(worst)][i] = next![i]
        }
    }

    /// Find the worst, nextWorst and best current set of parameter estimates
    @objc public func order() {
        let simp = self.simp!
        let numParams = Int(self.numParams)
        for i in 0..<Int32(max(numVertices, 0)) {
            if simp[Int(i)][numParams] < simp[Int(best)][numParams] { best = i }
            if simp[Int(i)][numParams] > simp[Int(worst)][numParams] { worst = i }
        }
        nextWorst = best
        for i in 0..<Int32(max(numVertices, 0)) where i != worst {
            if simp[Int(i)][numParams] > simp[Int(nextWorst)][numParams] { nextWorst = i }
        }
    }

    /// Get number of iterations performed
    @objc public func getIterations() -> Int32 {
        return numIter
    }

    /// Get maximum number of iterations allowed
    @objc public func getMaxIterations() -> Int32 {
        return maxIter
    }

    /// Set maximum number of iterations allowed
    @objc(setMaxIterations:)
    public func setMaxIterations(_ x: Int32) {
        maxIter = x
    }

    /// Get number of simplex restarts to do
    @objc public func getRestarts() -> Int32 {
        return restarts
    }

    /// Set number of simplex restarts to do
    @objc(setRestarts:)
    public func setRestarts(_ x: Int32) {
        restarts = x
    }

    /// Gets index of highest value in an array.
    ///
    /// - Parameter array: Double array.
    /// - Returns: Index of highest value.
    @objc(getMax:)
    public func getMax(_ array: UnsafeMutablePointer<Double>!) -> Int32 {
        var max = array[0]
        var index: Int32 = 0
        var i: Int32 = 1
        while i < numPoints {
            if max < array[Int(i)] {
                max = array[Int(i)]
                index = i
            }
            i += 1
        }
        return index
    }
}
