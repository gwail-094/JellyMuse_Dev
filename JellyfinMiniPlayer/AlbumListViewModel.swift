import Foundation
import Combine

class AlbumListViewModel: ObservableObject {
    @Published var albums: [JellyfinAlbum] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let apiService: JellyfinAPIService
    private var cancellables = Set<AnyCancellable>()

    init(apiService: JellyfinAPIService) {
        self.apiService = apiService
        
        apiService.$userId
            .combineLatest(apiService.$serverURL)
            .sink { [weak self] userId, serverURL in
                guard !userId.isEmpty && !serverURL.isEmpty else { return }
                self?.fetchAlbums()
            }
            .store(in: &cancellables)
    }

    func fetchAlbums() {
        guard !apiService.userId.isEmpty else {
            self.errorMessage = "User ID is missing."
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        apiService.fetchAlbums()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                self?.isLoading = false
                if case let .failure(error) = completion {
                    self?.errorMessage = "Failed to load albums: \(error.localizedDescription)"
                }
            }, receiveValue: { [weak self] albums in
                self?.albums = albums
            })
            .store(in: &cancellables)
    }
}
