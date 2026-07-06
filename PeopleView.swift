import SwiftUI
import SwiftData

// 🚨 PANCERNY REJESTR: Śledzi unikalne, niezmienne UUID osób
@Observable @MainActor
class MergeTracker {
    static let shared = MergeTracker()
    var mergingIDs: Set<UUID> = []
}

enum PeopleFilterMode {
    case top100, other, unnamed
}

struct PeopleView: View {
    let filterMode: PeopleFilterMode
    @Binding var searchKeywords: Set<String>
    @Binding var selectedNavItems: Set<NavigationItem>
    @Binding var activeSearchText: String
    
    @Environment(\.modelContext) private var modelContext
    @Query private var people: [Person]
    
    @State private var selectedPerson: Person?
    @State private var searchText = ""
    @State private var showDeleteUnnamedAlert = false
    
    @State private var sortedPeople: [Person] = []
    @State private var cachedNamedPeople: [Person] = []
    @State private var displayLimit: Int = 50
    
    var listTitle: String {
        switch filterMode {
        case .top100: return "Top 100 (Ważne)"
        case .other: return "Inni (Opisani)"
        case .unnamed: return "Pozostali (Turyści)"
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            
            // ==========================================
            // KOLUMNA 1: LISTA OSÓB
            // ==========================================
            VStack(spacing: 0) {
                TextField("Szukaj osoby...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                
                List(selection: $selectedPerson) {
                    Section(listTitle) {
                        ForEach(sortedPeople.prefix(displayLimit)) { person in
                            PersonRow(person: person, namedPeople: cachedNamedPeople, selectedPerson: $selectedPerson)
                                .tag(person)
                        }
                        
                        if sortedPeople.count > displayLimit {
                            HStack {
                                Spacer()
                                Button("Pokaż więcej (zostało \(sortedPeople.count - displayLimit))...") {
                                    displayLimit += 50
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                                .padding(.vertical, 8)
                                Spacer()
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                
                VStack(spacing: 12) {
                    if filterMode != .unnamed {
                        Button(action: {
                            let newPerson = Person(name: "Nowa Osoba")
                            modelContext.insert(newPerson)
                            selectedPerson = newPerson
                        }) {
                            Label("Dodaj ręcznie", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                    
                    if filterMode == .unnamed {
                        Button(role: .destructive) {
                            showDeleteUnnamedAlert = true
                        } label: {
                            Label("Usuń wszystkie nieopisane", systemImage: "trash.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
                .padding()
            }
            .frame(width: 260)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // ==========================================
            // KOLUMNA 2 & 3: WIDOK SZCZEGÓŁÓW
            // ==========================================
            VStack {
                if let person = selectedPerson {
                    PersonDetailWorkspace(person: person, namedPeople: cachedNamedPeople, searchKeywords: $searchKeywords, selectedNavItems: $selectedNavItems, activeSearchText: $activeSearchText)
                        .id(person.id)
                } else {
                    ContentUnavailableView(
                        "Wybierz osobę",
                        systemImage: "person.text.rectangle",
                        description: Text("Wybierz osobę z listy po lewej stronie, aby uzupełnić jej kartotekę i przeglądać zdjęcia.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
        }
        .alert("Usuń obcych z tła", isPresented: $showDeleteUnnamedAlert) {
            Button("Usuń bezpowrotnie", role: .destructive) { deleteUnnamedPeople() }
            Button("Anuluj", role: .cancel) { }
        } message: {
            Text("Usunięte zostaną wszystkie profile zaczynające się od słowa 'Osoba'. Operacja wykona się błyskawicznie w tle.")
        }
        .onAppear { updateList(with: people) }
        .onChange(of: people) { _, newPeople in updateList(with: newPeople) }
        .onChange(of: filterMode) { _, _ in
            displayLimit = 50
            selectedPerson = nil
            searchText = ""
            updateList(with: people)
        }
        .onChange(of: searchText) { _, _ in
            displayLimit = 50
            updateList(with: people)
        }
    }
    
    private func updateList(with allPeople: [Person]) {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allNamed = allPeople.filter { !$0.name.hasPrefix("Osoba ") }
        cachedNamedPeople = allNamed.sorted { $0.name < $1.name }
        
        var result: [Person] = []
        switch filterMode {
        case .top100: result = allNamed.filter { $0.isTop100 }
        case .other: result = allNamed.filter { !$0.isTop100 }
        case .unnamed: result = allPeople.filter { $0.name.hasPrefix("Osoba ") }
        }
        
        if !search.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        result.sort { $0.faceCount > $1.faceCount }
        self.sortedPeople = result
    }
    
    private func deleteUnnamedPeople() {
        if let s = selectedPerson, s.name.hasPrefix("Osoba ") { selectedPerson = nil }
        
        let container = modelContext.container
        Task.detached(priority: .background) {
            let bgCtx = ModelContext(container)
            bgCtx.autosaveEnabled = false
            
            let allPeopleDesc = FetchDescriptor<Person>()
            guard let allPeople = try? bgCtx.fetch(allPeopleDesc) else { return }
            
            let targets = allPeople.filter { $0.name.hasPrefix("Osoba ") }
            var deletedCount = 0
            var affectedPhotoIDs: Set<PersistentIdentifier> = []
            
            for p in targets {
                // Zbieramy ID zdjęć powiązanych z tą osobą z obu źródeł:
                // twarzy (FaceCrop.photo) i relacji (Person.photos)
                for crop in p.faceCrops {
                    if let photoId = crop.photo?.persistentModelID { affectedPhotoIDs.insert(photoId) }
                }
                for photo in p.photos {
                    affectedPhotoIDs.insert(photo.persistentModelID)
                }
                // 🚨 EKSTREMALNA OPTYMALIZACJA ZOMBIAKÓW
                // Nie dotykamy p.faceCrops! Skasowanie osoby aktywuje regułę bazy danych (deleteRule: .cascade)
                // i ukryty silnik SQLite sam po cichu wymaże z dysku twarze. Przyspieszenie 100x!
                bgCtx.delete(p)
                deletedCount += 1
                if deletedCount % 200 == 0 { try? bgCtx.save() } // Batching dla bezpieczeństwa RAMu
            }
            try? bgCtx.save()
            
            // 🚨 Po skasowaniu: zdjęcia, które nie mają już ŻADNEJ twarzy, przestają być oznaczone
            // jako "skanowane" - dzięki temu przy ponownym skanie nie pojawi się mylący monit
            // "znaleziono 0 twarzy", tylko program potraktuje je jak nigdy nieskanowane.
            for photoId in affectedPhotoIDs {
                guard let photo: PhotoAsset = bgCtx.registeredModel(for: photoId) ?? (try? bgCtx.model(for: photoId)) as? PhotoAsset else { continue }
                if photo.faceCrops.isEmpty {
                    photo.isFaceScanned = false
                }
            }
            try? bgCtx.save()
            
            // 🚨 KLUCZOWE: Synchronizacja z głównym kontekstem.
            // SwiftData nie propaguje automatycznie zmian relacji (photo.people) z kontekstu
            // tła do głównego kontekstu — ręcznie czyścimy zombie wpisy w UI.
            let capturedIDs = Array(affectedPhotoIDs)
            await MainActor.run {
                let mainCtx = container.mainContext
                for photoId in capturedIDs {
                    guard let mainPhoto: PhotoAsset = mainCtx.registeredModel(for: photoId) ?? (try? mainCtx.model(for: photoId)) as? PhotoAsset else { continue }
                    // Usuń wszystkie "Osoba X" z photo.people w głównym kontekście
                    mainPhoto.people.removeAll { $0.name.hasPrefix("Osoba ") }
                    if mainPhoto.faceCrops.isEmpty {
                        mainPhoto.isFaceScanned = false
                    }
                }
                try? mainCtx.save()
            }
        }
    }
}

struct PersonRow: View {
    let person: Person
    let namedPeople: [Person]
    @Binding var selectedPerson: Person?
    
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        let isMerging = MergeTracker.shared.mergingIDs.contains(person.id)
        
        HStack {
            ZStack(alignment: .bottomTrailing) {
                if isMerging {
                    ProgressView().controlSize(.small).frame(width: 36, height: 36)
                } else if let firstFace = person.faceCrops.first, let uiImage = NSImage(data: firstFace.cropData) {
                    Image(nsImage: uiImage).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(Circle())
                } else {
                    Circle().fill(Color.secondary.opacity(0.3)).frame(width: 36, height: 36).overlay(Image(systemName: "person.fill").foregroundColor(.secondary))
                }
                
                if person.isTop100 && !isMerging {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                        .background(Circle().fill(Color.black).frame(width: 14, height: 14))
                        .offset(x: 2, y: 2)
                }
            }
            
            VStack(alignment: .leading) {
                Text(person.name).font(.headline)
                if isMerging {
                    Text("Scalanie w tle...").font(.caption).foregroundColor(.accentColor)
                } else {
                    Text("\(person.faceCount) twarzy").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if isMerging {
                Text("Operacja w toku...").foregroundColor(.secondary)
            } else {
                Button(action: {
                    person.isTop100.toggle()
                    try? modelContext.save()
                }) {
                    Label(person.isTop100 ? "Usuń z Top 100" : "Dodaj do Top 100", systemImage: person.isTop100 ? "star.slash" : "star.fill")
                }
                
                Divider()
                
                Menu("Scal z osobą...") {
                    let options = namedPeople.filter { $0.id != person.id }
                    if options.isEmpty {
                        Text("Brak innych opisanych osób").foregroundColor(.secondary)
                    } else {
                        ForEach(options) { target in
                            Button(target.name) {
                                mergePerson(person, into: target)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func mergePerson(_ source: Person, into target: Person) {
        if selectedPerson?.id == source.id { selectedPerson = nil }
        try? modelContext.save()
        
        let sourceModelId = source.persistentModelID
        let targetModelId = target.persistentModelID
        
        let sourceId = source.id
        let targetId = target.id
        
        MergeTracker.shared.mergingIDs.insert(sourceId)
        MergeTracker.shared.mergingIDs.insert(targetId)
        
        let container = modelContext.container
        
        Task.detached(priority: .userInitiated) {
            let bgCtx = ModelContext(container)
            bgCtx.autosaveEnabled = false
            
            guard let bgSource = try? bgCtx.model(for: sourceModelId) as? Person,
                  let bgTarget = try? bgCtx.model(for: targetModelId) as? Person else {
                await MainActor.run {
                    MergeTracker.shared.mergingIDs.remove(sourceId)
                    MergeTracker.shared.mergingIDs.remove(targetId)
                }
                return
            }
            
            // 🚨 OPTYMALIZACJA 1: Przenoszenie twarzy mniejszymi partiami (Batching zapobiegający zadyszce pamięci)
            let cropsToMove = Array(bgSource.faceCrops)
            var processed = 0
            for crop in cropsToMove {
                crop.person = bgTarget
                processed += 1
                if processed % 500 == 0 { try? bgCtx.save() }
            }
            
            // 🚨 OPTYMALIZACJA 2: Odwrócenie ról dla zdjęć (O(1) zamiast O(N^2))
            let targetPhotoIDs = Set(bgTarget.photos.map { $0.persistentModelID })
            let photosToMove = Array(bgSource.photos)
            
            processed = 0
            for photo in photosToMove {
                if !targetPhotoIDs.contains(photo.persistentModelID) {
                    // Dodajemy Osobę do małej tablicy przy Zdjęciu (zamiast Zdjęcia do gigantycznej tablicy u Osoby)
                    photo.people.append(bgTarget)
                }
                processed += 1
                if processed % 500 == 0 { try? bgCtx.save() }
            }
            
            // 3. Przeniesienie licznika
            bgTarget.faceCount += bgSource.faceCount
            bgSource.faceCount = 0
            
            // 4. Skasowanie starej osoby
            bgCtx.delete(bgSource)
            try? bgCtx.save()
            
            await MainActor.run {
                MergeTracker.shared.mergingIDs.remove(sourceId)
                MergeTracker.shared.mergingIDs.remove(targetId)
            }
        }
    }
}

// ==========================================================
// PANELE SZCZEGÓŁÓW (Kartoteka + Siatka Twarzy + Pełne Zdjęcie)
// ==========================================================
struct PersonDetailWorkspace: View {
    let person: Person
    let namedPeople: [Person]
    @Binding var searchKeywords: Set<String>
    @Binding var selectedNavItems: Set<NavigationItem>
    @Binding var activeSearchText: String
    @Environment(\.modelContext) private var modelContext
    
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]
    
    @State private var selectedFaces: Set<FaceCrop> = []
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var preDragSelection: Set<FaceCrop> = []
    
    var dragRect: CGRect {
        guard let s = dragStart, let c = dragCurrent else { return .zero }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }
    
    @State private var draftName: String = ""
    @State private var draftFirstName: String = ""
    @State private var draftLastName: String = ""
    @State private var draftRelationship: String = ""
    @State private var draftBirthDate: String = ""
    @State private var draftDescription: String = ""
    @State private var hasUnsavedChanges: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            
            // --- ŚRODEK: KARTOTEKA + SIATKA + PEŁNE ZDJĘCIE ---
            VStack(spacing: 0) {
                
                // --- KARTOTEKA OSOBY ---
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Kartoteka Osoby").font(.title3.bold())
                        Spacer()
                        Text("Zidentyfikowano: \(person.faceCount) twarzy").font(.caption).foregroundColor(.secondary)
                        
                        if hasUnsavedChanges {
                            Button(action: saveDrafts) { Label("Zapisz zmiany", systemImage: "checkmark.circle.fill") }
                                .buttonStyle(.borderedProminent).tint(.blue)
                        }
                        
                        Button(action: {
                            person.isTop100.toggle()
                            try? modelContext.save()
                        }) {
                            Label(person.isTop100 ? "W Top 100" : "Dodaj do Top 100", systemImage: person.isTop100 ? "star.fill" : "star")
                                .foregroundColor(person.isTop100 ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.1)).cornerRadius(8)
                    }
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Główna nazwa (wyświetlana)").font(.caption).foregroundColor(.secondary)
                            TextField("Np. Jan Kowalski", text: $draftName).textFieldStyle(.roundedBorder)
                                .onChange(of: draftName) { _, _ in hasUnsavedChanges = true }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Relacja").font(.caption).foregroundColor(.secondary)
                            TextField("Np. Wujek, Znajomy z pracy", text: $draftRelationship).textFieldStyle(.roundedBorder)
                                .onChange(of: draftRelationship) { _, _ in hasUnsavedChanges = true }
                        }
                    }
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Imię").font(.caption).foregroundColor(.secondary)
                            TextField("Imię", text: $draftFirstName).textFieldStyle(.roundedBorder)
                                .onChange(of: draftFirstName) { _, newValue in
                                    updateMainName(fName: newValue, lName: draftLastName)
                                    hasUnsavedChanges = true
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nazwisko").font(.caption).foregroundColor(.secondary)
                            TextField("Nazwisko", text: $draftLastName).textFieldStyle(.roundedBorder)
                                .onChange(of: draftLastName) { _, newValue in
                                    updateMainName(fName: draftFirstName, lName: newValue)
                                    hasUnsavedChanges = true
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Data urodzenia").font(.caption).foregroundColor(.secondary)
                            TextField("YYYY-MM-DD", text: $draftBirthDate).textFieldStyle(.roundedBorder).frame(width: 120)
                                .onChange(of: draftBirthDate) { _, _ in hasUnsavedChanges = true }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notatki / Opis").font(.caption).foregroundColor(.secondary)
                        TextField("Dowolne notatki o osobie...", text: $draftDescription).textFieldStyle(.roundedBorder)
                            .onChange(of: draftDescription) { _, _ in hasUnsavedChanges = true }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // --- SIATKA Z TWARZAMI ---
                ZStack {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(person.faceCrops) { crop in
                                let isSelected = selectedFaces.contains(crop)
                                
                                FaceCropCell(crop: crop, isSelected: isSelected)
                                    .background(GeometryReader { geo in
                                        Color.clear.onAppear { cellFrames[crop.id] = geo.frame(in: .named("FaceGridSpace")) }
                                        .onChange(of: geo.frame(in: .named("FaceGridSpace"))) { _, newFrame in cellFrames[crop.id] = newFrame }
                                    })
                                    .onTapGesture {
                                        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                            if isSelected { selectedFaces.remove(crop) } else { selectedFaces.insert(crop) }
                                        } else {
                                            selectedFaces = [crop]
                                        }
                                    }
                                    .contextMenu {
                                        let targets = isSelected ? Array(selectedFaces) : [crop]
                                        let options = namedPeople.filter { $0.id != person.id }
                                        
                                        Menu("Przenieś zaznaczone (\(targets.count)) do innej osoby...") {
                                            if options.isEmpty { Text("Brak celów").foregroundColor(.secondary) }
                                            ForEach(options) { target in
                                                Button(target.name) {
                                                    moveFaces(targets, to: target)
                                                }
                                            }
                                        }
                                        Divider()
                                        Button("Usuń zaznaczone dopasowania", role: .destructive) {
                                            deleteFaces(targets)
                                        }
                                    }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("FaceGridSpace"))
                            .onChanged { val in
                                if dragStart == nil {
                                    dragStart = val.startLocation
                                    preDragSelection = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) ? selectedFaces : []
                                }
                                dragCurrent = val.location
                                var newSelection = preDragSelection
                                let currentRect = dragRect
                                for (id, frame) in cellFrames {
                                    if currentRect.intersects(frame) {
                                        if let crop = person.faceCrops.first(where: { $0.id == id }) {
                                            newSelection.insert(crop)
                                        }
                                    }
                                }
                                selectedFaces = newSelection
                            }
                            .onEnded { _ in dragStart = nil; dragCurrent = nil }
                    )
                    
                    if dragStart != nil {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .stroke(Color.accentColor, lineWidth: 1)
                            .frame(width: dragRect.width, height: dragRect.height)
                            .position(x: dragRect.midX, y: dragRect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "FaceGridSpace")
                
                // --- DOLNY PANEL: PEŁNE ZDJĘCIE ---
                if let firstFace = selectedFaces.first, let photo = firstFace.photo {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Podgląd zdjęcia: \(photo.fileName)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: { selectedFaces.removeAll() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        
                        if let thumbData = LocalStorage.loadThumbnailData(id: photo.id), let img = NSImage(data: thumbData) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300)
                                .padding(.bottom)
                                .padding(.horizontal)
                        } else if let img = NSImage(contentsOfFile: photo.originalPath) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300)
                                .padding(.bottom)
                                .padding(.horizontal)
                        } else {
                            Text("Nie można wczytać podglądu pliku: \(photo.originalPath)")
                                .foregroundColor(.red)
                                .font(.caption)
                                .padding()
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                }
            }
            
            // --- PRAWA KOLUMNA: METADANE ZDJĘCIA ---
            if let firstFace = selectedFaces.first, let photo = firstFace.photo {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Informacje o zdjęciu")
                        .font(.headline)
                        .padding()
                    
                    Divider()
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            MetaRow(icon: "doc.text", title: "Plik", value: photo.fileName)
                            
                            if let date = photo.virtualDateString, !date.isEmpty {
                                MetaRow(icon: "calendar", title: "Data", value: date)
                            }
                            
                            if let event = photo.event {
                                MetaRow(icon: "folder", title: "Wydarzenie", value: event.name)
                            }
                            
                            if !photo.keywords.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Tagi", systemImage: "tag").font(.subheadline).foregroundColor(.secondary)
                                    FlowLayout(spacing: 6) {
                                        ForEach(Array(Set(photo.keywords)).sorted(), id: \.self) { kw in
                                            Button(action: {
                                                activeSearchText = ""
                                                searchKeywords = [kw]
                                                selectedNavItems = [.keywords]
                                            }) {
                                                Text(kw)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.green)
                                                    .foregroundColor(.white)
                                                    .cornerRadius(8)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            
                            if !photo.imageDescription.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Opis AI / EXIF", systemImage: "text.quote").font(.subheadline).foregroundColor(.secondary)
                                    Text(photo.imageDescription)
                                        .font(.body)
                                }
                            }
                        }
                        .padding()
                    }}
                .frame(width: 250)
                .background(Color(NSColor.controlBackgroundColor))
                .transition(.move(edge: .trailing))
            }
        }
        .onAppear { loadDrafts() }
        .onChange(of: person.id) { _, _ in
            loadDrafts()
            selectedFaces.removeAll()
        }
    }
    
    private func loadDrafts() {
        draftName = person.name
        draftFirstName = person.firstName
        draftLastName = person.lastName
        draftRelationship = person.relationship
        draftBirthDate = person.birthDateString
        draftDescription = person.personDescription
        hasUnsavedChanges = false
    }
    
    private func saveDrafts() {
        person.name = draftName
        person.firstName = draftFirstName
        person.lastName = draftLastName
        person.relationship = draftRelationship
        person.birthDateString = draftBirthDate
        person.personDescription = draftDescription
        try? modelContext.save()
        hasUnsavedChanges = false
    }
    
    private func updateMainName(fName: String, lName: String) {
        let f = fName.trimmingCharacters(in: .whitespaces)
        let l = lName.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty || !l.isEmpty {
            draftName = [l, f].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
    
    private func moveFaces(_ crops: [FaceCrop], to target: Person) {
        let count = crops.count
        for crop in crops {
            if let index = person.faceCrops.firstIndex(of: crop) { person.faceCrops.remove(at: index) }
            target.faceCrops.append(crop)
            crop.person = target
        }
        person.faceCount = max(0, person.faceCount - count)
        target.faceCount += count
        try? modelContext.save()
        selectedFaces.subtract(crops)
    }
    
    private func deleteFaces(_ crops: [FaceCrop]) {
        let count = crops.count
        var affectedPhotos: Set<PhotoAsset> = []
        for crop in crops {
            if let index = person.faceCrops.firstIndex(of: crop) { person.faceCrops.remove(at: index) }
            if let photo = crop.photo {
                affectedPhotos.insert(photo)
                if let pIndex = photo.faceCrops.firstIndex(of: crop) { photo.faceCrops.remove(at: pIndex) }
                photo.people.removeAll { $0.id == person.id }
            }
            modelContext.delete(crop)
        }
        person.faceCount = max(0, person.faceCount - count)
        
        // 🚨 Jeśli po usunięciu zdjęcie nie ma już ŻADNEJ wykrytej twarzy, cofamy flagę "skanowania".
        // Dzięki temu program nie będzie już fałszywie ostrzegał "znaleziono 0 twarzy" przy ponownym
        // skanie - potraktuje takie zdjęcie tak, jakby nigdy nie było skanowane w poszukiwaniu twarzy.
        for photo in affectedPhotos {
            if photo.faceCrops.isEmpty {
                photo.isFaceScanned = false
            }
        }
        
        try? modelContext.save()
        selectedFaces.subtract(crops)
    }
}

struct FaceCropCell: View {
    let crop: FaceCrop
    let isSelected: Bool
    
    var body: some View {
        if let uiImage = NSImage(data: crop.cropData) {
            Image(nsImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 4)
                )
                .shadow(color: .black.opacity(isSelected ? 0.3 : 0.1), radius: 4, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 100, height: 100)
        }
    }
}

struct MetaRow: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.subheadline).foregroundColor(.secondary)
            Text(value).font(.body)
        }
    }
}
