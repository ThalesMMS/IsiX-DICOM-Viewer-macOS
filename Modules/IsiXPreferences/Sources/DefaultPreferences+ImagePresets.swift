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

import Foundation

// The presets of the image menus: window levels, convolution kernels, opacity
// tables, colour tables, and the shadings of the 3D viewers.
extension DefaultPreferences {
    static func addImagePresets(to values: NSMutableDictionary, viewer: Bool) {
        values["WLWW3"] = windowLevelPresets()
        values["Convolution"] = convolutionPresets()
        values["OPACITY"] = opacityTables()
        if viewer {
            values["CLUT"] = colourTables()
        }
    }

    // ** WLWW PRESETS: [level, width].
    private static func windowLevelPresets() -> NSMutableDictionary {
        let presets = NSMutableDictionary()
        for (name, level, width): (String, Float, Float) in [("CT - Pulmonary", -500, 1400), ("CT - Bone", 300, 1500),
                                                               ("CT - Brain", 50, 100), ("CT - Abdomen", 40, 350),
                                                               ("VR - Endoscopy", -300, 700)] {
            presets[name] = [NSNumber(value: level), NSNumber(value: width)] as NSArray
        }
        return presets
    }

    // ** CONVOLUTION PRESETS
    private static func convolutionPresets() -> NSMutableDictionary {
        let filters = NSMutableDictionary()
        // The first two carry their normalisation; the others the sum of their kernel.
        addConvolutionFilter(3, [-1, -1, -1, -1, 9, -1, -1, -1, -1], "Bone Filter 3x3", normalization: 1, to: filters)
        addConvolutionFilter(5, [1, 1, 1, 1, 1,
                                 1, 4, 4, 4, 1,
                                 1, 4, 12, 4, 1,
                                 1, 4, 4, 4, 1,
                                 1, 1, 1, 1, 1], "Basic Smooth 5x5", normalization: 60, to: filters)
        addConvolutionFilter(3, [1, 2, 1, 2, 4, 2, 1, 2, 1], "Blur 3x3", to: filters)
        addConvolutionFilter(5, [1, 1, 2, 1, 1, 1, 2, 3, 2, 1, 2, 3, 4, 3, 2, 1, 2, 3, 2, 1, 1, 1, 2, 1, 1], "Blur 5x5", to: filters)
        addConvolutionFilter(5, [3, 3, 2, 3, 3, 3, 2, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 2, 3, 3, 3, 2, 3, 3], "Inverted blur", to: filters)
        addConvolutionFilter(5, [0, 0, -1, 0, 0, 0, -1, -2, -1, 0, -1, -2, -3, -2, -1, 0, -1, -2, -1, 0, 0, 0, -1, 0, 0],
                             "Negative blur", to: filters)
        addConvolutionFilter(3, [1, 2, 1, 0, 0, 0, -1, -2, -1], "Emboss north", to: filters)
        addConvolutionFilter(3, [1, 0, -1, 2, 0, -2, 1, 0, -1], "Emboss west", to: filters)
        addConvolutionFilter(3, [0, 1, 0, -1, 0, 1, 0, -1, 0], "Emboss diagonal", to: filters)
        addConvolutionFilter(3, [-1, -1, -1, -1, 8, -1, -1, -1, -1], "Laplacian 8", to: filters)
        addConvolutionFilter(3, [0, -1, 0, -1, 4, -1, 0, -1, 0], "Laplacian 4", to: filters)
        addConvolutionFilter(3, [-1, 0, -1, 0, 7, 0, -1, 0, -1], "Sharpen 3x3", to: filters)
        addConvolutionFilter(3, [-1, 0, 0, 0, 0, 0, 0, 0, 1], "Emboss", to: filters)
        addConvolutionFilter(3, [-1, -1, 0, -1, 0, 1, 0, 1, 1], "Emboss heavy", to: filters)
        addConvolutionFilter(3, [1, 1, 1, 1, 1, 1, 1, 1, 1], "Lowpass", to: filters)
        addConvolutionFilter(3, [1, -2, 1, -2, 4, -2, 1, -2, 1], "Edge 3x3", to: filters)
        addConvolutionFilter(5, [0, -1, -1, -1, 0, -1, 2, -4, 2, -1, -1, -4, 13, -4, -1, -1, 2, -4, 2, -1, 0, -1, -1, -1, 0],
                             "Highpass 5x5", to: filters)
        addConvolutionFilter(5, [1, 1, 2, 1, 1, 1, 2, 4, 2, 1, 2, 4, 8, 4, 2, 1, 2, 4, 2, 1, 1, 1, 2, 1, 1], "Gaussian blur", to: filters)
        addConvolutionFilter(5, [0, 0, -1, 0, 0, 0, -1, -2, -1, 0, -1, -2, 16, -2, -1, 0, -1, -2, -1, 0, 0, 0, -1, 0, 0], "Hat", to: filters)
        addConvolutionFilter(5, [-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 24, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1],
                             "Laplacian", to: filters)
        addConvolutionFilter(5, [-1, -1, -1, -1, -1, -1, 2, 2, 2, -1, -1, 2, 8, 2, -1, -1, 2, 2, 2, -1, -1, -1, -1, -1, -1],
                             "Sharpen 5x5", to: filters)
        addConvolutionFilter(3, [1, 1, 1, 1, -7, 1, 1, 1, 1], "Excessive edges", to: filters)
        return filters
    }

    private static func addConvolutionFilter(_ size: Int, _ kernel: [Int], _ name: String, normalization: Int? = nil,
                                             to filters: NSMutableDictionary) {
        let filter = NSMutableDictionary()
        filter["Size"] = NSNumber(value: size)
        filter["Normalization"] = NSNumber(value: normalization ?? kernel.reduce(0, +))
        filter["Matrix"] = NSMutableArray(array: kernel.map { NSNumber(value: $0) })
        filters[name] = filter
    }

    // ** OPACITY TABLES: points of 1000 + the grey level, as NSStringFromPoint writes them.
    private static func opacityTables() -> NSMutableDictionary {
        func table(_ points: [NSPoint]) -> NSMutableDictionary {
            let table = NSMutableDictionary()
            table["Points"] = NSMutableArray(array: points.map { NSStringFromPoint($0) })
            return table
        }
        let tables = NSMutableDictionary()
        // 1 + level / 255 * 9 in one fused multiply-add, as clang contracted it.
        tables["Logarithmic Table"] = table((0..<256).map { i in
            NSPoint(x: CGFloat(1000 + i), y: log10((1.0).addingProduct(Double(i) / 255, 9)))
        })
        tables["Logarithmic Inverse Table"] = table((0..<256).map { i in
            NSPoint(x: CGFloat(1000 + i), y: 1 - log10((1.0).addingProduct(Double(255 - i) / 255, 9)))
        })
        tables["Smooth Table"] = table([NSPoint(x: 1000 + 180, y: 0.05)])
        return tables
    }

    // ** CLUT PRESETS: 256 levels of each channel, and the points and colours
    // the editor shows; then the tables the application ships as plists.
    private static func colourTables() -> NSMutableDictionary {
        let tables = NSMutableDictionary()
        tables["PET"] = colourTable(red: (0..<256).map { $0 < 128 ? $0 * 2 : 255 },
                                    green: (0..<256).map { $0 < 128 ? 0 : ($0 < 192 ? ($0 - 128) * 4 : 255) },
                                    blue: (0..<256).map { $0 < 192 ? 0 : ($0 - 192) * 4 },
                                    points: [0, 128, 192, 256], colours: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [1, 1, 1]])
        let inverse = (0..<256).map { 255 - $0 }
        tables["B/W Inverse"] = colourTable(red: inverse, green: inverse, blue: inverse,
                                            points: [0, 256], colours: [[1, 1, 1], [0, 0, 0]])
        // The level times a fraction, truncated toward zero as a C long.
        tables["Endoscopy"] = colourTable(red: (0..<256).map { Int(240 + Double($0) * 0.02) },
                                          green: (0..<256).map { Int(187 - Double($0) * 0.26) },
                                          blue: (0..<256).map { Int(195 - Double($0) * 0.26) },
                                          points: [0, 255], colours: [[1, 1, 1], [0, 0, 0]])
        // These two tables were written as red, green and blue arrays and stored
        // with the red and blue channels exchanged; the stored order is kept.
        tables["French"] = colourTable(red: frenchBlue, green: frenchGreen, blue: frenchRed,
                                       points: [0, 255], colours: [[1, 1, 1], [0, 0, 0]])
        tables["Perfusion"] = colourTable(red: perfusionBlue, green: perfusionGreen, blue: perfusionRed,
                                          points: [0, 255], colours: [[1, 1, 1], [0, 0, 0]])
        for name in ["VR Muscles-Bones", "VR Bones", "VR Red Vessels", "BlackBody", "Flow", "GEcolor", "Spectrum", "NIH",
                     "HotIron", "GrayRainbow", "UCLA", "Stern", "Ratio", "Rainbow3", "Rainbow2", "Rainbow", "ired", "Hue1",
                     "Hue2", "HotMetal", "HotGreen", "Jet", "PPU Inferno", "PPU Magma", "PPU Plasma", "PPU Viridis"] {
            if let path = Bundle.main.path(forResource: name, ofType: "plist"), let table = NSDictionary(contentsOfFile: path) {
                tables[name] = table
            } else {
                NSLog("CLUT plist not found: %@", name)
            }
        }
        return tables
    }

    private static func colourTable(red: [Int], green: [Int], blue: [Int], points: [Int], colours: [[Float]]) -> NSMutableDictionary {
        func numbers(_ values: [Int]) -> NSMutableArray { NSMutableArray(array: values.map { NSNumber(value: $0) }) }
        let table = NSMutableDictionary()
        table["Red"] = numbers(red)
        table["Green"] = numbers(green)
        table["Blue"] = numbers(blue)
        table["Colors"] = NSMutableArray(array: colours.map { colour in colour.map { NSNumber(value: $0) } as NSArray })
        table["Points"] = numbers(points)
        return table
    }

    /// The shadings of the 3D viewers' menu.
    static func shadingPresets() -> NSMutableArray {
        let presets = NSMutableArray()
        for (name, ambient, diffuse, specular, power) in [("Default", "0.15", "0.9", "0.3", "15"),
                                                          ("Glossy Vascular", "0.15", "0.28", "1.42", "50"),
                                                          ("Glossy Bone", "0.15", "0.24", "1.17", "6.98"),
                                                          ("Endoscopy", "0.12", "0.64", "0.73", "50")] {
            let shading = NSMutableDictionary()
            shading["name"] = name
            shading["ambient"] = ambient
            shading["diffuse"] = diffuse
            shading["specular"] = specular
            shading["specularPower"] = power
            presets.add(shading)
        }
        return presets
    }

    private static let frenchRed = [0,0,2,4,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,32,34,36,36,38,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,38,36,36,34,32,32,30,28,28,26,24,24,22,20,20,18,16,16,14,12,12,10,10,10,8,8,8,6,6,6,4,4,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,148,168,176,184,192,200,208,214,220,224,226,248,250,252,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,252,250,250,248,246,246,242,240,238,236,234,232,230,228,226,224,220,218,216,214,214,214,214,214,214,214,214,214,214,214,214,214,214,214,214,214,214,216,216,216,218,216,216,214,214,214,214,212,212,212,210,210,210,208,208,208,206,206,206,206,206,206,206,206,206,206,206,206,206,206,206,206,206,206,206,204,204,204,204,204,204,204,204,204,206,208,210,210,214,216,218,222,226,230,232,236,238,240,240,240,240,240,240,240,240,240]
    private static let frenchGreen = [0,2,4,6,8,10,12,14,16,18,20,22,24,28,30,32,36,38,40,44,46,48,52,54,56,60,62,64,68,70,72,76,78,80,84,86,88,92,94,96,100,102,104,108,110,112,116,118,120,124,126,128,132,134,136,140,142,144,146,148,150,152,154,156,158,160,162,162,162,162,162,162,162,162,162,162,160,158,158,156,154,154,152,150,150,148,146,146,144,142,142,140,140,140,130,128,128,126,126,126,126,126,126,128,128,130,130,134,138,142,148,152,158,164,168,174,180,184,190,196,202,206,212,218,222,228,234,238,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,226,218,210,202,194,186,178,170,162,154,146,138,130,122,114,106,98,90,82,74,66,58,50,42,34,26,18,10,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,4,4,4,6,6,6,8,8,8,10,10,10,12,14,14,16,18,18,62,34,42,50,58,66,74,82,90,98,106,114,122,130,138,144,152,160,168,176,184,192,200,208,216,224,232,240,248,254]
    private static let frenchBlue = [0,6,10,16,20,24,30,34,38,44,48,54,58,62,68,72,76,82,86,92,96,100,106,110,114,120,124,130,134,138,144,148,152,152,152,150,148,146,144,142,140,138,136,134,132,130,128,128,126,126,124,122,122,120,118,118,116,114,114,112,110,110,108,106,106,106,104,102,98,96,94,90,88,86,84,82,80,78,76,74,72,70,68,66,64,62,58,56,54,48,40,38,38,36,36,36,36,36,26,24,18,16,12,10,8,6,6,4,4,2,2,2,4,4,4,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,14,48,60,60,60,60,60,60,60,60,60,60,60,60,56,52,44,36,28,20,12,8,4,4,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,4,4,6,6,6,8,8,24,32,122,124,126,128,130,132,134,136,138,140,142,144,146,148,150,152,154,156,158,158,160,160,162,162,164,164,164,164,164,164,164,164,164,164,164,164,164,246,248,248,250,250,252,252,244,248,252,254,254,254,254,254,254,254,254]
    private static let perfusionRed = [0,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,8,10,14,16,18,22,24,26,28,32,34,36,40,42,44,48,50,52,54,58,60,62,66,68,70,74,76,78,80,84,86,88,92,94,96,98,102,104,106,110,112,114,118,120,122,124,128,130,132,136,138,140,144,146,148,150,154,156,158,162,164,166,168,172,174,176,180,182,184,188,190,192,194,198,200,202,206,208,210,214,216,218,220,224,226,228,232,234,236,240,242,244,246,250,252,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254,254]
    private static let perfusionGreen = [0,6,8,10,12,14,14,16,18,20,22,22,24,26,28,30,30,32,34,36,38,38,40,42,44,46,46,48,50,52,54,54,56,58,60,62,62,64,66,68,70,70,72,74,76,78,78,76,78,76,76,74,74,72,72,70,68,68,66,66,64,64,62,60,60,58,58,56,56,54,52,52,50,50,48,48,46,46,44,42,42,40,40,38,38,36,34,34,32,32,30,30,28,26,26,24,24,22,22,20,18,18,16,16,14,14,12,12,10,8,8,6,6,4,4,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,0,4,6,10,12,14,18,20,22,26,28,30,34,36,38,42,44,46,50,52,54,58,60,62,66,68,70,74,76,78,82,84,86,90,92,94,98,100,102,106,108,110,114,116,118,122,124,126,130,132,134,138,140,142,146,148,150,154,156,158,162,164,166,170,172,174,178,180,182,186,188,190,194,196,198,202,204,206,210,212,214,218,220,222,226,228,230,234,236,238,242,244,246,250,252,254]
    private static let perfusionBlue = [0,6,12,16,22,26,32,36,42,46,52,56,62,68,72,78,82,88,92,98,102,108,112,118,122,128,134,138,144,148,154,158,164,168,174,178,184,188,194,200,204,210,214,220,224,230,234,240,244,250,252,250,246,244,240,238,234,232,230,226,224,220,218,214,212,210,206,204,200,198,194,192,190,186,184,180,178,174,172,170,166,164,160,158,154,152,150,146,144,140,138,134,132,130,126,124,120,118,114,112,110,106,104,100,98,94,92,90,86,84,80,78,74,72,70,66,64,60,58,54,52,50,46,44,40,38,34,32,30,26,24,20,18,14,12,10,6,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,14,28,42,56,68,82,96,110,124,136,150,164,178,190]
}
