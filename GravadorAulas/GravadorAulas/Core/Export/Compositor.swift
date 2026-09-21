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
                 project: Project? = nil,
                 screenSize: CGSize?,
                 cameraOverlay: CameraOverlayConfig,
                 includeCamera: Bool,
                 micVolume: Float = 1.0,
                 systemVolume: Float = 0.7,
                 frameRate: Int = 30) async throws -> CompositionResult {

        let screenClips = project?.timeline.track(.screen)?.clips ?? result.screen.map {
            Clip(id: UUID(), assetURL: $0.url, sourceStart: 0,
                 sourceDuration: $0.duration, timelineStart: $0.timelineStart)
        }
        let cameraClips = project?.timeline.track(.camera)?.clips ?? result.camera.map {
            Clip(id: UUID(), assetURL: $0.url, sourceStart: 0,
                 sourceDuration: $0.duration, timelineStart: $0.timelineStart)
        }
        let micClips = project?.timeline.track(.microphone)?.clips ?? result.mic.map {
            Clip(id: UUID(), assetURL: $0.url, sourceStart: 0,
                 sourceDuration: $0.duration, timelineStart: $0.timelineStart)
        }
        let systemClips = (project?.timeline.track(.systemAudio)?.clips.isEmpty == false)
            ? (project?.timeline.track(.systemAudio)?.clips ?? []) : screenClips
        guard !screenClips.isEmpty else {
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

        var totalDuration: CMTime = .zero
        for clip in screenClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            // Verifica se o arquivo existe antes de tentar ler — protege
            // contra segmentos vazios que travariam o AVURLAsset.load.
            guard FileManager.default.fileExists(atPath: clip.assetURL.path) else {
                AppLog.export.warning("segmento de tela ausente: \(clip.assetURL.lastPathComponent, privacy: .public)")
                continue
            }
            let asset = AVURLAsset(url: clip.assetURL)
            do {
                let tracks = try await asset.load(.tracks)
                guard let v = tracks.first(where: { $0.mediaType == .video }) else {
                    AppLog.export.warning("sem vídeo em \(clip.assetURL.lastPathComponent, privacy: .public)")
                    continue
                }
                let dur = try await asset.load(.duration)
                // Pula segmentos com duração ínfima (não dá para compor)
                let usable = min(clip.sourceDuration, dur.seconds - clip.sourceStart)
                guard usable > 0.05 else {
                    AppLog.export.warning("clipe \(clip.assetURL.lastPathComponent, privacy: .public) sem duração válida — pulando")
                    continue
                }
                let range = CMTimeRange(
                    start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: usable, preferredTimescale: 600))
                let position = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)

                // Vídeo
                try screenVideoTrack.insertTimeRange(range, of: v, at: position)

                totalDuration = CMTimeMaximum(totalDuration, CMTimeAdd(position, range.duration))
            } catch {
                AppLog.export.error("falha lendo segmento \(clip.assetURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue  // pula segmento ruim em vez de travar tudo
            }
        }
        guard totalDuration > .zero else { throw CompositorError.noSegments }

        for clip in systemClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            let asset = AVURLAsset(url: clip.assetURL)
            do {
                let tracks = try await asset.load(.tracks)
                guard let audio = tracks.first(where: { $0.mediaType == .audio }) else { continue }
                let duration = try await asset.load(.duration)
                let usable = min(clip.sourceDuration, duration.seconds - clip.sourceStart)
                guard usable > 0.05 else { continue }
                let range = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                                        duration: CMTime(seconds: usable, preferredTimescale: 600))
                try sysAudioTrack.insertTimeRange(range, of: audio,
                    at: CMTime(seconds: clip.timelineStart, preferredTimescale: 600))
            } catch {
                AppLog.export.warning("sem áudio de sistema em \(clip.assetURL.lastPathComponent, privacy: .public)")
            }
        }

        // --- Trilha de vídeo da câmera (overlay)
        var cameraVideoTrack: AVMutableCompositionTrack? = nil
        if includeCamera, !cameraClips.isEmpty {
            cameraVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid)!
            for clip in cameraClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                let asset = AVURLAsset(url: clip.assetURL)
                do {
                    let tracks = try await asset.load(.tracks)
                    guard let v = tracks.first(where: { $0.mediaType == .video }) else { continue }
                    let dur = try await asset.load(.duration)
                    let usable = min(clip.sourceDuration, dur.seconds - clip.sourceStart)
                    guard usable > 0.05 else { continue }
                    let range = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                                            duration: CMTime(seconds: usable, preferredTimescale: 600))
                    try cameraVideoTrack?.insertTimeRange(range, of: v,
                        at: CMTime(seconds: clip.timelineStart, preferredTimescale: 600))
                } catch {
                    AppLog.export.error("falha lendo câmera \(clip.assetURL.lastPathComponent, privacy: .public)")
                }
            }
        }

        // --- Trilha de áudio do microfone
        var micAudioTrack: AVMutableCompositionTrack? = nil
        if !micClips.isEmpty {
            micAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)!
            for clip in micClips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                guard FileManager.default.fileExists(atPath: clip.assetURL.path) else {
                    AppLog.export.warning("segmento de mic ausente: \(clip.assetURL.lastPathComponent, privacy: .public)")
                    continue
                }
                let asset = AVURLAsset(url: clip.assetURL)
                do {
                    let tracks = try await asset.load(.tracks)
                    guard let a = tracks.first(where: { $0.mediaType == .audio }) else {
                        AppLog.export.warning("sem áudio em \(clip.assetURL.lastPathComponent, privacy: .public)")
                        continue
                    }
                    let dur = try await asset.load(.duration)
                    let usable = min(clip.sourceDuration, dur.seconds - clip.sourceStart)
                    guard usable > 0.05 else { continue }
                    let range = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                                            duration: CMTime(seconds: usable, preferredTimescale: 600))
                    try micAudioTrack?.insertTimeRange(range, of: a,
                        at: CMTime(seconds: clip.timelineStart, preferredTimescale: 600))
                } catch {
                    AppLog.export.error("falha lendo mic \(clip.assetURL.lastPathComponent, privacy: .public)")
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
        applyVideoFades(from: screenClips, to: screenTransform)

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
            applyVideoFades(from: cameraClips, to: layerCam)
            layerInstructions.append(layerCam)
        }

        baseInstruction.layerInstructions = layerInstructions
        comp.instructions = [baseInstruction]

        // --- AVMutableAudioMix (volumes)
        let audioMix = AVMutableAudioMix()
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let sys = composition.tracks(withMediaType: .audio).first {
            let p = AVMutableAudioMixInputParameters(track: sys)
            let volume: Float = project?.timeline.track(.systemAudio)?.muted == true ? 0 : systemVolume
            p.setVolume(volume, at: .zero)
            applyAudioFades(from: systemClips, volume: volume, to: p)
            mixParams.append(p)
        }
        if let mic = micAudioTrack {
            let p = AVMutableAudioMixInputParameters(track: mic)
            let volume: Float = project?.timeline.track(.microphone)?.muted == true ? 0 : micVolume
            p.setVolume(volume, at: .zero)
            applyAudioFades(from: micClips, volume: volume, to: p)
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

    private func applyVideoFades(from clips: [Clip], to layer: AVMutableVideoCompositionLayerInstruction) {
        for clip in clips {
            for effect in clip.effects where effect.duration > 0 {
                let range = CMTimeRange(start: CMTime(seconds: effect.start, preferredTimescale: 600),
                    duration: CMTime(seconds: effect.duration, preferredTimescale: 600))
                switch effect.kind {
                case .fadeIn: layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range)
                case .fadeOut: layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
                default: break
                }
            }
        }
    }

    private func applyAudioFades(from clips: [Clip], volume: Float,
                                 to parameters: AVMutableAudioMixInputParameters) {
        for clip in clips {
            for effect in clip.effects where effect.duration > 0 {
                let range = CMTimeRange(start: CMTime(seconds: effect.start, preferredTimescale: 600),
                    duration: CMTime(seconds: effect.duration, preferredTimescale: 600))
                switch effect.kind {
                case .fadeIn: parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: range)
                case .fadeOut: parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: range)
                default: break
                }
            }
        }
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
