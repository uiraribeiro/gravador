//
//  KeyCastService.swift
//  GravadorAulas
//
//  Captura teclas e atalhos via CGEventTap. Implementação completa
//  na Etapa 4. Aqui estão o esqueleto e a fila de eventos.
//
//  Requer que o usuário conceda permissão de Acessibilidade em
//  Preferências do Sistema → Privacidade e Segurança → Acessibilidade.
//

import Foundation
import CoreGraphics
import AppKit

final class KeyCastService {

    struct KeyEvent: Equatable {
        let timestamp: TimeInterval
        let display: String  // ex.: "⌘ C"
        let isShortcut: Bool // Cmd/Ctrl/Opt/Shift envolvidos
    }

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var queue: DispatchQueue?
    private(set) var events: [KeyEvent] = []
    var onEvent: ((KeyEvent) -> Void)?
    private(set) var isRunning: Bool = false

    /// Inicia o tap global. Retorna false se o app não tiver
    /// permissão de Acessibilidade.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userData = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, userDataPtr in
                guard let userDataPtr else { return Unmanaged.passRetained(event) }
                let svc = Unmanaged<KeyCastService>.fromOpaque(userDataPtr).takeUnretainedValue()
                return svc.handle(event: event)
            },
            userInfo: userData
        ) else {
            AppLog.keycast.error("CGEvent.tapCreate falhou — sem permissão de Acessibilidade?")
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoop = CFRunLoopGetMain()
        self.isRunning = true
        AppLog.keycast.info("keycast iniciado")
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        tap = nil
        isRunning = false
        AppLog.keycast.info("keycast parado")
    }

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Política de privacidade: só registra atalhos com modificador.
        // Nunca exibe texto bruto, mesmo digitação "isolada".
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
                         || flags.contains(.maskAlternate) || flags.contains(.maskShift)
        if !isShortcut {
            return Unmanaged.passRetained(event)
        }
        let display = Self.describe(keyCode: Int(keyCode), flags: flags)
        let now = Date.now.timeIntervalSinceReferenceDate
        let e = KeyEvent(timestamp: now, display: display, isShortcut: true)
        events.append(e)
        onEvent?(e)
        return Unmanaged.passRetained(event)
    }

    static func describe(keyCode: Int, flags: CGEventFlags) -> String {
        // Subset mínimo de descrições; a versão completa da Etapa 4 amplia.
        var s = ""
        if flags.contains(.maskControl) { s += "⌃ " }
        if flags.contains(.maskAlternate) { s += "⌥ " }
        if flags.contains(.maskShift) { s += "⇧ " }
        if flags.contains(.maskCommand) { s += "⌘ " }

        let keyChar: String
        switch keyCode {
        case 0: keyChar = "A"
        case 1: keyChar = "S"
        case 2: keyChar = "D"
        case 3: keyChar = "F"
        case 4: keyChar = "H"
        case 5: keyChar = "G"
        case 6: keyChar = "Z"
        case 7: keyChar = "X"
        case 8: keyChar = "C"
        case 9: keyChar = "V"
        case 11: keyChar = "B"
        case 12: keyChar = "Q"
        case 13: keyChar = "W"
        case 14: keyChar = "E"
        case 15: keyChar = "R"
        case 16: keyChar = "Y"
        case 17: keyChar = "T"
        case 36: keyChar = "↩"
        case 48: keyChar = "⇥"
        case 49: keyChar = "Space"
        case 51: keyChar = "⌫"
        case 53: keyChar = "⎋"
        case 76: keyChar = "⌘"
        case 123: keyChar = "←"
        case 124: keyChar = "→"
        case 125: keyChar = "↓"
        case 126: keyChar = "↑"
        default: keyChar = "[\(keyCode)]"
        }
        s += keyChar
        return s
    }
}