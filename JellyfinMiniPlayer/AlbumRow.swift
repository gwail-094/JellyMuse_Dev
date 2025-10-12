import SwiftUI
import SDWebImageSwiftUI

struct AlbumRow: View {
    let album: JellyfinAlbum
    let apiService: JellyfinAPIService
    
    var body: some View {
        HStack {
            WebImage(url: apiService.imageURL(for: album.id))
                .resizable()
                .indicator(.activity)
                .transition(.fade(duration: 0.5))
                .scaledToFill()
                .frame(width: 60, height: 60)
                .background(Color.gray)
                .cornerRadius(4)

            VStack(alignment: .leading) {
                Text(album.name)
                    .font(.headline)
                
                Text(album.artistItems?.first?.name ?? "Unknown Artist")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
