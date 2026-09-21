//
//  Project.swift
//  GravadorAulas
//

import Foundation

struct Chapter: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var start: Double // segundos na timeline
}

struct IntroOutroTemplate: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kind: Kind
    enum Kind: String, Codable { case intro, outro }
    var backgroundVideoURL: URL?
    var backgroundImageURL: URL?
    var title: String
    var teacher: String
    var logoURL: URL?
    var musicURL: URL?
    var durationSeconds: Double = 4
}

struct PrivacyRegion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var rect: CGRect     // normalizado 0...1 da composição final
    var mode: Mode
    enum Mode: String, Codable { case blur, pixelate, solidBar }
    var intensity: Double = 1.0
}

struct RemovedRange: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
}

struct Project: Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    var sources: SourceConfig
    var timeline: Timeline
    var chapters: [Chapter]
    var privacyRegions: [PrivacyRegion]
    var removedRanges: [RemovedRange]? = []
    var transcriptionSegments: [TranscriptionSegment]? = nil
    var introOutroTemplate: IntroOutroTemplate?

    static func empty(name: String) -> Project {
        Project(
            id: UUID(),
            name: name,
            createdAt: .now,
            modifiedAt: .now,
            sources: SourceConfig(),
            timeline: Timeline(tracks: defaultTracks(), duration: 0),
            chapters: [],
            privacyRegions: [],
            removedRanges: [],
            transcriptionSegments: nil,
            introOutroTemplate: nil
        )
    }

    static func defaultTracks() -> [Track] {
        [
            Track(id: UUID(), kind: .screen,       clips: []),
            Track(id: UUID(), kind: .camera,       clips: []),
            Track(id: UUID(), kind: .microphone,   clips: [], volume: 1.0),
            Track(id: UUID(), kind: .systemAudio,  clips: [], volume: 0.7),
            Track(id: UUID(), kind: .image,        clips: []),
            Track(id: UUID(), kind: .text,         clips: []),
            Track(id: UUID(), kind: .effect,       clips: []),
        ]
    }
}

struct TranscriptionSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var end: Double
    /// "filler" | "silence" | nil
    var kind: String? = nil
}
