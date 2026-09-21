//
//  CMTimeFormatting.swift
//  GravadorAulas
//
//  Helpers de tempo.
//

import Foundation
import CoreMedia

extension CMTime {
    var seconds: Double { CMTimeGetSeconds(self) }
    var positiveOrZero: CMTime { seconds < 0 ? .zero : self }
}

extension TimeInterval {
    var asCMTime: CMTime {
        CMTime(seconds: self, preferredTimescale: 600)
    }
    var hmsString: String {
        let total = Int(max(0, self))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
    var srtTimestamp: String {
        let total = Int(max(0, self * 1000))
        let h = total / 3_600_000
        let m = (total % 3_600_000) / 60_000
        let s = (total % 60_000) / 1000
        let ms = total % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

extension CMTime {
    var hmsString: String { seconds.hmsString }
}