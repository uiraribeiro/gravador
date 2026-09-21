//
//  TimelineBuilder.swift
//  GravadorAulas
//
//  Constrói uma representação interna de timeline a partir de um
//  Project. Etapa 1: apenas cria as trilhas; Etapa 2: adiciona splits,
//  trims, fades e edições.
//

import Foundation
import CoreMedia

struct TimelineBuilder {

    static func build(from project: Project, recordingResult: RecordingResult?) -> Timeline {
        var tracks = Project.defaultTracks()

        if let r = recordingResult {
            // Tela
            for s in r.screen {
                let c = Clip(
                    id: UUID(),
                    assetURL: s.url,
                    sourceStart: 0,
                    sourceDuration: max(0, s.duration == 0 ? 0.001 : s.duration),
                    timelineStart: s.timelineStart
                )
                tracks[0].clips.append(c)
            }
            // Câmera
            for s in r.camera {
                let c = Clip(
                    id: UUID(), assetURL: s.url, sourceStart: 0,
                    sourceDuration: max(0, s.duration == 0 ? 0.001 : s.duration),
                    timelineStart: s.timelineStart
                )
                tracks[1].clips.append(c)
            }
            // Mic
            for s in r.mic {
                let c = Clip(
                    id: UUID(), assetURL: s.url, sourceStart: 0,
                    sourceDuration: max(0, s.duration == 0 ? 0.001 : s.duration),
                    timelineStart: s.timelineStart
                )
                tracks[2].clips.append(c)
            }
            // A trilha do sistema usa o áudio embutido nos arquivos de tela.
            // Os clipes espelhados permitem controlar volume e mudo no editor.
            if project.sources.captureSystemAudio {
                tracks[3].clips = tracks[0].clips.map { clip in
                    var audioClip = clip
                    audioClip.id = UUID()
                    return audioClip
                }
            }
        }

        let duration = max(recordingResult?.timelineDuration ?? 0,
            tracks[0].clips.map { $0.timelineStart + $0.sourceDuration }.max() ?? 0)
        return Timeline(tracks: tracks, duration: duration)
    }
}
