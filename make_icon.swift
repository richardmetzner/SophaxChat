#!/usr/bin/env swift
// Generates SophaxChat app icon: 1024×1024 PNG
// Run: swift make_icon.swift

import CoreGraphics
import CoreText
import Foundation
import ImageIO

let size = 1024
let ctx = CGContext(
    data: nil,
    width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let s = CGFloat(size)

// ---------------------------------------------------------------------------
// Background gradient: dark indigo → deep purple
// ---------------------------------------------------------------------------
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.07, green: 0.05, blue: 0.18, alpha: 1),
        CGColor(red: 0.25, green: 0.08, blue: 0.42, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(grad,
    start: CGPoint(x: 0, y: s),
    end:   CGPoint(x: s, y: 0),
    options: [])

// ---------------------------------------------------------------------------
// Three horizontal strokes — centered on canvas
// Matches the hand-drawn three-line mark (slightly organic angles)
// ---------------------------------------------------------------------------

ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.setLineCap(.round)

let lineW: CGFloat = 500          // stroke length
let lx0 = (s - lineW) / 2        // left start X
let lx1 = lx0 + lineW             // right end X
let lineThick: CGFloat = 62       // stroke width
let gap: CGFloat = 148            // vertical gap between line centers

// CG y-up: center of the group sits exactly at canvas center
// Total group height = 2 * gap = 296 → lines span ±148 around center
let groupCY = s / 2               // 512 — true canvas center

// Line 1 (top) — slight upward tilt to the right
ctx.setLineWidth(lineThick)
ctx.move(to: CGPoint(x: lx0,     y: groupCY + gap - 8))
ctx.addLine(to: CGPoint(x: lx1,  y: groupCY + gap + 14))
ctx.strokePath()

// Line 2 (middle) — gentle curve
ctx.setLineWidth(lineThick - 4)
ctx.move(to: CGPoint(x: lx0,    y: groupCY + 4))
ctx.addQuadCurve(
    to:      CGPoint(x: lx1,    y: groupCY - 6),
    control: CGPoint(x: s / 2,  y: groupCY - 30)   // bows slightly down in screen
)
ctx.strokePath()

// Line 3 (bottom) — slight tilt, slightly shorter
let lineW3: CGFloat = lineW - 28
let lx0b = (s - lineW3) / 2
let lx1b = lx0b + lineW3
ctx.setLineWidth(lineThick - 2)
ctx.move(to: CGPoint(x: lx0b,   y: groupCY - gap + 6))
ctx.addLine(to: CGPoint(x: lx1b, y: groupCY - gap - 8))
ctx.strokePath()

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: "SophaxChat/Assets.xcassets/AppIcon.appiconset/icon_1024.png",
              relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("✓ Icon saved to \(url.path)")
