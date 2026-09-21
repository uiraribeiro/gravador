//
//  ContentView.swift
//  GravadorAulas
//
//  Tela raiz com navegação por abas (fontes → gravação → revisão).
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var permissions: PermissionsManager
    @State private var stage: Stage = .sources
    @State private var openError: String?

    enum Stage: String, CaseIterable, Identifiable {
        case sources = "Fontes"
        case record  = "Gravação"
        case review  = "Revisão"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                switch stage {
                case .sources:
                    SourceSelectionView(onContinue: { stage = .record })
                case .record:
                    RecordingView(onStop: { stage = .review })
                case .review:
                    EditorView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Gravador de Aulas")
        .alert("Não foi possível abrir o projeto", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button("OK") { openError = nil }
            } message: {
                Text(openError ?? "Erro desconhecido")
            }
    }

    private var sidebar: some View {
        List {
            ForEach(Stage.allCases) { s in
                HStack {
                    Image(systemName: icon(for: s))
                    Text(s.rawValue)
                    Spacer()
                    if currentStageMatches(s) {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !env.menuBar.isAttached || s == .record { stage = s }
                }
            }
            Button("Abrir projeto…") { openProject() }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private func currentStageMatches(_ s: Stage) -> Bool { s == stage }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.directoryURL = ProjectStore.shared.defaultProjectsDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try env.openProject(at: url)
            stage = .review
        } catch {
            openError = error.localizedDescription
        }
    }

    private func icon(for s: Stage) -> String {
        switch s {
        case .sources: return "rectangle.3.group"
        case .record:  return "record.circle"
        case .review:  return "wand.and.stars"
        }
    }
}
