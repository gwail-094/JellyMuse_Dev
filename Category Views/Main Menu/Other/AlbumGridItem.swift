import SwiftUI
import SDWebImageSwiftUI

private struct ExplicitBadge: View {
    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .accessibilityLabel("Explicit")
    }
}

struct AlbumGridItem: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    let album: JellyfinAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WebImage(url: apiService.imageURL(for: album.id)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
            .aspectRatio(1, contentMode: .fit)
            .cornerRadius(8)
            .clipped()

            HStack(spacing: 4) {
                Text(album.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if album.isExplicit {
                    ExplicitBadge()
                }
            }

            if let artistName = album.albumArtists?.first?.name {
                Text(artistName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
