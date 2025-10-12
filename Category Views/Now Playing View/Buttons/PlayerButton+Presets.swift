//
//  PlayerButton+Presets.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 12.10.2025.
//

import SwiftUI

extension PlayerButtonConfig {
    /// Large transport controls (prev / play-pause / next)
    static var transport: Self {
        .init(
            updateUnterval: 0.08,
            size: 64,
            labelColor: .white,   // icon color (idle)
            tint: .white,         // background circle color while pressed
            pressedColor: .black, // icon color while pressed
            disabledColor: .gray
        )
    }

    /// Small circular icon buttons if you want the same press behavior elsewhere
    static var smallIcon: Self {
        .init(
            updateUnterval: 0.08,
            size: 32,
            labelColor: .white,
            tint: .white,
            pressedColor: .black,
            disabledColor: .gray
        )
    }
}
