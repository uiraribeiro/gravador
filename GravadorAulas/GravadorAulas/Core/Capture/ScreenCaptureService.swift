//
//  ScreenCaptureService.swift
//  GravadorAulas
//
//  Wrapper sobre ScreenCaptureKit (SCStream). Encapsula configuração
//  (display/window/region), start, stop e entrega de CMSampleBuffers
//  de vídeo e áudio para um delegate.
//
//  Não gerencia AVAssetWriter; isso é responsabilidade do RecordingSession.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

protocol ScreenCaptureServiceDelegate: AnyObject {
    func screenCapture(_ service: ScreenCaptureService,
                       didOutput sampleBuffer: CMSampleBuffer,
                       type: SCStreamOutputType)
    func screenCapture(_ service: ScreenCaptureService, didStopWithError error: Error?)
}

final class ScreenCaptureService: NSObject {

    weak var delegate: ScreenCaptureServiceDelegate?

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private(set) var source: ScreenSource = .display(displayID: CGMainDisplayID())

    private let sampleQueue = DispatchQueue(label: "gravadoraulas.screencapture.samples",
                                             qos: .userInteractive)

    func configure(source: ScreenSource,
                   frameRate: Int,
                   resolution: CaptureResolution,
                   captureAudio: Bool,
                   audioSampleRate: Int = 48_000) throws {

        self.source = source

        let cfg = SCStreamConfiguration()
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
        cfg.queueDepth = 8
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        if let size = resolution.pixelSize {
            cfg.width  = Int(size.width)
            cfg.height = Int(size.height)
        }
        // Sem resolution.pixelSize (matchDisplay): deixa width/height em 0
        // e o ScreenCaptureKit usa a resolução nativa do display/filtro.

        cfg.capturesAudio = captureAudio
        cfg.sampleRate = audioSampleRate
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true

        // sourceRect: usado quando 'region'
        if case .region(let rect, let displayID, _) = source {
            cfg.sourceRect = rect
            // Com preset, ScreenCaptureKit escala o recorte diretamente para
            // o mesmo tamanho esperado pelo AVAssetWriter. Isso evita MP4
            // incompleto quando a dimensão livre da seleção não coincide com
            // a configuração do encoder.
            if resolution.pixelSize == nil {
                let scale = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                })?.backingScaleFactor ?? 1
                cfg.width = Self.evenPixelDimension(rect.width * scale)
                cfg.height = Self.evenPixelDimension(rect.height * scale)
            }
        }

        // O filter é construído depois, pois depende de displays/windows.
        // Apenas guardamos a config.
        self.configuration = cfg
    }

    private static func evenPixelDimension(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) / 2 * 2)
    }

    /// Resolve o SCContentFilter a partir do ScreenSource.
    /// Requer que `displays/windows` tenham sido descobertos antes.
    private func buildFilter(from content: SCShareableContent) throws -> SCContentFilter {
        switch source {
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) else {
                throw NSError(domain: "GravadorAulas", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Display \(id) não encontrado."])
            }
            return SCContentFilter(display: d, excludingWindows: [])

        case .window(let id, _):
            guard let w = content.windows.first(where: { $0.windowID == id }) else {
                throw NSError(domain: "GravadorAulas", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Janela \(id) não encontrada (pode ter sido fechada)."])
            }
            return SCContentFilter(desktopIndependentWindow: w)

        case .region(_, let id, _):
            guard let d = content.displays.first(where: { $0.displayID == id }) else {
                throw NSError(domain: "GravadorAulas", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Display da região não encontrado."])
            }
            return SCContentFilter(display: d, excludingWindows: [])
        }
    }

    /// Inicia a captura. `content` deve vir de SCShareableContentProxy.current().
    func start(content: SCShareableContent) async throws {
        guard let cfg = configuration else {
            throw NSError(domain: "GravadorAulas", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "configure() antes de start()"])
        }
        let filter = try buildFilter(from: content)
        self.filter = filter

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if cfg.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        try await stream.startCapture()
        self.stream = stream
        AppLog.screen.info("SCStream iniciado: \(self.source.humanLabel, privacy: .public)")
    }

    func stop() async {
        guard let stream = stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            AppLog.screen.error("stopCapture falhou: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        AppLog.screen.info("SCStream parado")
    }

    /// Atualização dinâmica de configuração (ex.: trocar fps).
    func updateConfiguration(_ block: (inout SCStreamConfiguration) -> Void) async throws {
        guard let stream = stream, let cfg = configuration else { return }
        var local = cfg
        block(&local)
        self.configuration = local
        try await stream.updateConfiguration(local)
    }
}

extension ScreenCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        delegate?.screenCapture(self, didOutput: sampleBuffer, type: type)
    }
}

extension ScreenCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        delegate?.screenCapture(self, didStopWithError: error)
    }
}
