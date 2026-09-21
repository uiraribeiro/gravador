//
//  Effects.swift
//  GravadorAulas
//
//  Renderização de efeitos (blur, pixelização, tarja, fade in/out,
//  destaque do cursor). Implementação completa nas Etapas 2 e 4;
//  aqui estão os tipos e operações sobre o AVVideoComposition.
//

import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia

/// Aplica um efeito numa faixa da composition.
struct EffectApplier {

    static func applyPrivacy(region: PrivacyRegion,
                             to composition: AVMutableVideoComposition,
                             renderSize: CGSize) {
        // Implementação completa na Etapa 4. Aqui apenas ajustamos a posição
        // da região e o tipo. O CIFilter é aplicado por uma
        // AVMutableVideoCompositionInstruction custom (via CALayer no playback).
        _ = region
        _ = composition
        _ = renderSize
    }

    static func fadeInstructions(for clip: Clip) -> [AVMutableVideoCompositionLayerInstruction] {
        // Adiciona fade-in/out como ramps de opacidade. Implementação
        // completa na Etapa 2.
        _ = clip
        return []
    }
}

/// CIFilter pré-fabricados para blur/pixelização. Não usados ainda, mas
/// já compilam para acelerar a Etapa 4.
enum VideoEffectsFilters {

    static func blur(intensity: Double) -> CIFilter & CIBoxBlur {
        let f = CIFilter.boxBlur()
        f.radius = Float(intensity * 30)
        return f
    }

    static func pixelate(intensity: Double) -> CIFilter & CIPixellate {
        let f = CIFilter.pixellate()
        f.center = CGPoint(x: 0.5, y: 0.5)
        f.scale = Float(intensity * 24)
        return f
    }
}