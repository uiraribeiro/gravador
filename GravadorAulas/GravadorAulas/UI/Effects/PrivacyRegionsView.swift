//
//  PrivacyRegionsView.swift
//  GravadorAulas
//
//  Stub da Etapa 1. Implementação completa na Etapa 4:
//  - blur / pixelização / tarja em regiões
//  - início/fim, mover/redimensionar
//  - tracking automático (se viável) ou pontos de controle na timeline
//

import SwiftUI

struct PrivacyRegionsView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading) {
            Text("Privacidade visual")
                .font(.headline)
            Text("Disponível na Etapa 4 — desfoque, pixelização ou tarja em regiões com tempo de início e fim.")
                .font(.callout).foregroundStyle(.secondary)

            if let project = env.currentProject {
                List(project.privacyRegions) { r in
                    HStack {
                        Image(systemName: icon(for: r.mode))
                        Text("\(r.start.hmsString) → \(r.end.hmsString)")
                            .monospacedDigit()
                    }
                }
                .frame(minHeight: 100)
            }
        }
        .padding()
    }

    private func icon(for mode: PrivacyRegion.Mode) -> String {
        switch mode {
        case .blur: return "drop.fill"
        case .pixelate: return "circle.grid.cross"
        case .solidBar: return "rectangle.fill"
        }
    }
}