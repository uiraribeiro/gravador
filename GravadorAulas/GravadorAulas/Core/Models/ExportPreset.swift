//
//  ExportPreset.swift
//  GravadorAulas
//

import Foundation
import AVFoundation

struct ExportPreset: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var description: String
    /// pixels
    var width: Int
    var height: Int
    var frameRate: Int
    /// bits por segundo do vídeo
    var videoBitrate: Int
    /// bits por segundo do áudio
    var audioBitrate: Int
    var codec: String   // "h264"
    var embedSubtitles: Bool
    var generateChapterText: Bool

    static let defaultPresets: [ExportPreset] = [
        ExportPreset(
            id: UUID(),
            name: "Plataforma de ensino • 1080p",
            description: "H.264 High Profile, AAC 128 kbps. Compatível com a maioria dos players e LMS.",
            width: 1920, height: 1080, frameRate: 30,
            videoBitrate: 6_000_000, audioBitrate: 128_000,
            codec: "h264", embedSubtitles: false, generateChapterText: true
        ),
        ExportPreset(
            id: UUID(),
            name: "Upload leve • 720p",
            description: "H.264 Main Profile, AAC 96 kbps. Arquivo menor para conexões lentas.",
            width: 1280, height: 720, frameRate: 30,
            videoBitrate: 3_000_000, audioBitrate: 96_000,
            codec: "h264", embedSubtitles: false, generateChapterText: true
        ),
        ExportPreset(
            id: UUID(),
            name: "Alta qualidade • 1080p 60fps",
            description: "H.264 High Profile, 60 fps. Para arquivamento e revisão.",
            width: 1920, height: 1080, frameRate: 60,
            videoBitrate: 12_000_000, audioBitrate: 192_000,
            codec: "h264", embedSubtitles: false, generateChapterText: true
        ),
    ]
}