//
//  PreviewViews.swift
//  GravadorAulas
//
//  Wrappers SwiftUI para NSView:
//    - ScreenPreviewView     : desenha frames CMSampleBuffer da tela
//    - CameraPreviewNSView   : AVCaptureVideoPreviewLayer
//    - MetalPreviewView      : fallback OpenGL/Metal (não usado no MVP)
//

import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit
import ScreenCaptureKit

// MARK: - Screen preview

/// NSView que desenha o último frame de buffer da tela.
final class ScreenBufferView: NSView {
    var latestPixelBuffer: CVPixelBuffer? {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let pb = latestPixelBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let ns = NSImage(cgImage: cg, size: bounds.size)
        ns.draw(in: bounds)
    }
}

struct ScreenPreviewView: NSViewRepresentable {
    @ObservedObject var session: RecordingSession

    func makeNSView(context: Context) -> ScreenBufferView {
        let v = ScreenBufferView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        // Amarra o stream para o NSView atualizar
        session.attachPreview(view: v)
        return v
    }

    func updateNSView(_ nsView: ScreenBufferView, context: Context) {
        session.attachPreview(view: nsView)
    }
}

// MARK: - Camera preview (AVCaptureVideoPreviewLayer)

final class CameraPreviewNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CALayer() }
}

struct CameraPreviewView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let v = CameraPreviewNSView(frame: .zero)
        previewLayer.frame = v.bounds
        v.layer = previewLayer
        return v
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        previewLayer.frame = nsView.bounds
        nsView.layer = previewLayer
    }
}