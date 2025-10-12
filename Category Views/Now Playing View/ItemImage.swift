//
//  ItemImage.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 22.08.2025.
//

import SwiftUI
import SDWebImageSwiftUI

/// Simple artwork view for album/track images.
struct ItemImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 12

    var body: some View {
        if let url {
            WebImage(url: url)
                .resizable()                        // allow resizing
                .scaledToFill()                     // fill frame
                .transition(.fade(duration: 0.25))  // nice fade-in
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if url.absoluteString.isEmpty {
                        // fallback if empty URL
                        ZStack {
                            Color.gray.opacity(0.15)
                            Image(systemName: "music.note")
                                .imageScale(.large)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        } else {
            ZStack {
                Color.gray.opacity(0.15)
                Image(systemName: "music.note")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
