//
//  MenuBarController.swift
//  GravadorAulas
//
//  Adiciona um item na NSStatusBar (menu bar do macOS, ao lado do relógio)
//  com botões de Pausar/Retomar e Parar enquanto a gravação está ativa.
//  Isso evita que a janela do app apareça na captura de tela.
//

import Foundation
import AppKit
import Combine

@MainActor
final class MenuBarController: ObservableObject {

    var isAttached: Bool { statusItem != nil }

    private var statusItem: NSStatusItem?
    private weak var session: RecordingSession?
    private var onStopRequested: (() -> Void)?
    private var onCancelRequested: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    /// Anexa o item da menu bar. Remove qualquer item anterior antes.
    func attach(session: RecordingSession,
                onStopRequested: @escaping () -> Void,
                onCancelRequested: @escaping () -> Void) {
        detach()

        self.session = session
        self.onStopRequested = onStopRequested
        self.onCancelRequested = onCancelRequested

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "●"

        let menu = NSMenu()
        let pauseItem = NSMenuItem(title: "Pausar / Retomar",
                                   action: #selector(togglePause),
                                   keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let stopItem = NSMenuItem(title: "Parar e revisar",
                                  action: #selector(stop),
                                  keyEquivalent: ".")
        stopItem.target = self
        menu.addItem(stopItem)

        let separator = NSMenuItem.separator()
        menu.addItem(separator)

        let cancelItem = NSMenuItem(title: "Cancelar gravação (descartar)",
                                    action: #selector(cancel),
                                    keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)

        item.menu = menu
        self.statusItem = item

        // Atualiza o ícone conforme o estado da sessão
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
    }

    func detach() {
        cancellables.removeAll()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        session = nil
        onStopRequested = nil
        onCancelRequested = nil
    }

    // MARK: - Ações

    @objc private func togglePause() {
        guard let session = session else { return }
        switch session.state {
        case .recording: session.pause()
        case .paused:    Task { try? await session.resume() }
        default: break
        }
    }

    @objc private func stop() {
        onStopRequested?()
    }

    @objc private func cancel() {
        onCancelRequested?()
    }

    // MARK: - Visual

    private func updateIcon(for state: RecordingSession.State) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle, .preparing, .ready:
            button.title = "●"
            button.toolTip = "Gravador de Aulas"
        case .recording:
            button.title = "●"
            button.toolTip = "Gravando…"
        case .paused:
            button.title = "⏸"
            button.toolTip = "Pausado"
        case .stopping:
            button.title = "●"
            button.toolTip = "Finalizando…"
        }
    }
}

// MARK: - Helpers de janela

@MainActor
enum WindowHider {
    /// Esconde a janela principal (sem encerrar o app) para que ela não
    /// apareça na captura de tela.
    static func hideMainWindow() {
        // Ocultar a única janela de um WindowGroup faz o SwiftUI criar outra,
        // abandonando a RecordingView e a sessão ativa. Mantemos a janela.
    }

    /// Traz a janela principal de volta e foca.
    static func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
