//
//  CustomCompositor.swift
//  GravadorAulas
//
//  AVVideoCompositing customizado. Aplica, em cada frame:
//    - Privacidade: blur/pixelização/tarja em regiões (PrivacyRegion)
//    - Cursor highlight: halo + realce de cliques
//    - Anotações: setas, círculos, retângulos, texto, imagem
//
//  Recebe o frame bruto via renderContext.newPixelBuffer e devolve um
//  buffer modificado. Usa Core Image para filtros e Core Graphics para
//  overlays rasterizados.
//

import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import AppKit
import CoreText

/// Instruções completas para o compositor. Criado uma vez no início do
/// export e congelado — não muda durante a renderização.
struct CompositorInstructions {
    let renderSize: CGSize
    let frameDuration: CMTime
    let totalDuration: CMTime
    let privacyRegions: [PrivacyRegion]   // normalizado
    let keyEvents: [KeyCastService.KeyEvent]
    let cursorSamples: [CursorSample]
    let annotations: [Annotation]
    let trackKindForInstruction: TrackKind
}

struct CursorSample {
    let timestamp: Double       // segundos na timeline
    let position: CGPoint       // normalizado 0...1
    let clicked: Bool
}

final class GravadorAulasCompositor: NSObject, AVVideoCompositing {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let renderQueue = DispatchQueue(label: "gravadoraulas.compositor.render")
    /// Estado compartilhado entre instâncias porque o AVAssetExportSession
    /// cria sua própria instância da classe via `customVideoCompositorClass`.
    /// Para um único export ativo, isso é seguro.
    static var sharedInstructions: CompositorInstructions?
    private var cachedRequiredAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        cachedRequiredAttributes
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            self?.handle(asyncVideoCompositionRequest)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: - Renderização de fato

    private func handle(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = request.sourceTrackIDs.first as? Int32 else {
            request.finish(with: NSError(domain: "GravadorAulas.Compositor", code: 1))
            return
        }
        guard let instructions = Self.sharedInstructions else {
            request.finish(with: NSError(domain: "GravadorAulas.Compositor", code: 2))
            return
        }

        let presentationTime = request.compositionTime
        let tSeconds = CMTimeGetSeconds(presentationTime)

        // Pega buffer do source para o track ID
        guard let sourceBuffer = request.sourceFrame(byTrackID: trackID) else {
            request.finish(with: NSError(domain: "GravadorAulas.Compositor", code: 3))
            return
        }

        // Aloca buffer de saída
        let outputBuffer = request.renderContext.newPixelBuffer()
        guard let outputBuffer else {
            request.finish(with: NSError(domain: "GravadorAulas.Compositor", code: 4))
            return
        }

        // Processa: começa com imagem base e aplica overlays
        processFrame(
            source: sourceBuffer,
            destination: outputBuffer,
            instructions: instructions,
            time: tSeconds
        )

        request.finish(withComposedVideoFrame: outputBuffer)
    }

    private func processFrame(source: CVPixelBuffer,
                              destination: CVPixelBuffer,
                              instructions: CompositorInstructions,
                              time: Double) {
        var ciImage = CIImage(cvPixelBuffer: source)

        // 1) Aplica regiões de privacidade
        for region in instructions.privacyRegions {
            guard time >= region.start && time <= region.end else { continue }
            ciImage = applyPrivacy(region: region, to: ciImage, renderSize: instructions.renderSize)
        }

        // 2) Renderiza overlays via Core Graphics em uma imagem temporária
        let overlayImage = renderOverlays(instructions: instructions, time: time, baseSize: ciImage.extent.size)
        if let overlay = overlayImage {
            ciImage = overlay.composited(over: ciImage)
        }

        // 3) Escala para renderSize
        if ciImage.extent.size != instructions.renderSize {
            let scaleX = instructions.renderSize.width  / ciImage.extent.width
            let scaleY = instructions.renderSize.height / ciImage.extent.height
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        // 4) Renderiza para o buffer de saída
        ciContext.render(ciImage, to: destination)
    }

    private func applyPrivacy(region: PrivacyRegion, to image: CIImage, renderSize: CGSize) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        let rect = CGRect(
            x: region.rect.minX * w,
            y: (1.0 - region.rect.maxY) * h,    // y invertido: origem em baixo-esquerda no CIImage
            width: region.rect.width * w,
            height: region.rect.height * h
        )

        switch region.mode {
        case .blur:
            let f = CIFilter.boxBlur()
            f.radius = Float(20 * region.intensity)
            f.inputImage = image.cropped(to: rect)
            if let out = f.outputImage {
                // Composite do blur de volta na posição original
                return out.composited(over: blankOutside(rect: rect, in: image))
            }
            return image

        case .pixelate:
            let f = CIFilter.pixellate()
            f.center = CGPoint(x: rect.midX, y: rect.midY)
            f.scale = Float(20 * region.intensity)
            f.inputImage = image
            if let out = f.outputImage {
                return out
            }
            return image

        case .solidBar:
            // Tarja preta opaca
            let barImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: rect)
            return barImage.composited(over: image)
        }
    }

    private func blankOutside(rect: CGRect, in image: CIImage) -> CIImage {
        // Crop a imagem dentro do rect (para o blur overlay)
        return image.cropped(to: rect)
    }

    private func renderOverlays(instructions: CompositorInstructions,
                                 time: Double,
                                 baseSize: CGSize) -> CIImage? {
        // Coletamos tudo num NSImage e convertemos para CIImage uma vez
        let w = Int(baseSize.width)
        let h = Int(baseSize.height)
        guard w > 0, h > 0 else { return nil }

        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

        // 3a) Cursor halo + clique
        drawCursor(in: ctx, instructions: instructions, time: time, size: CGSize(width: w, height: h))

        // 3b) Teclas pressionadas
        drawKeyCast(in: ctx, instructions: instructions, time: time, size: CGSize(width: w, height: h))

        // 3c) Anotações
        drawAnnotations(in: ctx, instructions: instructions, time: time, size: CGSize(width: w, height: h))

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Cursor

    private func drawCursor(in ctx: CGContext,
                            instructions: CompositorInstructions,
                            time: Double,
                            size: CGSize) {
        // Cursor ativo no momento (mais recente antes do tempo atual)
        guard let sample = instructions.cursorSamples.last(where: { $0.timestamp <= time }) else {
            return
        }
        let x = sample.position.x * size.width
        let y = (1.0 - sample.position.y) * size.height  // flip

        // Halo
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: x - 22, y: y - 22, width: 44, height: 44))

        // Onda de clique
        if sample.clicked {
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: x - 36, y: y - 36, width: 72, height: 72))
        }

        // Cursor desenhado como seta simples
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + 14, y: y - 4))
        ctx.addLine(to: CGPoint(x: x + 6, y: y - 6))
        ctx.addLine(to: CGPoint(x: x + 4, y: y - 14))
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)
    }

    // MARK: - KeyCast

    private func drawKeyCast(in ctx: CGContext,
                             instructions: CompositorInstructions,
                             time: Double,
                             size: CGSize) {
        // Eventos ativos: começamos 1.2s antes do tempo atual e duram 1.5s
        let recentEvents = instructions.keyEvents.filter { event in
            time >= event.timestamp && time <= event.timestamp + 1.5
        }
        guard !recentEvents.isEmpty else { return }

        let text = recentEvents.map(\.display).joined(separator: "  ")
        let fontSize: CGFloat = 36
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()

        let padding: CGFloat = 16
        let bgRect = CGRect(
            x: size.width - textSize.width - padding * 2 - 24,
            y: padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fill(bgRect.insetBy(dx: -12, dy: -4))

        attr.draw(at: CGPoint(x: bgRect.minX + padding, y: bgRect.minY + padding / 2))
    }

    // MARK: - Annotations

    private func drawAnnotations(in ctx: CGContext,
                                 instructions: CompositorInstructions,
                                 time: Double,
                                 size: CGSize) {
        for ann in instructions.annotations where time >= ann.start && time <= ann.start + ann.duration {
            let rect = CGRect(
                x: ann.rect.minX * size.width,
                y: (1.0 - ann.rect.maxY) * size.height,
                width: ann.rect.width * size.width,
                height: ann.rect.height * size.height
            )
            let color = NSColor(hex: ann.color) ?? .systemRed

            switch ann.kind {
            case .rectangle:
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(rect)

            case .circle:
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: rect)

            case .arrow:
                ctx.setStrokeColor(color.cgColor)
                ctx.setFillColor(color.cgColor)
                ctx.setLineWidth(4)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                ctx.strokePath()
                // ponta da seta
                let tip = CGPoint(x: rect.maxX, y: rect.minY)
                let dx = rect.maxX - rect.minX
                let dy = rect.minY - rect.maxY
                let len = sqrt(dx*dx + dy*dy)
                let ux = dx / len, uy = dy / len
                let size: CGFloat = 16
                ctx.beginPath()
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: tip.x - size * ux + size * 0.5 * uy,
                                        y: tip.y - size * uy - size * 0.5 * ux))
                ctx.addLine(to: CGPoint(x: tip.x - size * ux - size * 0.5 * uy,
                                        y: tip.y - size * uy + size * 0.5 * ux))
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)

            case .text:
                if let text = ann.text {
                    let font = NSFont.systemFont(ofSize: max(20, rect.height * 0.4), weight: .bold)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: color,
                        .strokeColor: NSColor.black,
                        .strokeWidth: -2.0,
                    ]
                    NSAttributedString(string: text, attributes: attrs)
                        .draw(in: rect)
                }

            case .image, .keyPress:
                break   // implementações futuras
            }
        }
    }

    func configure(with instructions: CompositorInstructions) {
        Self.sharedInstructions = instructions
    }
}

// MARK: - NSColor hex helper

extension NSColor {
    convenience init?(hex: String?) {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((v & 0xFF0000) >> 16) / 255
        let g = CGFloat((v & 0x00FF00) >> 8) / 255
        let b = CGFloat( v & 0x0000FF       ) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}