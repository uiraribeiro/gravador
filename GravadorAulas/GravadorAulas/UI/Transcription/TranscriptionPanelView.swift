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

            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
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
        if let firstMic = result.mic.first {
            await transcriber.transcribe(audioURL: firstMic.url)
        } else if let firstScreen = result.screen.first {
            // Fallback: usa áudio da tela se não houver trilha de mic
            await transcriber.transcribe(audioURL: firstScreen.url)
        }
    }

    private func analyze() async {
        transcriber.analyzeForEditing(minSilenceSeconds: 0.6)
    }

    private func applySuggestion(_ sug: CutSuggestion) {
        guard var project = env.currentProject else { return }
        // Cria uma região de privacidade do tipo .solidBar com duração = gap,
        // o que efetivamente marca o trecho. Implementação completa do corte
        // (remoção + recomposição) fica para a Etapa 2. Por ora, aplicamos
        // o trecho como uma marca visual que será renderizada no export.
        project.timeline.tracks = project.timeline.tracks.map { track in
            var t = track
            // Só marca em tracks de áudio (mic / sistema) ou na tela.
            if [.microphone, .systemAudio, .screen].contains(track.kind) {
                t.clips.append(Clip(
                    id: UUID(),
                    assetURL: t.clips.first?.assetURL ?? URL(fileURLWithPath: "/dev/null"),
                    sourceStart: sug.start,
                    sourceDuration: sug.duration,
                    timelineStart: sug.start,
                    effects: [EffectDescriptor(kind: .solidBar, start: sug.start, duration: sug.duration)]
                ))
            }
            return t
        }
        project.modifiedAt = .now
        env.currentProject = project
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