//
//  Exporter.swift
//  GravadorAulas
//
//  Encapsula AVAssetExportSession com progresso, cancelamento e relatório
//  de erros. Para a Etapa 1, produz H.264/AAC; a Etapa 2 adiciona legendas
//  embutidas, SRT lateral e anotações.
//

import Foundation
import AVFoundation
import CoreMedia
import AppKit

@MainActor
final class Exporter: ObservableObject {

    enum Status: Equatable {
        case idle
        case composing(progress: Double)
        case exporting(progress: Double)
        case finished(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var status: Status = .idle

    private var exportSession: AVAssetExportSession?
    private var progressTimer: Timer?
    private var activeCompositor: GravadorAulasCompositor?

    func cancel() {
        exportSession?.cancelExport()
        progressTimer?.invalidate()
        progressTimer = nil
        status = .cancelled
    }

    /// Compõe e exporta. `outputURL` é o destino do MP4 final.
    func export(result: RecordingResult,
                preset: ExportPreset,
                outputURL: URL,
                cameraOverlay: CameraOverlayConfig,
                includeCamera: Bool,
                micVolume: Float,
                systemVolume: Float,
                project: Project? = nil) async {

        do {
            status = .composing(progress: 0)
            let comp = Compositor()
            let composed = try await comp.compose(
                result: result,
                project: project,
                screenSize: CGSize(width: preset.width, height: preset.height),
                cameraOverlay: cameraOverlay,
                includeCamera: includeCamera && !cameraOverlay.hidden,
                micVolume: micVolume,
                systemVolume: systemVolume,
                frameRate: preset.frameRate
            )

            // Remove os mesmos intervalos de todas as trilhas da composição.
            // Processar de trás para frente preserva as posições originais.
            let duration = composed.duration.seconds
            let ranges = (project?.removedRanges ?? [])
                .filter { $0.start >= 0 && $0.end > $0.start && $0.end <= duration }
                .sorted { $0.start < $1.start }
            var merged: [(Double, Double)] = []
            for range in ranges {
                if let last = merged.last, range.start <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, range.end)
                } else {
                    merged.append((range.start, range.end))
                }
            }
            for (start, end) in merged.reversed() {
                let timeRange = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: end - start, preferredTimescale: 600)
                )
                composed.composition.removeTimeRange(timeRange)
            }
            if let instruction = composed.videoComposition?.instructions.first as? AVMutableVideoCompositionInstruction {
                instruction.timeRange = CMTimeRange(start: .zero, duration: composed.composition.duration)
            }

            AppLog.export.info("composição pronta: \(composed.duration.seconds, privacy: .public)s @ \(Int(composed.renderSize.width))x\(Int(composed.renderSize.height))")

            try? FileManager.default.removeItem(at: outputURL)

            // Mapeia o preset do projeto para um AVAssetExportPresetName
            // que respeite a resolução pedida.
            let exportPresetName = Self.avPreset(for: preset)

            // AVAssetExportSession
            guard let session = AVAssetExportSession(
                asset: composed.composition,
                presetName: exportPresetName
            ) else {
                status = .failed("Não foi possível criar o export session.")
                return
            }
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.audioMix = composed.audioMix

            self.exportSession = session
            status = .exporting(progress: 0)
            startProgressTimer(session: session)

            // Se há overlays para aplicar (privacidade / cursor / teclas /
            // anotações), configuramos um compositor customizado.
            let allAnnotations = project?.timeline.tracks.flatMap(\.clips).flatMap(\.annotations) ?? []
            let allEffects = project?.timeline.tracks.flatMap(\.clips).flatMap(\.effects) ?? []
            let allPrivacy = project?.privacyRegions ?? []
            let keyEvents: [KeyCastService.KeyEvent] = (project?.keyEvents ?? []).compactMap { event in
                guard event.timestamp >= 0 && event.timestamp <= duration else { return nil }
                var removedBefore = 0.0
                for (start, end) in merged {
                    if event.timestamp >= start && event.timestamp < end { return nil }
                    if end <= event.timestamp { removedBefore += end - start }
                }
                return KeyCastService.KeyEvent(timestamp: event.timestamp - removedBefore,
                                                display: event.display, isShortcut: true)
            }
            let needsCustomCompositor = !allPrivacy.isEmpty
                || allEffects.contains(where: { $0.kind == .blur || $0.kind == .pixelate || $0.kind == .solidBar })
                || !allAnnotations.isEmpty || !keyEvents.isEmpty

            if needsCustomCompositor {
                let videoTracks = composed.composition.tracks(withMediaType: .video)
                guard let screenTrack = videoTracks.first else {
                    status = .failed("Composição sem vídeo de tela")
                    return
                }
                let compositor = GravadorAulasCompositor()
                compositor.configure(with: CompositorInstructions(
                    renderSize: composed.renderSize,
                    frameDuration: composed.videoComposition?.frameDuration ?? CMTime(value: 1, timescale: 30),
                    totalDuration: composed.duration,
                    privacyRegions: allPrivacy,
                    keyEvents: keyEvents,
                    cursorSamples: [],
                    annotations: allAnnotations,
                    trackKindForInstruction: .screen,
                    screenTrackID: screenTrack.trackID,
                    cameraTrackID: videoTracks.dropFirst().first?.trackID,
                    cameraRect: cameraOverlay.normalizedRect
                ))
                composed.videoComposition?.customVideoCompositorClass = GravadorAulasCompositor.self
                self.activeCompositor = compositor
            }
            session.videoComposition = composed.videoComposition

            await session.export()

            progressTimer?.invalidate()
            progressTimer = nil

            switch session.status {
            case .completed:
                status = .finished(outputURL)
                AppLog.export.info("export concluído: \(outputURL.path, privacy: .public)")
            case .cancelled:
                status = .cancelled
            case .failed:
                status = .failed(session.error?.localizedDescription ?? "Falha desconhecida")
                AppLog.export.error("export falhou: \(session.error?.localizedDescription ?? "?", privacy: .public)")
            default:
                status = .failed("Estado inválido do export session")
            }
        } catch {
            status = .failed(error.localizedDescription)
            AppLog.export.error("export erro: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startProgressTimer(session: AVAssetExportSession) {
        progressTimer?.invalidate()
        // AVAssetExportSession não é Sendable. Envolvemos em @unchecked Sendable
        // para que possa ser capturado por closures @Sendable do Timer/Task.
        let box = UncheckedSendableBox(session)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            let p = box.value.progress
            Task { @MainActor in
                guard let self else { return }
                if case .exporting = self.status {
                    self.status = .exporting(progress: Double(p))
                }
            }
        }
    }
}

/// Wrapper Sendable para classes não-Sendable. Usado quando a API deprecada
/// exige captura em closure @Sendable sem alternativa oficial.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { self.value = v }
}

// MARK: - Preset mapping

extension Exporter {
    /// Mapeia ExportPreset (que tem dimensões em pixels) para o nome de
    /// AVAssetExportPreset correspondente. Sempre H.264 via nome canônico,
    /// garantindo que o bitrate/resolução sejam respeitados pelo AVAssetExportSession
    /// — coisa que `AVAssetExportPresetHighestQuality` não faz (no macOS 27 ele
    /// pode acabar virando HEVC 4K).
    static func avPreset(for preset: ExportPreset) -> String {
        // 4K
        if preset.height >= 2160 { return AVAssetExportPreset3840x2160 }
        // 1440p
        if preset.height >= 1440 { return AVAssetExportPreset1920x1080 /* não há 1440p canônico, fallback para 1080p */ }
        // 1080p
        if preset.height >= 1080 { return AVAssetExportPreset1920x1080 }
        // 720p
        if preset.height >= 720  { return AVAssetExportPreset1280x720 }
        // 540p
        if preset.height >= 540  { return AVAssetExportPreset960x540 }
        // SD
        return AVAssetExportPreset640x480
    }
}
