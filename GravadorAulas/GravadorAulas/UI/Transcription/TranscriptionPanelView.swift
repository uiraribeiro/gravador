//
//  TranscriptionPanelView.swift
//  GravadorAulas
//
//  Painel de transcrição funcional:
//    - Botão "Transcrever" roda SFSpeechRecognizer
//    - Lista de segmentos com timestamp e texto
//    - Sugestões de corte (fillers + silêncios) com aceitar/rejeitar
//    - Botão "Exportar SRT"
//

import SwiftUI
import AVFoundation

struct TranscriptionPanelView: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var transcriber = Transcriber()
    @State private var preparationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcrição")
                    .font(.headline)
                Spacer()
                if transcriber.state == .running {
                    ProgressView().controlSize(.small)
                    Text("Transcrevendo…").font(.caption)
                } else if transcriber.onDeviceSupported {
                    Label("on-device", systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            controls
                .padding(.horizontal)

            if !transcriber.segments.isEmpty {
                Divider()
                segmentsList
            }

            if !transcriber.suggestions.isEmpty {
                Divider()
                suggestionsList
            }

            if case .failed(let msg) = transcriber.state {
                Text(msg)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if let preparationError {
                Text(preparationError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .onAppear {
            if let saved = env.currentProject?.transcriptionSegments, !saved.isEmpty,
               transcriber.segments.isEmpty {
                transcriber.loadSegments(saved)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                Task { await transcribeRecording() }
            } label: {
                Label("Transcrever", systemImage: "waveform.badge.mic")
            }
            .disabled(env.lastRecordingResult == nil || transcriber.state == .running)
            .controlSize(.small)

            Button {
                Task { await analyze() }
            } label: {
                Label("Detectar fillers e silêncios", systemImage: "wand.and.stars")
            }
            .disabled(transcriber.segments.isEmpty)
            .controlSize(.small)

            Button {
                applyAllSilences()
            } label: {
                Label("Remover silêncios", systemImage: "speaker.slash")
            }
            .disabled(!transcriber.suggestions.contains(where: { $0.kind == .silence }))
            .controlSize(.small)

            Button {
                exportSRT()
            } label: {
                Label("Exportar SRT", systemImage: "doc.text")
            }
            .disabled(transcriber.segments.isEmpty)
            .controlSize(.small)

            Spacer()
        }
    }

    private var segmentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(transcriber.segments) { seg in
                    HStack(alignment: .top, spacing: 8) {
                        Text(seg.start.hmsString)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(seg.text)
                            .font(.callout)
                            .foregroundStyle(seg.kind == "filler" ? Color.secondary : .primary)
                            .italic(seg.kind == "filler")
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sugestões de corte (\(transcriber.suggestions.count))")
                    .font(.subheadline).bold()
                Spacer()
            }
            .padding(.horizontal)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(transcriber.suggestions) { sug in
                        SuggestionRow(suggestion: sug, onApply: {
                            applySuggestion(sug)
                        })
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    // MARK: - Ações

    private func transcribeRecording() async {
        guard let result = env.lastRecordingResult else { return }
        preparationError = nil
        let sources = result.mic.isEmpty ? result.screen : result.mic
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        do {
            for segment in sources {
                let asset = AVURLAsset(url: segment.url)
                let tracks = try await asset.load(.tracks)
                guard let audio = tracks.first(where: { $0.mediaType == .audio }) else { continue }
                let duration = try await asset.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                    of: audio, at: CMTime(seconds: segment.timelineStart, preferredTimescale: 600))
            }
            guard !track.segments.isEmpty else {
                preparationError = "A gravação não contém áudio para transcrever."
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcricao-\(UUID().uuidString).m4a")
            guard let session = AVAssetExportSession(asset: composition,
                presetName: AVAssetExportPresetAppleM4A) else {
                preparationError = "Não foi possível preparar o áudio para transcrição."
                return
            }
            session.outputURL = url
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else {
                preparationError = session.error?.localizedDescription ?? "Falha preparando áudio."
                return
            }
            await transcriber.transcribe(audioURL: url)
            try? FileManager.default.removeItem(at: url)
            saveTranscription()
        } catch {
            preparationError = error.localizedDescription
        }
    }

    private func analyze() async {
        transcriber.analyzeForEditing(minSilenceSeconds: 0.6)
        saveTranscription()
    }

    private func saveTranscription() {
        guard transcriber.state == .finished, var project = env.currentProject else { return }
        project.transcriptionSegments = transcriber.segments
        project.modifiedAt = .now
        env.currentProject = project
    }

    private func applySuggestion(_ sug: CutSuggestion) {
        guard var project = env.currentProject else { return }
        guard sug.start >= 0, sug.end > sug.start,
              sug.end <= project.timeline.duration else { return }
        project.removedRanges = mergedRanges((project.removedRanges ?? []) +
            [RemovedRange(start: sug.start, end: sug.end)])
        project.modifiedAt = .now
        env.currentProject = project
        transcriber.removeSuggestion(id: sug.id)
    }

    private func applyAllSilences() {
        guard var project = env.currentProject else { return }
        let candidates = transcriber.suggestions.filter {
            $0.kind == .silence && $0.start >= 0 && $0.end > $0.start
                && $0.end <= project.timeline.duration
        }
        guard !candidates.isEmpty else { return }
        project.removedRanges = mergedRanges((project.removedRanges ?? []) +
            candidates.map { RemovedRange(start: $0.start, end: $0.end) })
        project.modifiedAt = .now
        env.currentProject = project
        for suggestion in candidates { transcriber.removeSuggestion(id: suggestion.id) }
    }

    private func mergedRanges(_ ranges: [RemovedRange]) -> [RemovedRange] {
        var result: [RemovedRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(env.currentProject?.name ?? "aula").srt"
        if panel.runModal() == .OK, let url = panel.url {
            try? transcriber.writeSRT(to: url)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: CutSuggestion
    let onApply: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon(for: suggestion.kind))
                .foregroundStyle(color(for: suggestion.kind))
            VStack(alignment: .leading) {
                Text(suggestion.description)
                    .font(.callout)
                Text("\(suggestion.start.hmsString) → \(suggestion.end.hmsString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Aceitar", action: onApply)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal)
    }

    private func icon(for k: CutSuggestion.Kind) -> String {
        switch k {
        case .silence: return "speaker.slash"
        case .filler:  return "text.bubble"
        }
    }

    private func color(for k: CutSuggestion.Kind) -> Color {
        switch k {
        case .silence: return .blue
        case .filler:  return .orange
        }
    }
}
