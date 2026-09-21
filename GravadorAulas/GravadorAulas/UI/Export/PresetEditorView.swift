//
//  PresetEditorView.swift
//  GravadorAulas
//

import SwiftUI

struct PresetEditorView: View {
    @Binding var preset: ExportPreset
    @Environment(\.dismiss) private var dismiss

    @State private var widthText: String = ""
    @State private var heightText: String = ""

    var body: some View {
        VStack {
            HStack {
                Text("Personalizar preset").font(.title3.bold())
                Spacer()
                Button("Fechar") { dismiss() }
            }
            .padding()

            Form {
                TextField("Nome", text: $preset.name)
                TextField("Descrição", text: $preset.description)

                HStack {
                    Text("Resolução:")
                    TextField("Largura", text: $widthText)
                        .frame(width: 60)
                    Text("×")
                    TextField("Altura", text: $heightText)
                        .frame(width: 60)
                }

                Picker("Quadros/s", selection: $preset.frameRate) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }

                Stepper(value: $preset.videoBitrate, in: 500_000...50_000_000, step: 500_000) {
                    Text("Vídeo: \(preset.videoBitrate / 1_000_000) Mbps")
                }

                Stepper(value: $preset.audioBitrate, in: 64_000...320_000, step: 16_000) {
                    Text("Áudio: \(preset.audioBitrate / 1_000) kbps")
                }

                Toggle("Incorporar legendas no MP4", isOn: $preset.embedSubtitles)
                Toggle("Gerar lista de capítulos", isOn: $preset.generateChapterText)
            }
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 460)
        }
        .onAppear {
            widthText  = String(preset.width)
            heightText = String(preset.height)
        }
        .onDisappear {
            preset.width  = Int(widthText)  ?? preset.width
            preset.height = Int(heightText) ?? preset.height
        }
    }
}