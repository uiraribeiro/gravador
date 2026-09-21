//
//  Logger.swift
//  GravadorAulas
//
//  Logger unificado. Substituível por OSLog/Logger se desejado.
//

import Foundation
import os

public enum AppLog {
    private static let subsystem = "com.gravadoraulas.app"

    public static let recorder = Logger(subsystem: subsystem, category: "recorder")
    public static let capture  = Logger(subsystem: subsystem, category: "capture")
    public static let camera   = Logger(subsystem: subsystem, category: "camera")
    public static let mic      = Logger(subsystem: subsystem, category: "mic")
    public static let screen   = Logger(subsystem: subsystem, category: "screen")
    public static let export   = Logger(subsystem: subsystem, category: "export")
    public static let editor   = Logger(subsystem: subsystem, category: "editor")
    public static let transc   = Logger(subsystem: subsystem, category: "transcription")
    public static let chapter  = Logger(subsystem: subsystem, category: "chapters")
    public static let keycast  = Logger(subsystem: subsystem, category: "keycast")
    public static let perm     = Logger(subsystem: subsystem, category: "permissions")
    public static let ui       = Logger(subsystem: subsystem, category: "ui")
}