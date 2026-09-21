import SwiftUI

struct PrivacyRegionsView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var draftRect: CGRect
    @State private var start: Double = 0
    @State private var end: Double = 5
    @State private var mode: PrivacyRegion.Mode = .blur
    @State private var intensity: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacidade visual").font(.headline)
            HStack {
                TextField("Início (s)", value: $start, format: .number)
                TextField("Fim (s)", value: $end, format: .number)
            }
            Picker("Proteção", selection: $mode) {
                Text("Desfoque").tag(PrivacyRegion.Mode.blur)
                Text("Pixelização").tag(PrivacyRegion.Mode.pixelate)
                Text("Tarja preta").tag(PrivacyRegion.Mode.solidBar)
            }
            .pickerStyle(.segmented)
            Text("Arraste sobre a prévia para marcar a área.")
                .font(.caption).foregroundStyle(.secondary)
            coordinate("Esquerda", keyPath: \.origin.x)
            coordinate("Topo", keyPath: \.origin.y)
            coordinate("Largura", keyPath: \.size.width)
            coordinate("Altura", keyPath: \.size.height)
            if mode != .solidBar {
                HStack {
                    Text("Intensidade")
                    Slider(value: $intensity, in: 0.1...2)
                }
            }
            Button("Adicionar região") { addRegion() }
                .disabled(!validInput)
            if let regions = env.currentProject?.privacyRegions {
                List(regions) { region in
                    HStack {
                        Text(label(for: region.mode))
                        Text("\(region.start.hmsString) – \(region.end.hmsString)")
                            .monospacedDigit()
                        Spacer()
                        Button(role: .destructive) { removeRegion(region.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 80)
            }
        }
        .padding()
        .onAppear {
            if let duration = env.currentProject?.timeline.duration {
                end = min(end, duration)
            }
        }
    }

    private func coordinate(_ label: String, keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        let value = Binding<Double>(
            get: { Double(draftRect[keyPath: keyPath]) },
            set: { draftRect[keyPath: keyPath] = CGFloat($0) })
        return HStack {
            Text(label).frame(width: 62, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private var validInput: Bool {
        guard let project = env.currentProject else { return false }
        return start >= 0 && end > start && end <= project.timeline.duration
            && draftRect.width > 0 && draftRect.height > 0
            && draftRect.minX >= 0 && draftRect.minY >= 0
            && draftRect.maxX <= 1 && draftRect.maxY <= 1
    }

    private func addRegion() {
        guard validInput, var project = env.currentProject else { return }
        project.privacyRegions.append(PrivacyRegion(
            start: start, end: end,
            rect: draftRect,
            mode: mode, intensity: intensity))
        project.modifiedAt = .now
        env.currentProject = project
    }

    private func removeRegion(_ id: UUID) {
        guard var project = env.currentProject else { return }
        project.privacyRegions.removeAll { $0.id == id }
        project.modifiedAt = .now
        env.currentProject = project
    }

    private func label(for mode: PrivacyRegion.Mode) -> String {
        switch mode {
        case .blur: return "Desfoque"
        case .pixelate: return "Pixels"
        case .solidBar: return "Tarja"
        }
    }
}
