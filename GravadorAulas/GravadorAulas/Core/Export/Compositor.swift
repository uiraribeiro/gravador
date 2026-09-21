//
//  Compositor.swift
//  GravadorAulas
//
//  Constrói um AVMutableComposition a partir dos SegmentRefs
//  de tela/câmera/microfone capturados. Lida com concatenação de
//  segmentos pause/resume e com offsets de timeline.
//
//  Para a Etapa 1, é uma composição direta (sem anotações / blur
//  / overlay complexo). As Etapas 2+ adicionam AVVideoComposition
//  com overlays e AudioMix com volumes/fades.
//

import Foundation
import AVFoundation
import CoreMedia
import AppKit

struct CompositionResult {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix?
    let renderSize: CGSize
    let duration: CMTime
}

final class Compositor {

    enum CompositorError: LocalizedError {
        case noSegments
        case loadFailed(String)
        case renderSizeUnknown

        var errorDescription: String? {
            switch self {
            case .noSegments: return "Não há segmentos para compor."
            case .loadFailed(let s): return "Falha carregando asset: \(s)"
            case .renderSizeUnknown: return "Não foi possível determinar tamanho de saída."
            }
        }
    }

    private let queue = DispatchQueue(label: "gravadoraulas.compositor")

    /// Compõe os segmentos em um único AVMutableComposition.
    func compose(result: RecordingResult,
                 screenSize: CGSize?,
                 cameraOverlay: CameraOverlayConfig,
                 includeCamera: Bool,
                 micVolume: Float = 1.0,
                 systemVolume: Float = 0.7,
                 frameRate: Int = 30) async throws -> CompositionResult {

        guard !result.screen.isEmpty else {
            throw CompositorError.noSegments
        }

        let composition = AVMutableComposition()

        // Resolve tamanho de saída
        let renderSize: CGSize
        if let s = screenSize {
            renderSize = s
        } else {
            renderSize = try await firstVideoSize(segments: result.screen) ?? CGSize(width: 1920, height: 1080)
        }

        // --- Trilha de vídeo principal (tela)
        let screenVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)!
        // --- Trilha de áudio do sistema (dentro do mesmo arquivo screen)
        let sysAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)!

        var cursor: CMTime = .zero
        for seg in result.screen {
            // Verifica se o arquivo existe antes de tentar ler — protege
            // contra segmentos vazios que travariam o AVURLAsset.load.
            guard FileManager.default.fileExists(atPath: seg.url.path) else {
                AppLog.export.warning("segmento de tela ausente: \(seg.url.lastPathComponent, privacy: .public)")
                continue
            }
            let asset = AVURLAsset(url: seg.url)
            do {
                let tracks = try await asset.load(.tracks)
                guard let v = tracks.first(where: { $0.mediaType == .video }) else {
                    AppLog.export.warning("sem vídeo em \(seg.url.lastPathComponent, privacy: .public)")
                    continue
                }
                let dur = try await asset.load(.duration)
                // Pula segmentos com duração ínfima (não dá para compor)
                guard dur.seconds > 0.05 else {
                    AppLog.export.warning("segmento \(seg.url.lastPathComponent, privacy: .public) tem \(dur.seconds, privacy: .public)s — pulando")
                    continue
                }
                let range = CMTimeRange(start: .zero, duration: dur)

                // Vídeo
                try screenVideoTrack.insertTimeRange(range, of: v, at: cursor)

                // Áudio do sistema (se houver)
                if let a = tracks.first(where: { $0.mediaType == .audio }) {
                    do {
                        try sysAudioTrack.insertTimeRange(range, of: a, at: cursor)
                    } catch {
                        AppLog.export.warning("sem trilha de áudio em \(seg.url.lastPathComponent, privacy: .public)")
                    }
                }
                cursor = CMTimeAdd(cursor, dur)
            } catch {
                AppLog.export.error("falha lendo segmento \(seg.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue  // pula segmento ruim em vez de travar tudo
            }
        }
        let totalDuration = cursor

        // --- Trilha de vídeo da câmera (overlay)
        var cameraVideoTrack: AVMutableCompositionTrack? = nil
        if includeCamera, !result.camera.isEmpty {
            cameraVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid)!
            var camCursor: CMTime = .zero
            for seg in result.camera {
                let asset = AVURLAsset(url: seg.url)
                do {
                    let tracks = try await asset.load(.tracks)
                    guard let v = tracks.first(where: { $0.mediaType == .video }) else { continue }
                    let dur = try await asset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: dur)
                    try cameraVideoTrack?.insertTimeRange(range, of: v, at: camCursor)
                    camCursor = CMTimeAdd(camCursor, dur)
                } catch {
                    AppLog.export.error("falha lendo câmera \(seg.url.lastPathComponent, privacy: .public)")
                }
            }
        }

        // --- Trilha de áudio do microfone
        var micAudioTrack: AVMutableCompositionTrack? = nil
        if !result.mic.isEmpty {
            micAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)!
            var micCursor: CMTime = .zero
            for seg in result.mic {
                guard FileManager.default.fileExists(atPath: seg.url.path) else {
                    AppLog.export.warning("segmento de mic ausente: \(seg.url.lastPathComponent, privacy: .public)")
                    continue
                }
                let asset = AVURLAsset(url: seg.url)
                do {
                    let tracks = try await asset.load(.tracks)
                    guard let a = tracks.first(where: { $0.mediaType == .audio }) else {
                        AppLog.export.warning("sem áudio em \(seg.url.lastPathComponent, privacy: .public)")
                        continue
                    }
                    let dur = try await asset.load(.duration)
                    guard dur.seconds > 0.05 else { continue }
                    let range = CMTimeRange(start: .zero, duration: dur)
                    try micAudioTrack?.insertTimeRange(range, of: a, at: micCursor)
                    micCursor = CMTimeAdd(micCursor, dur)
                } catch {
                    AppLog.export.error("falha lendo mic \(seg.url.lastPathComponent, privacy: .public)")
                    continue
                }
            }
        }

        // --- AVMutableVideoComposition
        // Sempre criamos uma videoComposition para garantir que a tela seja
        // escalada para renderSize. Mesmo sem câmera, ela é necessária quando
        // o tamanho da captura difere do tamanho de saída.
        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        let baseInstruction = AVMutableVideoCompositionInstruction()
        baseInstruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)
        baseInstruction.backgroundColor = NSColor.black.cgColor

        // Escala a tela para preencher renderSize respeitando aspect ratio.
        let screenTransform = AVMutableVideoCompositionLayerInstruction(assetTrack: screenVideoTrack)
        let screenNatural = renderSize  // idealmente capturada em renderSize já
        let scaleX = renderSize.width  / screenNatural.width
        let scaleY = renderSize.height / screenNatural.height
        let fillScale = max(scaleX, scaleY)
        let screenScaleTransform = CGAffineTransform(scaleX: fillScale, y: fillScale)
        screenTransform.setTransform(screenScaleTransform, at: .zero)

        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = [screenTransform]

        if let camTrack = cameraVideoTrack {
            let layerCam = AVMutableVideoCompositionLayerInstruction(assetTrack: camTrack)
            let overlayRect = cameraOverlay.normalizedRect
            let overlayW = renderSize.width  * overlayRect.width
            let overlayH = renderSize.height * overlayRect.height
            let overlayX = renderSize.width  * overlayRect.minX
            let overlayY = renderSize.height * (1.0 - overlayRect.minY - overlayRect.height)
            layerCam.setTransform(CGAffineTransform.identity
                                    .translatedBy(x: overlayX, y: overlayY)
                                    .scaledBy(x: overlayW / renderSize.width,
                                              y: overlayH / renderSize.height),
                                  at: .zero)
            layerInstructions.append(layerCam)
        }

        baseInstruction.layerInstructions = layerInstructions
        comp.instructions = [baseInstruction]

        // --- AVMutableAudioMix (volumes)
        let audioMix = AVMutableAudioMix()
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let sys = composition.tracks(withMediaType: .audio).first {
            let p = AVMutableAudioMixInputParameters(track: sys)
            p.setVolume(systemVolume, at: .zero)
            mixParams.append(p)
        }
        if let mic = micAudioTrack {
            let p = AVMutableAudioMixInputParameters(track: mic)
            p.setVolume(micVolume, at: .zero)
            mixParams.append(p)
        }
        if !mixParams.isEmpty {
            audioMix.inputParameters = mixParams
        }

        return CompositionResult(
            composition: composition,
            videoComposition: comp,
            audioMix: mixParams.isEmpty ? nil : audioMix,
            renderSize: renderSize,
            duration: totalDuration
        )
    }

    private func firstVideoSize(segments: [SegmentRef]) async throws -> CGSize? {
        for seg in segments {
            let asset = AVURLAsset(url: seg.url)
            do {
                let tracks = try await asset.load(.tracks)
                if let v = tracks.first(where: { $0.mediaType == .video }) {
                    let dim = try await v.load(.naturalSize)
                    let t = try await v.load(.preferredTransform)
                    let size = applying(transform: t, to: dim)
                    return size
                }
            } catch { continue }
        }
        return nil
    }

    private func applying(transform: CGAffineTransform, to size: CGSize) -> CGSize {
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }
}