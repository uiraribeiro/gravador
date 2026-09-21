#!/usr/bin/env swift
//
//  generate_icon.swift
//  GravadorAulas
//
//  Gera o AppIcon em 1024x1024 usando Core Graphics.
//  Saída: <output-dir>/icon_1024.png
//

import Foundation
import AppKit
import CoreGraphics

func drawIcon(size: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )
    guard let rep,
          let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let ctx = nsCtx.cgContext
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }

    let s = CGFloat(size)

    // 1) Fundo em gradiente azul com cantos arredondados
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerR = s * 0.22
    ctx.saveGState()
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerR, yRadius: cornerR)
    bgPath.addClip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(colorSpace: colorSpace, components: [0.06, 0.09, 0.22, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.22, 0.27, 0.58, 1.0])!,
    ]
    let locations: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: colors as CFArray,
                                  locations: locations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: s, y: s),
            options: []
        )
    }
    ctx.restoreGState()

    // 2) Tela (retângulo branco arredondado)
    let screenMargin = s * 0.16
    let screenRect = CGRect(
        x: screenMargin,
        y: screenMargin + s * 0.08,
        width: s - screenMargin * 2,
        height: s - screenMargin * 2 - s * 0.08
    )
    let screenCornerR = s * 0.04

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012),
                  blur: s * 0.02,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let screenPath = NSBezierPath(roundedRect: screenRect,
                                  xRadius: screenCornerR,
                                  yRadius: screenCornerR)
    NSColor.white.setFill()
    screenPath.fill()
    ctx.restoreGState()

    // 3) Linhas de "conteúdo" na tela
    ctx.saveGState()
    NSColor(white: 0.85, alpha: 1.0).setFill()
    let lineH = s * 0.025
    let lineGap = s * 0.018
    let lineInset = s * 0.07
    let lineOriginY = screenRect.midY - s * 0.04
    let lineFullWidth = screenRect.width - lineInset * 2
    for i in 0..<3 {
        let y = lineOriginY + CGFloat(i) * (lineH + lineGap)
        let widths: [CGFloat] = [0.78, 0.62, 0.85]
        let w = lineFullWidth * widths[i]
        let r = NSBezierPath(roundedRect: CGRect(
            x: screenRect.minX + lineInset,
            y: y,
            width: w,
            height: lineH),
            xRadius: lineH / 2,
            yRadius: lineH / 2)
        r.fill()
    }
    ctx.restoreGState()

    // 4) Triângulo "play" no canto inferior direito da tela
    let playSize = s * 0.10
    let playRect = CGRect(
        x: screenRect.maxX - playSize * 1.3,
        y: screenRect.minY + playSize * 0.3,
        width: playSize,
        height: playSize
    )
    ctx.saveGState()
    NSColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1.0).setFill()
    let play = NSBezierPath()
    play.move(to: CGPoint(x: playRect.minX, y: playRect.minY))
    play.line(to: CGPoint(x: playRect.maxX, y: playRect.midY))
    play.line(to: CGPoint(x: playRect.minX, y: playRect.maxY))
    play.close()
    play.fill()
    ctx.restoreGState()

    // 5) Círculo vermelho de "gravando" no canto superior direito
    let dotR = s * 0.06
    let dotCenter = CGPoint(x: s - s * 0.15, y: s * 0.15)
    ctx.saveGState()
    ctx.setShadow(offset: .zero,
                  blur: s * 0.02,
                  color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor(red: 0.95, green: 0.20, blue: 0.20, alpha: 1.0).setFill()
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR,
                              y: dotCenter.y - dotR,
                              width: dotR * 2,
                              height: dotR * 2))
    ctx.restoreGState()

    ctx.saveGState()
    NSColor.white.setStroke()
    ctx.setLineWidth(s * 0.012)
    ctx.strokeEllipse(in: CGRect(x: dotCenter.x - dotR,
                                y: dotCenter.y - dotR,
                                width: dotR * 2,
                                height: dotR * 2))
    ctx.restoreGState()

    return rep.representation(using: .png, properties: [:])
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Uso: generate_icon.swift <output-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let png = drawIcon(size: 1024) else {
    print("Falha ao gerar PNG")
    exit(1)
}

let outURL = outDir.appendingPathComponent("icon_1024.png")
do {
    try png.write(to: outURL)
    print("✓ \(outURL.path)")
} catch {
    print("Erro: \(error.localizedDescription)")
    exit(1)
}