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

// MARK: - KeywordsView

struct KeywordsView: View {
    @Binding var globalSelectedPhotos: Set<PhotoAsset>
    @Binding var searchKeywords: Set<String>
    @Binding var selectedNavItems: Set<NavigationItem>
    @Binding var activeSearchText: String

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Person> { $0.isTop100 }, sort: \Person.name) private var topPeople: [Person]

    @State private var filteredPhotos: [PhotoAsset] = []
    @State private var isSearching = false
    @State private var selectedPhotos: Set<PhotoAsset> = []
    @State private var isInspectorPresented = true

    // MARK: – Wyszukiwanie

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

                // Ścieżka 1: relacja Person — szukaj po name, firstName lub lastName
                let personDesc = FetchDescriptor<Person>(predicate: #Predicate<Person> {
                    $0.name == kw || $0.firstName == kw || $0.lastName == kw
                })
                if let persons = try? ctx.fetch(personDesc) {
                    for person in persons {
                        for photo in person.photos where !photo.isTrash { resultSet.insert(photo.persistentModelID) }
                    }
                }

                // Ścieżka 2: keywords array (skan in-memory)
                if resultSet.count < 200 {
                    var kwDesc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false })
                    kwDesc.fetchLimit = 5000
                    if let photos = try? ctx.fetch(kwDesc) {
                        for photo in photos {
                            if photo.keywords.contains(where: { $0.lowercased() == kwLower }) {
                                resultSet.insert(photo.persistentModelID)
                            }
                            if resultSet.count >= 200 { break }
                        }
                    }
                }

                // Ścieżka 3: imageDescription (SQL)
                if resultSet.count < 200 {
                    var photoDesc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> {
                        $0.isTrash == false && $0.imageDescription.localizedStandardContains(kw)
                    })
                    photoDesc.fetchLimit = 100
                    if let photos = try? ctx.fetch(photoDesc) {
                        for photo in photos { resultSet.insert(photo.persistentModelID) }
                    }
                }
            }
            return Array(resultSet.prefix(200))
        }.value
    }

    // MARK: – Akcje

    /// Usuwa konkretne słowo kluczowe (tag) ze wskazanych zdjęć
    private func removeKeyword(_ kw: String, from photos: [PhotoAsset]) {
        for photo in photos {
            photo.keywords.removeAll { $0.lowercased() == kw.lowercased() }
        }
        try? modelContext.save()
        updateFilteredPhotos()
    }

    /// Odpina osobę (relację Person↔PhotoAsset) od konkretnego zdjęcia
    private func removePersonLink(_ person: Person, from photo: PhotoAsset) {
        // 1. NIE usuwamy FaceCrops — muszą zostać, żeby skaner miał embedding
        //    tej osoby z innych zdjęć i mógł ją ponownie dopasować przy rescan.
        //    Scanner sam wyczyści stare cropsy przed nowym skanem.
        //    Zmniejszamy faceCount tylko jeśli crop dotyczący TEGO zdjęcia istnieje.
        let relatedCropsCount = photo.faceCrops.filter { $0.person?.id == person.id }.count
        person.faceCount = max(0, person.faceCount - relatedCropsCount)

        // 2. Odepnij relację Person↔Photo
        photo.people.removeAll { $0.id == person.id }
        person.photos.removeAll { $0.id == photo.id }

        // 3. Usuń stare auto-generowane nazwy z keywords ("Osoba X")
        photo.keywords.removeAll { $0.lowercased() == person.name.lowercased() }

        // 4. Zresetuj flagę skanowania — przy kolejnym "Tylko brakujące"
        //    scanner wykryje WSZYSTKIE twarze od nowa (wyczyści stare cropsie
        //    i dopasuje do klastrów korzystając z embeddingów z innych zdjęć).
        photo.isFaceScanned = false

        try? modelContext.save()
        updateFilteredPhotos()
    }

    /// Usuwa WSZYSTKIE aktywne search-keywords ze wskazanych zdjęć
    private func removeTagFromPhotos(_ photos: [PhotoAsset]) {
        for kw in searchKeywords {
            for photo in photos {
                photo.keywords.removeAll { $0.lowercased() == kw.lowercased() }
                if let person = photo.people.first(where: { $0.name.lowercased() == kw.lowercased() }) {
                    photo.people.removeAll { $0.id == person.id }
                    person.photos.removeAll { $0.id == photo.id }
                }
            }
        }
        try? modelContext.save()
        selectedPhotos.removeAll()
        updateFilteredPhotos()
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
        mainContent
            .inspector(isPresented: $isInspectorPresented) {
                Group {
                    if selectedPhotos.count == 1, let photo = selectedPhotos.first {
                        KeywordsInspectorView(
                            photo: photo,
                            searchKeywords: searchKeywords,
                            onRemoveKeyword: { kw in removeKeyword(kw, from: [photo]) },
                            onRemovePerson: { person in removePersonLink(person, from: photo) }
                        )
                    } else if selectedPhotos.count > 1 {
                        VStack(spacing: 16) {
                            Image(systemName: "photo.stack").font(.system(size: 40)).foregroundColor(.secondary)
                            Text("Wybrano: \(selectedPhotos.count) zdjęć").font(.headline)
                            Divider()
                            actionBarMulti
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "sidebar.right").font(.system(size: 36)).foregroundColor(.secondary)
                            Text("Wybierz zdjęcie").font(.headline).foregroundStyle(.secondary)
                            Text("Kliknij na zdjęcie aby zobaczyć szczegóły").font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isInspectorPresented.toggle() }) {
                        Label("Inspektor", systemImage: "sidebar.right")
                    }.help("Pokaż/ukryj szczegóły zdjęcia")
                }
            }
            .onAppear { updateFilteredPhotos() }
            .onChange(of: searchKeywords) { _, _ in selectedPhotos.removeAll(); updateFilteredPhotos() }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if searchKeywords.isEmpty {
                // --- Pusty stan ---
                VStack(spacing: 20) {
                    ContentUnavailableView("Brak wybranych tagów", systemImage: "tag.slash",
                        description: Text("Zaznacz tagi w Inspektorze lub kliknij na tag osoby/słowa kluczowego."))
                    if !topPeople.isEmpty {
                        VStack(alignment: .center, spacing: 8) {
                            Text("Szybki wybór (Top 100 Osób):").font(.headline).foregroundColor(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(topPeople) { person in
                                        Button(action: { searchKeywords = [person.name] }) {
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
                            ForEach(Array(searchKeywords).sorted(), id: \.self) { kw in
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

                // --- Wyniki / siatka ---
                if isSearching {
                    Spacer()
                    ProgressView("Szukanie tagów...").frame(maxWidth: .infinity, maxHeight: .infinity)
                    Spacer()
                } else if filteredPhotos.isEmpty {
                    ContentUnavailableView("Brak wyników", systemImage: "magnifyingglass",
                        description: Text("Żadne zdjęcie nie ma tagu \(searchKeywords.first.map { "\"\($0)\"" } ?? "")"))
                } else {
                    HStack {
                        Text("\(filteredPhotos.count) \(filteredPhotos.count == 1 ? "zdjęcie" : "zdjęć")")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }.padding(.horizontal).padding(.top, 6)

                    KeywordsPhotoGridView(
                        photos: filteredPhotos, selectedPhotos: $selectedPhotos,
                        searchKeywords: searchKeywords,
                        onRemoveTag: { removeTagFromPhotos($0) },
                        onMoveToTrash: movePhotosToTrash
                    )
                }
            }
        }
    }

    // MARK: – Pasek akcji (jedno zaznaczenie lub wiele)

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
            Text("Zaznaczono: \(selectedPhotos.count)").font(.subheadline.bold())

            Divider().frame(height: 22)

            HStack(spacing: 5) {
                ForEach(kColorLabels, id: \.hex) { item in
                    let isActive = selectedPhotos.allSatisfy { $0.colorLabel?.lowercased() == item.hex.lowercased() }
                    Circle().fill(item.color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(isActive ? 0.9 : 0), lineWidth: 2).padding(1))
                        .onTapGesture { applyColorLabel(isActive ? nil : item.hex) }
                        .help("Kolor: \(item.name)")
                }
                Button(action: { applyColorLabel(nil) }) {
                    Image(systemName: "xmark.circle").font(.caption).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Usuń etykietę koloru")
            }

            Divider().frame(height: 22)

            let allVIP = selectedPhotos.allSatisfy { $0.isVIP }
            Button(action: toggleVIP) {
                Image(systemName: allVIP ? "star.fill" : "star")
                    .foregroundColor(allVIP ? .yellow : .secondary).font(.subheadline)
            }.buttonStyle(.plain).help(allVIP ? "Usuń VIP" : "Oznacz jako VIP")

            Divider().frame(height: 22)

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

            Button(action: { removeTagFromPhotos(Array(selectedPhotos)) }) {
                Label("Usuń tag \(searchKeywords.first.map { "\"\($0)\"" } ?? "") z zaznaczonych", systemImage: "tag.slash")
                    .font(.subheadline.bold())
            }.buttonStyle(.borderedProminent).tint(.red)

            Button(action: { selectedPhotos.removeAll() }) { Text("Odznacz") }.buttonStyle(.bordered)
        }
        .padding(.horizontal).padding(.vertical, 8).background(Color.red.opacity(0.07))
    }

    @ViewBuilder
    private var actionBarMulti: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Kolor:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                HStack(spacing: 8) {
                    ForEach(kColorLabels, id: \.hex) { item in
                        Circle().fill(item.color).frame(width: 20, height: 20)
                            .onTapGesture { applyColorLabel(item.hex) }.help(item.name)
                    }
                    Button(action: { applyColorLabel(nil) }) {
                        Image(systemName: "xmark.circle").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            Button(action: toggleVIP) {
                Label(selectedPhotos.allSatisfy { $0.isVIP } ? "Usuń VIP" : "Oznacz jako VIP", systemImage: "star.fill")
            }.buttonStyle(.borderedProminent).tint(.yellow)
            HStack {
                Text("Ocena:").font(.caption).foregroundColor(.secondary)
                ForEach(1...6, id: \.self) { score in
                    Button(action: { setRating(score) }) {
                        Text("\(score)").font(.caption2.bold()).frame(width: 22, height: 22)
                            .background(Color.secondary.opacity(0.2)).foregroundColor(.primary).cornerRadius(5)
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            Button(action: { removeTagFromPhotos(Array(selectedPhotos)) }) {
                Label("Usuń tag z \(selectedPhotos.count) zaznaczonych", systemImage: "tag.slash")
            }.buttonStyle(.borderedProminent).tint(.red)
            Button(action: { selectedPhotos.removeAll() }) { Text("Odznacz wszystkie") }.buttonStyle(.bordered)
        }
    }
}

// MARK: - Inspektor szczegółów zdjęcia (prawa kolumna)

struct KeywordsInspectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var photo: PhotoAsset
    let searchKeywords: Set<String>
    var onRemoveKeyword: (String) -> Void
    var onRemovePerson: (Person) -> Void

    @State private var loadedImage: NSImage?

    private var peopleTags: [Person] {
        photo.people.sorted { $0.name < $1.name }
    }

    private var keywordTags: [String] {
        let personNames = Set(peopleTags.map { $0.name.lowercased() })
        return Array(Set(photo.keywords).filter { !personNames.contains($0.lowercased()) }).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // --- Miniatura ---
                Group {
                    if let img = loadedImage {
                        Image(nsImage: img).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .background(Color.secondary.opacity(0.07))
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.1))
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .overlay(ProgressView())
                            .task(id: photo.id) { await loadThumbnail() }
                    }
                }

                Form {
                    Section("Plik") {
                        LabeledContent("Nazwa", value: photo.fileName)
                        Text(photo.originalPath).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }

                    Section("Lokalizacja w bibliotece") {
                        LabeledContent("Album", value: photo.folder?.name ?? "Brak")
                        LabeledContent("Wydarzenie", value: photo.event?.name ?? "Brak")
                    }

                    if !peopleTags.isEmpty {
                        Section {
                            ForEach(peopleTags, id: \.id) { person in
                                HStack {
                                    Image(systemName: "person.fill").foregroundColor(.blue).font(.caption)
                                    Text(person.name).font(.callout)
                                        .fontWeight(searchKeywords.map { $0.lowercased() }.contains(person.name.lowercased()) ? .bold : .regular)
                                    Spacer()
                                    Button(action: { onRemovePerson(person) }) {
                                        Image(systemName: "person.crop.circle.badge.minus").foregroundColor(.red)
                                    }.buttonStyle(.plain).help("Odepnij \(person.name) od tego zdjęcia")
                                }
                            }
                        } header: { Label("Osoby na zdjęciu", systemImage: "person.2") }
                    }

                    if !keywordTags.isEmpty {
                        Section {
                            ForEach(keywordTags, id: \.self) { kw in
                                HStack {
                                    Image(systemName: "tag.fill").foregroundColor(.green).font(.caption)
                                    Text(kw).font(.callout)
                                        .foregroundColor(searchKeywords.map { $0.lowercased() }.contains(kw.lowercased()) ? .accentColor : .primary)
                                        .fontWeight(searchKeywords.map { $0.lowercased() }.contains(kw.lowercased()) ? .semibold : .regular)
                                    Spacer()
                                    Button(action: { onRemoveKeyword(kw) }) {
                                        Image(systemName: "minus.circle").foregroundColor(.red)
                                    }.buttonStyle(.plain).help("Usuń tag \"\(kw)\"")
                                }
                            }
                        } header: { Label("Słowa kluczowe", systemImage: "tag") }
                    }

                    if peopleTags.isEmpty && keywordTags.isEmpty {
                        Section {
                            Text("Brak tagów").foregroundStyle(.secondary)
                        } header: { Label("Tagi", systemImage: "tag") }
                    }

                    if !photo.imageDescription.isEmpty {
                        Section("Opis AI") {
                            Text(photo.imageDescription).font(.callout)
                        }
                    }

                    Section("Ocena") {
                        HStack(spacing: 4) {
                            ForEach(1...6, id: \.self) { score in
                                Button(action: {
                                    photo.rating = (photo.rating == score) ? 0 : score
                                    try? modelContext.save()
                                }) {
                                    Text("\(score)").font(.caption2.bold()).frame(width: 22, height: 22)
                                        .background(score <= photo.rating ? Color.accentColor : Color.secondary.opacity(0.2))
                                        .foregroundColor(score <= photo.rating ? .white : .primary).cornerRadius(5)
                                }.buttonStyle(.plain).help("Ocena \(score)/6")
                            }
                            if photo.rating > 0 {
                                Text("(\(photo.rating)/6)").font(.caption2).foregroundColor(.secondary).padding(.leading, 4)
                            }
                        }
                    }

                    Section("Status") {
                        Toggle(isOn: $photo.isVIP) {
                            Label("VIP", systemImage: photo.isVIP ? "star.fill" : "star")
                                .foregroundColor(photo.isVIP ? .yellow : .primary)
                        }.onChange(of: photo.isVIP) { _, _ in try? modelContext.save() }
                    }

                    Section("Kolor etykiety") {
                        HStack(spacing: 8) {
                            ForEach(kColorLabels, id: \.hex) { item in
                                let isActive = photo.colorLabel?.lowercased() == item.hex.lowercased()
                                Button(action: {
                                    photo.colorLabel = isActive ? nil : item.hex
                                    try? modelContext.save()
                                }) {
                                    Circle().fill(item.color).frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(Color.primary, lineWidth: isActive ? 2.5 : 0).padding(1))
                                }.buttonStyle(.plain).help(isActive ? "Usuń etykietę" : item.name)
                            }
                            if photo.colorLabel != nil {
                                Button(action: { photo.colorLabel = nil; try? modelContext.save() }) {
                                    Image(systemName: "xmark.circle").foregroundColor(.secondary)
                                }.buttonStyle(.plain).help("Usuń etykietę koloru")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Szczegóły")
        .onChange(of: photo.id) { _, _ in loadedImage = nil; Task { await loadThumbnail() } }
    }

    private func loadThumbnail() async {
        let key = NSString(string: photo.id.uuidString)
        if let cached = ThumbnailCache.shared.object(forKey: key) { await MainActor.run { loadedImage = cached }; return }
        let pid = photo.id
        if let img = await Task.detached(priority: .userInitiated, operation: { LocalStorage.loadThumbnail(id: pid) }).value {
            ThumbnailCache.shared.setObject(img, forKey: key)
            await MainActor.run { loadedImage = img }
        }
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

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        if let hex = photo.colorLabel { return colorFromHex(hex) }
        return Color.clear
    }
    private var borderWidth: CGFloat { isSelected ? 4 : (photo.colorLabel != nil ? 3 : 0) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let img = loadedImage {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(width: 150, height: 150)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: borderWidth))
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                        .frame(width: 150, height: 150).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: borderWidth))
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
            }
            .frame(width: 150, height: 150)

            Text(photo.fileName).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 150)

            let location = [photo.event?.name, photo.folder?.name].compactMap { $0 }.prefix(1).joined()
            if !location.isEmpty {
                Text(location).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    .truncationMode(.middle).frame(width: 150)
            }

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
