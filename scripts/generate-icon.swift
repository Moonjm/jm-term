#!/usr/bin/env swift
// scripts/generate-icon.swift
// JMTerm 앱 아이콘 생성 스크립트

import AppKit
import CoreGraphics

let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("Cannot get graphics context")
}

// 배경: 둥근 사각형 (macOS 스타일, 가이드라인 여백 적용)
let padding: CGFloat = size * 0.1
let iconSize = size - padding * 2
let cornerRadius: CGFloat = iconSize * 0.22
let bgRect = CGRect(x: padding, y: padding, width: iconSize, height: iconSize)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// 그라데이션 배경 (어두운 남색 → 진한 검정)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradientColors = [
    CGColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0),
    CGColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1.0),
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0])!

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: size/2, y: bgRect.maxY), end: CGPoint(x: size/2, y: bgRect.minY), options: [])
ctx.restoreGState()

// 미세한 테두리
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(CGColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 0.4))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// 터미널 윈도우 프레임
let termMargin: CGFloat = iconSize * 0.08
let termRect = CGRect(x: bgRect.minX + termMargin, y: bgRect.minY + termMargin * 0.8, width: iconSize - termMargin * 2, height: iconSize - termMargin * 2)
let termRadius: CGFloat = iconSize * 0.06
let termPath = CGPath(roundedRect: termRect, cornerWidth: termRadius, cornerHeight: termRadius, transform: nil)

// 터미널 배경
ctx.saveGState()
ctx.addPath(termPath)
ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 0.9))
ctx.fillPath()
ctx.restoreGState()

// 터미널 테두리
ctx.saveGState()
ctx.addPath(termPath)
ctx.setStrokeColor(CGColor(red: 0.25, green: 0.35, blue: 0.55, alpha: 0.6))
ctx.setLineWidth(2.5)
ctx.strokePath()
ctx.restoreGState()

// 타이틀바 점 3개
let dotY = termRect.maxY - iconSize * 0.055
let dotRadius: CGFloat = iconSize * 0.018
let dotStartX = termRect.minX + iconSize * 0.05
let dotSpacing: CGFloat = iconSize * 0.042

let dotColors: [(CGFloat, CGFloat, CGFloat)] = [
    (0.95, 0.30, 0.25),  // red
    (0.95, 0.75, 0.20),  // yellow
    (0.25, 0.80, 0.35),  // green
]

for (i, color) in dotColors.enumerated() {
    let x = dotStartX + CGFloat(i) * dotSpacing
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: x - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    ctx.restoreGState()
}

// 타이틀바 구분선
let separatorY = dotY - iconSize * 0.04
ctx.saveGState()
ctx.move(to: CGPoint(x: termRect.minX, y: separatorY))
ctx.addLine(to: CGPoint(x: termRect.maxX, y: separatorY))
ctx.setStrokeColor(CGColor(red: 0.25, green: 0.35, blue: 0.55, alpha: 0.4))
ctx.setLineWidth(1.5)
ctx.strokePath()
ctx.restoreGState()

// 프롬프트 텍스트: ">_" (큰 글씨, 중앙)
let promptFont = NSFont.monospacedSystemFont(ofSize: iconSize * 0.28, weight: .bold)
let promptStr = ">_"
let promptAttrs: [NSAttributedString.Key: Any] = [
    .font: promptFont,
    .foregroundColor: NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0),
]
let promptSize = (promptStr as NSString).size(withAttributes: promptAttrs)

let contentAreaTop = separatorY
let contentAreaBottom = termRect.minY
let contentCenterY = (contentAreaTop + contentAreaBottom) / 2

let promptX = bgRect.minX + (iconSize - promptSize.width) / 2
let promptY = contentCenterY - promptSize.height / 2

(promptStr as NSString).draw(at: NSPoint(x: promptX, y: promptY), withAttributes: promptAttrs)

// 커서 블링크 효과 (사각 커서)
let cursorX = promptX + promptSize.width + iconSize * 0.02
let cursorHeight = iconSize * 0.26
let cursorWidth = iconSize * 0.04
let cursorY = promptY + (promptSize.height - cursorHeight) / 2 + iconSize * 0.01
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.7))
ctx.fill(CGRect(x: cursorX, y: cursorY, width: cursorWidth, height: cursorHeight))
ctx.restoreGState()

// 하단 작은 텍스트 라인 (장식용)
let smallFont = NSFont.monospacedSystemFont(ofSize: iconSize * 0.05, weight: .regular)
let lines = ["ssh user@server", "connected"]
let lineColors: [NSColor] = [
    NSColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.5),
    NSColor(red: 0.3, green: 0.7, blue: 0.5, alpha: 0.4),
]

for (i, line) in lines.enumerated() {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: smallFont,
        .foregroundColor: lineColors[i],
    ]
    let y = termRect.minY + iconSize * 0.05 + CGFloat(i) * iconSize * 0.065
    let x = termRect.minX + iconSize * 0.05
    (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

image.unlockFocus()

// PNG로 저장
guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot convert to PNG")
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let outputPath = "\(outputDir)/AppIcon.png"
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Icon saved to \(outputPath)")
