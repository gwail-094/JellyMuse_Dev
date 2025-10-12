//
//  Delay.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 12.10.2025.
//

import Foundation

@inline(__always)
func delay(_ seconds: Double, _ block: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
}
