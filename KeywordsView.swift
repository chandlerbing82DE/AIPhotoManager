import SwiftUI
import SwiftData

// Paleta etykiet kolorów (ta sama co w pasku wyszukiwania)
private let kColorLabels: [(name: String, hex: String, color: Color)] = [
    ("Czerwony",     "#FF3B30", .red),
    ("Niebieski",    "#007AFF", .blue),
    ("Zielony",      "#34C759", .green),
    ("Pomarańczowy", "#FF9500", .orange),
    ("Fioletowy",    "#AF52DE", .purple),
]

struct KeywordsView: View {
    @Binding var globalSelectedPhotos: Set<PhotoAsset>
    @Binding var searchKeywords: Set<String>
    
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Person> { $0.isTop100 }, sort: \Person.name) private var topPeople: [Person]
    
    @State private var filteredPhotos: [PhotoAsset] = []
    @State private var isSearching = false
    @State private var selectedPhotos: Set<PhotoAsset> = []

    private func updateFilteredPhotos() {
        guard !searchKeywords.isEmpty else { filteredPhotos = []; return }
        isSearching = true
        let container = modelContext.container
        let kws = searchKeywords
        Task { @MainActor in
            let resultIDs = await performBackgroundSearch(container: container, kws: kws)
            var finalPhotos: [PhotoAsset] = []
            let ctx = container.mainContext
            for id in resultIDs {
                if let model = ctx.registeredModel(for: id) as PhotoAsset? { finalPhotos.append(model); continue }
                if let model = (try? ctx.model(for: id)) as? PhotoAsset { finalPhotos.append(model) }
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
                let kwLower = kw.lowercased()
                // Ścieżka 1: relacja Person.photos (szybka)
                let personDesc = FetchDescriptor<Person>(predicate: #Predicate<Person> { $0.name == kw })
                if let persons = try? ctx.fetch(personDesc) {
                    for person in persons { for photo in person.photos where !photo.isTrash { resultSet.insert(photo.persistentModelID) } }
                }
                if resultSet.count >= 50 { break }
                // Ścieżka 2: imageDescription
                var photoDesc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.imageDescription.localizedStandardContains(kw) })
                photoDesc.fetchLimit = 100
                if let photos = try? ctx.fetch(photoDesc) { for photo in photos { resultSet.insert(photo.persistentModelID) } }
                if resultSet.count >= 50 { break }
                // Ścieżka 3: keywords array
                if resultSet.count < 50 {
                    var kwDesc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false })
                    kwDesc.fetchLimit = 2000
                    if let photos = try? ctx.fetch(kwDesc) {
                        for photo in photos {
                            if photo.keywords.contains(where: { $0.lowercased() == kwLower }) { resultSet.insert(photo.persistentModelID) }
                            if resultSet.count >= 50 { break }
                        }
                    }
                }
                if resultSet.count >= 50 { break }
            }
            return Array(resultSet.prefix(50))
        }.value
    }
    
    // MARK: – Akcje na zaznaczonych zdjęciach
    
    private func removeTagFromPhotos(_ photos: [PhotoAsset]) {
        for kw in searchKeywords {
            for photo in photos {
                photo.keywords.removeAll { $0.lowercased() == kw.lowercased() }
                if let person = photo.people.first(where: { $0.name == kw }) {
                    photo.people.removeAll { $0.id == person.id }
                    person.photos.removeAll { $0.id == photo.id }
                }
            }
        }
        try? modelContext.save(); selectedPhotos.removeAll(); updateFilteredPhotos()
    }
    
    private func applyColorLabel(_ hex: String?) {
        for photo in selectedPhotos { photo.colorLabel = hex }
        try? modelContext.save()
    }
    
    private func toggleVIP() {
        let allVIP = selectedPhotos.allSatisfy { $0.isVIP }
        for photo in selectedPhotos { photo.isVIP = !allVIP }
        try? modelContext.save()
    }
    
    private func setRating(_ score: Int) {
        let allSame = selectedPhotos.allSatisfy { $0.rating == score }
        for photo in selectedPhotos { photo.rating = allSame ? 0 : score }
        try? modelContext.save()
    }
    
    private func movePhotosToTrash(_ photos: [PhotoAsset]) {
        let now = Date()
        for photo in photos {
            photo.isTrash = true; photo.trashDate = now; photo.reviewCategory = nil
            photo.folder = nil; photo.event = nil; photo.people.removeAll()
            for crop in photo.faceCrops { if let person = crop.person { person.faceCount -= 1 }; modelContext.delete(crop) }
            photo.faceCrops.removeAll()
        }
        try? modelContext.save(); globalSelectedPhotos.removeAll()
    }
    
    // MARK: – Body
    
    var body: some View {
        VStack(spacing: 0) {
            if searchKeywords.isEmpty {
                // --- Pusty stan ---
                VStack(spacing: 20) {
                    ContentUnavailableView("Brak wybranych tagów", systemImage: "tag.slash",
                        description: Text("Zaznacz tagi w oknie Inspektora, aby wyszukać powiązane zdjęcia."))
                    if !topPeople.isEmpty {
                        VStack(alignment: .center, spacing: 8) {
                            Text("Szybki wybór (Top 100 Osób):").font(.headline).foregroundColor(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(topPeople) { person in
                                        Button(action: { searchKeywords = [person.name]; updateFilteredPhotos() }) {
                                            HStack { Image(systemName: "person.fill"); Text(person.name) }
                                                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                                                .background(Color.accentColor.opacity(0.8)).foregroundColor(.white).cornerRadius(12)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal)
                            }
                        }
                        .padding(.vertical).background(Color(NSColor.controlBackgroundColor).opacity(0.5)).cornerRadius(12).padding(.horizontal, 32)
                    }
                }
            } else {
                // --- Pasek aktywnych tagów ---
                HStack {
                    Text("Wyszukiwanie po tagach:").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(searchKeywords), id: \.self) { kw in
                                Text(kw).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.accentColor).foregroundColor(.white).cornerRadius(8)
                            }
                        }
                    }
                    Spacer()
                    Button(action: { searchKeywords.removeAll() }) {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundColor(.secondary)
                    }.buttonStyle(.plain).help("Wyczyść filtry")
                }
                .padding().background(Color(NSColor.controlBackgroundColor))
                
                // --- Pasek akcji dla zaznaczonych ---
                if !selectedPhotos.isEmpty {
                    actionBar
                    Divider()
                }
                
                Divider()
                
                // --- Siatka zdjęć ---
                KeywordsPhotoGridView(
                    photos: filteredPhotos, selectedPhotos: $selectedPhotos,
                    searchKeywords: searchKeywords,
                    onRemoveTag: { removeTagFromPhotos($0) },
                    onMoveToTrash: movePhotosToTrash
                )
                .overlay { if isSearching { ProgressView("Szukanie tagów...") } }
            }
        }
        .onAppear { updateFilteredPhotos() }
        .onChange(of: searchKeywords) { _, _ in selectedPhotos.removeAll(); updateFilteredPhotos() }
    }
    
    // MARK: – Pasek akcji (kolor / VIP / ocena / usuń tag)
    
    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            // Licznik
            Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
            Text("Zaznaczono: \(selectedPhotos.count)").font(.subheadline.bold())
            
            Divider().frame(height: 22)
            
            // Etykiety kolorów
            HStack(spacing: 5) {
                ForEach(kColorLabels, id: \.hex) { item in
                    let isActive = selectedPhotos.allSatisfy { $0.colorLabel?.lowercased() == item.hex.lowercased() }
                    Circle().fill(item.color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(isActive ? 0.9 : 0), lineWidth: 2).padding(1))
                        .onTapGesture { applyColorLabel(isActive ? nil : item.hex) }
                        .help("Kolor: \(item.name)")
                }
                // Wyczyść kolor
                Button(action: { applyColorLabel(nil) }) {
                    Image(systemName: "xmark.circle").font(.caption).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Usuń etykietę koloru")
            }
            
            Divider().frame(height: 22)
            
            // VIP
            let allVIP = selectedPhotos.allSatisfy { $0.isVIP }
            Button(action: toggleVIP) {
                Image(systemName: allVIP ? "star.fill" : "star")
                    .foregroundColor(allVIP ? .yellow : .secondary)
                    .font(.subheadline)
            }.buttonStyle(.plain).help(allVIP ? "Usuń VIP" : "Oznacz jako VIP")
            
            Divider().frame(height: 22)
            
            // Ocena 1–6
            HStack(spacing: 3) {
                Text("Ocena:").font(.caption).foregroundColor(.secondary)
                ForEach(1...6, id: \.self) { score in
                    let isActive = selectedPhotos.allSatisfy { $0.rating == score }
                    Button(action: { setRating(score) }) {
                        Text("\(score)").font(.caption2.bold()).frame(width: 18, height: 18)
                            .background(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                            .foregroundColor(isActive ? .white : .primary).cornerRadius(4)
                    }.buttonStyle(.plain).help("Oceń na \(score)/6")
                }
            }
            
            Spacer()
            
            // Usuń tag
            Button(action: { removeTagFromPhotos(Array(selectedPhotos)) }) {
                Label("Usuń tag \(searchKeywords.first.map { "\"\($0)\"" } ?? "") z zaznaczonych", systemImage: "tag.slash")
                    .font(.subheadline.bold())
            }.buttonStyle(.borderedProminent).tint(.red)
            
            Button(action: { selectedPhotos.removeAll() }) { Text("Odznacz") }.buttonStyle(.bordered)
        }
        .padding(.horizontal).padding(.vertical, 8).background(Color.red.opacity(0.07))
    }
}

// MARK: - Siatka zdjęć

struct KeywordsPhotoGridView: View {
    let photos: [PhotoAsset]
    @Binding var selectedPhotos: Set<PhotoAsset>
    let searchKeywords: Set<String>
    let onRemoveTag: ([PhotoAsset]) -> Void
    let onMoveToTrash: ([PhotoAsset]) -> Void
    
    let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]
    @State private var previewPhoto: PhotoAsset? = nil
    
    var tagLabel: String { searchKeywords.first.map { "\"\($0)\"" } ?? "tagu" }
    
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
                        .simultaneousGesture(TapGesture(count: 2).onEnded { previewPhoto = photo })
                        .contextMenu {
                            let targets = isSelected && !selectedPhotos.isEmpty ? Array(selectedPhotos) : [photo]
                            Button(role: .destructive, action: { onRemoveTag(targets) }) {
                                let label = targets.count > 1 ? "Usuń tag \(tagLabel) z \(targets.count) zdjęć" : "Usuń tag \(tagLabel) z tego zdjęcia"
                                Label(label, systemImage: "tag.slash")
                            }
                            Divider()
                            Button(role: .destructive, action: { onMoveToTrash(targets) }) {
                                Label("Przenieś do kosza", systemImage: "trash")
                            }
                        }
                }
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .onTapGesture { selectedPhotos.removeAll() }
        }
        .background(
            Button("") { selectedPhotos = Set(photos) }
                .keyboardShortcut("a", modifiers: .command).opacity(0).allowsHitTesting(false)
        )
        .sheet(item: $previewPhoto) { photo in QuickPhotoPreview(photo: photo) }
    }
}

// MARK: - Komórka zdjęcia

struct KeywordsPhotoCellView: View {
    let photo: PhotoAsset
    let isSelected: Bool
    @State private var loadedImage: NSImage?
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let img = loadedImage {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 150, height: 150).clipped().cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 4 : 0))
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                        .frame(width: 150, height: 150).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 4 : 0))
                        .task(id: photo.id) { await loadThumbnail() }
                }
                
                VStack(alignment: .trailing, spacing: 3) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").font(.title2)
                            .foregroundColor(.accentColor).background(Color.white.clipShape(Circle())).padding(6)
                    }
                    if photo.isVIP {
                        Image(systemName: "star.fill").font(.caption).foregroundColor(.yellow)
                            .shadow(radius: 2).padding(.trailing, 6).padding(.top, isSelected ? 0 : 6)
                    }
                }
                
                // Pasek koloru (lewy dolny róg)
                if let hex = photo.colorLabel, !hex.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            colorFromHex(hex).frame(width: 150, height: 5).cornerRadius(4)
                        }
                    }.frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 150, height: 150)
            
            // Nazwa pliku
            Text(photo.fileName).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 150)
            
            // Wydarzenie / Album
            let location = [photo.event?.name, photo.folder?.name].compactMap { $0 }.prefix(1).joined()
            if !location.isEmpty {
                Text(location).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    .truncationMode(.middle).frame(width: 150)
            }
            
            // Ocena (gwiazdki)
            if photo.rating > 0 {
                HStack(spacing: 2) {
                    ForEach(1...6, id: \.self) { i in
                        Circle().fill(i <= photo.rating ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
    }
    
    private func colorFromHex(_ hex: String) -> Color {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let n = UInt64(h, radix: 16) else { return .accentColor }
        return Color(red: Double((n>>16)&0xFF)/255, green: Double((n>>8)&0xFF)/255, blue: Double(n&0xFF)/255)
    }
    
    private func loadThumbnail() async {
        if loadedImage != nil { return }
        let key = NSString(string: photo.id.uuidString)
        if let cached = ThumbnailCache.shared.object(forKey: key) { await MainActor.run { loadedImage = cached }; return }
        let pid = photo.id
        if let img = await Task.detached(priority: .userInitiated, operation: { LocalStorage.loadThumbnail(id: pid) }).value {
            ThumbnailCache.shared.setObject(img, forKey: key)
            await MainActor.run { loadedImage = img }
        }
    }
}
