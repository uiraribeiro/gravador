//
//  GravadorAulasApp.swift
//  GravadorAulas
//

import SwiftUI

@main
struct GravadorAulasApp: App {

    @StateObject private var env = AppEnvironment()
    @StateObject private var permissions = PermissionsManager.shared

    var body: some Scene {
        WindowGroup("Gravador de Aulas") {
            ContentView()
                .environmentObject(env)
                .environmentObject(permissions)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    _ = await permissions.requestMicrophone()
                    _ = await permissions.requestScreenCapture()
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nova gravação") {
                    env.beginNewRecording()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Gravar") {
                    env.requestToggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Pausar / Retomar") {
                    env.requestTogglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}