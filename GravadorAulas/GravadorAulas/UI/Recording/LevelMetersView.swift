//
//  LevelMetersView.swift
//  GravadorAulas
//

import SwiftUI

struct LevelMetersView: View {
    let level: Float   // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color(for: level))
                    .frame(width: max(0, min(1, CGFloat(level))) * geo.size.width)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 8)
    }

    private func color(for level: Float) -> Color {
        if level > 0.9 { return .red }
        if level > 0.7 { return .orange }
        return .green
    }
}