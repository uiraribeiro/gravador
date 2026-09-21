//
//  ExportSheetView.swift
//  GravadorAulas
//
//  UI de exportação com escolha de preset, destino e progresso.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportSheetView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var isPresented: Bool

    @State private var selectedPreset: ExportPreset = ExportPreset.defaultPresets[0]
    @State private var embedSubtitles: Bool = false
    @State private var exportSRT: Bool = true
    @State private var generateChapterText: Bool = true
    @State private var micVolume: Float = 1.0
    @State private var systemVolume: Float = 0.7
    @State private var outputURL: URL?
    @State private var editingPreset: Bool = false
    @State private var showEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Exportar").font(.title2.bold())
                Spacer()
                Button("Fechar") { isPresented = false }
            }
            .padding()

            Divider()

            Form {
                Section("Preset") {
                    Picker("Qualidade", selection: $selectedPreset) {
                        ForEach(ExportPreset.defaultPresets) { p in
                            Text(p.name).tag(p)
                        }
                    }
                    Text(selectedPreset.description)
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("Vídeo: \(selectedPreset.width)×\(selectedPreset.height) @ \(selectedPreset.frameRate)fps")
                        Spacer()
                        Text("\(selectedPreset.videoBitrate / 1_000_000) Mbps")
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    Button("Personalizar…") { showEditor = true }
                }

                Section("Áudio") {
                    Slider(value: $micVolume, in: 0...1) { Text("Microfone") }
                    HStack { Text("Microfone"); Spacer(); Text("\(Int(micVolume*100))%") }
                    Slider(value: $systemVolume, in: 0...1) { Text("Sistema") }
                    HStack { Text("Áudio do sistema"); Spacer(); Text("\(Int(systemVolume*100))%") }
                }

                Section("Saída") {
                    HStack {
                        if let url = outputURL {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("(escolha o arquivo de saída)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Escolher…") { chooseOutput() }
                    }
                    Toggle("Incorporar legendas no MP4", isOn: $embedSubtitles)
                        .disabled(true)
                    Text("Legendas incorporadas ainda não estão disponíveis.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Exportar legendas SRT", isOn: $exportSRT)
                        .disabled(env.currentProject?.transcriptionSegments?.isEmpty ?? true)
                    Toggle("Gerar lista de capítulos", isOn: $generateChapterText)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320)

            Divider()

            statusBar

            Divider()

            HStack {
                Spacer()
                Button("Cancelar") {
                    env.exporter.cancel()
                    isPresented = false
                }
                Button("Exportar") {
                    Task { await runExport() }
                }
                .disabled(outputURL == nil || env.lastRecordingResult == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 540)
        .sheet(isPresented: $showEditor) {
            PresetEditorView(preset: $selectedPreset)
        }
        .onAppear {
            micVolume = env.currentProject?.timeline.track(.microphone)?.volume ?? 1.0
            systemVolume = env.currentProject?.timeline.track(.systemAudio)?.volume ?? 0.7
        }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(env.currentProject?.name ?? "aula").mp4"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK {
            outputURL = panel.url
        }
    }

    private var statusBar: some View {
        Group {
            switch env.exporter.status {
            case .idle:
                EmptyView()
            case .composing(let p):
                statusRow("Compondo…", p)
            case .exporting(let p):
                statusRow("Exportando…", p)
            case .finished(let url):
                Label("Concluído: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding()
            case .failed(let m):
                Label("Falhou: \(m)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .padding()
            case .cancelled:
                Label("Cancelado", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func statusRow(_ label: String, _ progress: Double) -> some View {
        HStack {
            Text(label)
            ProgressView(value: progress)
        }
        .padding()
    }

    private func runExport() async {
        guard let url = outputURL, let result = env.lastRecordingResult else { return }
        var preset = selectedPreset
        preset.embedSubtitles = embedSubtitles
        preset.generateChapterText = generateChapterText

        await env.exporter.export(
            result: result,
            preset: preset,
            outputURL: url,
            cameraOverlay: env.sourceConfig.cameraOverlay,
            includeCamera: env.sourceConfig.camera != nil && !env.sourceConfig.cameraOverlay.hidden,
            micVolume: micVolume,
            systemVolume: systemVolume,
            project: env.currentProject
        )

        if case .finished = env.exporter.status {
            if generateChapterText {
                writeChapterList(to: url.deletingPathExtension().appendingPathExtension("txt"))
            }
            if exportSRT {
                writeSRT(to: url.deletingPathExtension().appendingPathExtension("srt"))
            }
        }
    }

    private func writeChapterList(to url: URL) {
        guard let project = env.currentProject else { return }
        var lines: [String] = []
        lines.append("# Capítulos de \(project.name)")
        lines.append("")
        for ch in project.chapters.sorted(by: { $0.start < $1.start }) {
            let removedBefore = (project.removedRanges ?? []).reduce(0.0) { sum, range in
                sum + max(0, min(ch.start, range.end) - range.start)
            }
            lines.append("\(max(0, ch.start - removedBefore).hmsString)  \(ch.title)")
        }
        let body = lines.joined(separator: "\n")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private func writeSRT(to url: URL) {
        guard let segments = env.currentProject?.transcriptionSegments, !segments.isEmpty else { return }
        let body = segments.enumerated().map { index, segment in
            "\(index + 1)\n\(segment.start.srtTimestamp) --> \(segment.end.srtTimestamp)\n\(segment.text)\n"
        }.joined(separator: "\n")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
