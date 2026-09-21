//
//  ContentView.swift
//  GravadorAulas
//
//  Tela raiz com navegação por abas (fontes → gravação → revisão).
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var permissions: PermissionsManager
    @State private var stage: Stage = .sources

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
    }

    private var sidebar: some View {
        List(Stage.allCases) { s in
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
            .onTapGesture { stage = s }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private func currentStageMatches(_ s: Stage) -> Bool { s == stage }

    private func icon(for s: Stage) -> String {
        switch s {
        case .sources: return "rectangle.3.group"
        case .record:  return "record.circle"
        case .review:  return "wand.and.stars"
        }
    }
}