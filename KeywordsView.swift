import SwiftUI
import SwiftData

struct KeywordsView: View {
    @Binding var globalSelectedPhotos: Set<PhotoAsset>
    @Binding var searchKeywords: Set<String>
    
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Person> { $0.isTop100 }, sort: \Person.name) private var topPeople: [Person]
    
    @State private var filteredPhotos: [PhotoAsset] = []
    @State private var isSearching = false
    @State private var selectedPhotos: Set<PhotoAsset> = []

    private func updateFilteredPhotos() {
        guard !searchKeywords.isEmpty else {
            filteredPhotos = []
            return
        }
        isSearching = true
        let container = modelContext.container
        let kws = searchKeywords
        
        Task { @MainActor in
            let resultIDs = await performBackgroundSearch(container: container, kws: kws)
            
            var finalPhotos: [PhotoAsset] = []
            let ctx = container.mainContext
            for id in resultIDs {
                let reg: PhotoAsset? = ctx.registeredModel(for: id)
                if let model = reg {
                    finalPhotos.append(model)
                    continue
                }
                if let model = (try? ctx.model(for: id)) as? PhotoAsset {
                    finalPhotos.append(model)
                }
            }
            self.filteredPhotos = finalPhotos.sorted { $0.fileName < $1.fileName }
            self.isSearching = false
        }
    }
    
    private nonisolated func performBackgroundSearch(container: ModelContainer, kws: Set<String>) async -> [PersistentIdentifier] {
        return await Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            var resultSet = Set<PersistentIdentifier>()

            for kw in kws {
                // --- ŚCIEŻKA 1: tagi osób (szybka przez relację Person.photos) ---
                let personDesc = FetchDescriptor<Person>(predicate: #Predicate<Person> { $0.name == kw })
                if let persons = try? ctx.fetch(personDesc) {
                    for person in persons {
                        for photo in person.photos where !photo.isTrash {
                            resultSet.insert(photo.persistentModelID)
                        }
                    }
                }

                // --- ŚCIEŻKA 2: tagi AI (keywords [String] — skanujemy imageDescription) ---
                // keywords są tablicą więc SwiftData nie obsługuje predykatu CONTAINS dla nich —
                // używamy imageDescription jako dodatkowego indeksowalnego pola
                let kwLower = kw.lowercased()
                var photoDesc = FetchDescriptor<PhotoAsset>(
                    predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.imageDescription.localizedStandardContains(kw) }
                )
                photoDesc.fetchLimit = 100
                if let photos = try? ctx.fetch(photoDesc) {
                    for photo in photos {
                        resultSet.insert(photo.persistentModelID)
                    }
                }

                // --- ŚCIEŻKA 3: keywords [String] — musimy niestety skanować, ale z limitem ---
                // Ograniczamy do 2000 i przerywamy wcześnie
                var kwDesc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false })
                kwDesc.fetchLimit = 2000
                kwDesc.propertiesToFetch = [\.keywords, \.persistentModelID]
                if let photos = try? ctx.fetch(kwDesc) {
                    for photo in photos {
                        if photo.keywords.contains(where: { $0.lowercased() == kwLower }) {
                            resultSet.insert(photo.persistentModelID)
                        }
                        if resultSet.count >= 50 { break }
                    }
                }

                if resultSet.count >= 50 { break }
            }

            return Array(resultSet.prefix(50))
        }.value
    }
    
    /// Usuwa tag (keyword lub osobę) z podanych zdjęć
    private func removeTagFromPhotos(_ photos: [PhotoAsset]) {
        for kw in searchKeywords {
            for photo in photos {
                // Usuń z keywords (tagi AI)
                photo.keywords.removeAll { $0.lowercased() == kw.lowercased() }
                // Usuń powiązanie z Person (tagi twarzy)
                if let person = photo.people.first(where: { $0.name == kw }) {
                    photo.people.removeAll { $0.id == person.id }
                    person.photos.removeAll { $0.id == photo.id }
                }
            }
        }
        try? modelContext.save()
        selectedPhotos.removeAll()
        // Odśwież wyniki
        updateFilteredPhotos()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if searchKeywords.isEmpty {
                VStack(spacing: 20) {
                    ContentUnavailableView(
                        "Brak wybranych tagów",
                        systemImage: "tag.slash",
                        description: Text("Zaznacz tagi w oknie Inspektora (np. odczytane z pliku XMP), aby wyszukać powiązane zdjęcia w całej bazie.")
                    )
                    
                    if !topPeople.isEmpty {
                        VStack(alignment: .center, spacing: 8) {
                            Text("Szybki wybór (Top 100 Osob):")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(topPeople) { person in
                                        Button(action: {
                                            searchKeywords = [person.name]
                                            updateFilteredPhotos()
                                        }) {
                                            HStack {
                                                Image(systemName: "person.fill")
                                                Text(person.name)
                                            }
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.8))
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(12)
                        .padding(.horizontal, 32)
                    }
                }
            } else {
                // --- Pasek tagów + wyczyść ---
                HStack {
                    Text("Wyszukiwanie po tagach:").font(.headline)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(searchKeywords), id: \.self) { kw in
                                Text(kw)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: { searchKeywords.removeAll() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Wyczyść filtry")
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                // --- Pasek akcji dla zaznaczonych ---
                if !selectedPhotos.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("Zaznaczono: \(selectedPhotos.count)")
                            .font(.subheadline.bold())
                        Spacer()
                        Button(action: { removeTagFromPhotos(Array(selectedPhotos)) }) {
                            Label(
                                "Usuń tag \(searchKeywords.first.map { "\"\($0)\"" } ?? "") z zaznaczonych",
                                systemImage: "tag.slash"
                            )
                            .font(.subheadline.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        
                        Button(action: { selectedPhotos.removeAll() }) {
                            Text("Odznacz")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.07))
                    
                    Divider()
                }
                
                Divider()
                
                // --- Siatka zdjęć z własnym zaznaczaniem i context menu ---
                KeywordsPhotoGridView(
                    photos: filteredPhotos,
                    selectedPhotos: $selectedPhotos,
                    searchKeywords: searchKeywords,
                    onRemoveTag: { photos in removeTagFromPhotos(photos) },
                    onMoveToTrash: movePhotosToTrash
                )
                .overlay {
                    if isSearching { ProgressView("Szukanie tagów...") }
                }
            }
        }
        .onAppear { updateFilteredPhotos() }
        .onChange(of: searchKeywords) { _, _ in
            selectedPhotos.removeAll()
            updateFilteredPhotos()
        }
    }
    
    // ==========================================
    // FUNKCJE WYKONAWCZE DLA WIDOKU SŁÓW KLUCZOWYCH
    // ==========================================
    
    private func scanAIManually(photos: [PhotoAsset], force: Bool = false) {
        let pids = photos.map { $0.persistentModelID }
        let container = modelContext.container
        Task {
            let scanner = ScannerService()
            // Z poziomu słów kluczowych nie pokazujemy głównego paska, ale zadanie odpali się ładnie w tle!
            await scanner.scanWithAI(photoIDs: pids, container: container, forceOverwrite: force) { _, _, _ in }
        }
    }
    
    private func scanFacesManually(photos: [PhotoAsset]) {
            let pids = photos.map { $0.persistentModelID }
            let container = modelContext.container
            Task {
                let scanner = ScannerService()
                await scanner.scanFaces(photoIDs: pids, container: container, forceOverwrite: true) { _, _, _ in }
            }
        }
    
    private func movePhotosToTrash(_ photos: [PhotoAsset]) {
        let now = Date()
        for photo in photos {
            photo.isTrash = true
            photo.trashDate = now
            photo.reviewCategory = nil
            photo.folder = nil
            photo.event = nil
            photo.people.removeAll()
            for crop in photo.faceCrops {
                if let person = crop.person { person.faceCount -= 1 }
                modelContext.delete(crop)
            }
            photo.faceCrops.removeAll()
        }
        try? modelContext.save()
        globalSelectedPhotos.removeAll()
    }
    
    private func restorePhotos(_ photos: [PhotoAsset]) {
        for photo in photos {
            photo.isTrash = false
            photo.trashDate = nil
        }
        try? modelContext.save()
        globalSelectedPhotos.removeAll()
    }
    
    private func permanentlyDelete(_ photos: [PhotoAsset]) {
        for photo in photos {
            for crop in photo.faceCrops { modelContext.delete(crop) }
            modelContext.delete(photo)
        }
        try? modelContext.save()
        globalSelectedPhotos.removeAll()
    }
}

// MARK: - Siatka z obsługą zaznaczania i usuwania tagów

struct KeywordsPhotoGridView: View {
    let photos: [PhotoAsset]
    @Binding var selectedPhotos: Set<PhotoAsset>
    let searchKeywords: Set<String>
    let onRemoveTag: ([PhotoAsset]) -> Void
    let onMoveToTrash: ([PhotoAsset]) -> Void
    
    let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]
    
    var tagLabel: String {
        searchKeywords.first.map { "\"\($0)\"" } ?? "tagu"
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(photos) { photo in
                    let isSelected = selectedPhotos.contains(photo)
                    
                    KeywordsPhotoCellView(photo: photo, isSelected: isSelected)
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                if isSelected { selectedPhotos.remove(photo) } else { selectedPhotos.insert(photo) }
                            } else {
                                selectedPhotos = [photo]
                            }
                        }
                        .contextMenu {
                            let targets = isSelected && !selectedPhotos.isEmpty ? Array(selectedPhotos) : [photo]
                            
                            Button(role: .destructive, action: { onRemoveTag(targets) }) {
                                let label = targets.count > 1
                                    ? "Usuń tag \(tagLabel) z \(targets.count) zdjęć"
                                    : "Usuń tag \(tagLabel) z tego zdjęcia"
                                Label(label, systemImage: "tag.slash")
                            }
                            
                            Divider()
                            
                            Button(role: .destructive, action: { onMoveToTrash(targets) }) {
                                Label("Przenieś do kosza", systemImage: "trash")
                            }
                        }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { selectedPhotos.removeAll() }
        }
        // Cmd+A zaznacza wszystkie
        .background(
            Button("") { selectedPhotos = Set(photos) }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Komórka zdjęcia

struct KeywordsPhotoCellView: View {
    let photo: PhotoAsset
    let isSelected: Bool
    @State private var loadedImage: NSImage?
    
    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                if let img = loadedImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 150, height: 150)
                        .clipped()
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 4 : 0))
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 4 : 0))
                        .task(id: photo.id) { await loadThumbnail() }
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                        .background(Color.white.clipShape(Circle()))
                        .padding(6)
                }
            }
            Text(photo.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    private func loadThumbnail() async {
        if loadedImage != nil { return }
        let cacheKey = NSString(string: photo.id.uuidString)
        if let cached = ThumbnailCache.shared.object(forKey: cacheKey) {
            await MainActor.run { self.loadedImage = cached }
            return
        }
        let pid = photo.id
        if let img = await Task.detached(priority: .userInitiated, operation: { LocalStorage.loadThumbnail(id: pid) }).value {
            ThumbnailCache.shared.setObject(img, forKey: cacheKey)
            await MainActor.run { self.loadedImage = img }
        }
    }
}
