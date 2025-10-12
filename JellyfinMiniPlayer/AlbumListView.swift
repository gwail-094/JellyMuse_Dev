import SwiftUI
import Combine

struct AlbumListView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    
    @State private var albums: [JellyfinAlbum] = []
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        List(albums, id: \.id) { album in
            NavigationLink(destination: AlbumDetailView(album: album)) {
                AlbumRow(album: album, apiService: apiService)
            }
        }
        .navigationTitle("Albums")
        .onAppear {
            if albums.isEmpty {
                fetchAlbums()
            }
        }
    }
    
    private func fetchAlbums() {
        apiService.fetchAlbums()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    print("Error fetching albums: \(error.localizedDescription)")
                }
            }, receiveValue: { fetchedAlbums in
                self.albums = fetchedAlbums
            })
            .store(in: &cancellables)
    }
}
