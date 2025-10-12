// ElasticSlider+Presets.swift
import SwiftUI

extension ElasticSliderConfig {
    static var playbackProgress: Self {
        .init(
            labelLocation: .bottom,
            maxStretch: 0,                             // progress track doesn’t stretch
            minimumTrackActiveColor: .white,
            minimumTrackInactiveColor: .white.opacity(0.6),
            maximumTrackColor: .white.opacity(0.6),
            blendMode: .overlay,
            syncLabelsStyle: true
        )
    }
    static var volume: Self {
        .init(
            labelLocation: .side,
            maxStretch: 10,                            // gives the elastic feel on edge pull/push
            minimumTrackActiveColor: .white,
            minimumTrackInactiveColor: .white.opacity(0.6),
            maximumTrackColor: .white.opacity(0.6),
            blendMode: .overlay,
            syncLabelsStyle: true
        )
    }
}
