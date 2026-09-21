//
//  ChaptersPanelView.swift
//  GravadorAulas
//
//  Stub da Etapa 1. Implementação completa na Etapa 4:
//  - sugestão automática via transcrição
//  - criar/renomear/mover/excluir manualmente
//  - exportar para colar na descrição da plataforma
//

import SwiftUI

struct ChaptersPanelView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading) {
            Text("Capítulos")
                .font(.headline)
            Text("Disponível na Etapa 4 — sugerido por assunto a partir da transcrição.")
                .font(.callout).foregroundStyle(.secondary)

            if let project = env.currentProject {
                List {
                    ForEach(project.chapters) { c in
                        HStack {
                            Text(c.start.hmsString).monospacedDigit()
                            Text(c.title)
                        }
                    }
                }
                .frame(minHeight: 120)
            }
        }
        .padding()
    }
}