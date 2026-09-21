//
//  Timeline.swift
//  GravadorAulas
//

import Foundation
import CoreMedia

enum TrackKind: String, Codable {
    case screen
    case camera
    case microphone
    case systemAudio
    case image
    case text
    case effect
}

struct Track: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: TrackKind
    var clips: [Clip]
    var muted: Bool = false
    var volume: Float = 1.0
}

struct Clip: Codable, Identifiable, Equatable {
    var id: UUID
    /// URL do arquivo de origem (segmento gravado ou mídia importada).
    var assetURL: URL
    /// Trecho dentro do asset, em segundos.
    var sourceStart: Double
    var sourceDuration: Double
    /// Posição do início do clipe na timeline, em segundos.
    var timelineStart: Double
    var effects: [EffectDescriptor] = []
    var annotations: [Annotation] = []

    var timelineDuration: Double { sourceDuration }
}

struct EffectDescriptor: Codable, Equatable {
    enum Kind: String, Codable {
        case fadeIn, fadeOut, blur, pixelate, solidBar
    }
    var kind: Kind
    var start: Double
    var duration: Double
    var intensity: Double = 1.0
    var rect: CGRect? = nil
}

struct Annotation: Codable, Equatable {
    enum Kind: String, Codable { case arrow, circle, rectangle, text, image, keyPress }
    var kind: Kind
    var start: Double
    var duration: Double
    var rect: CGRect
    var text: String?
    var color: String? // hex
    var intensity: Double = 1.0
}

struct Timeline: Codable, Equatable {
    var tracks: [Track]
    var duration: Double

    func track(_ kind: TrackKind) -> Track? {
        tracks.first { $0.kind == kind }
    }
}