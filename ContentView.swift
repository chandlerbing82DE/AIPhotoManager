import SwiftUI
import SwiftData
import AppKit
import MapKit
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import Vision

// ==========================================
// GŁÓWNY WIDOK INTERFEJSU
// ==========================================

// ==========================================
// TYPY POMOCNICZE (NAWIGACJA I STAN ZADAŃ)
// ==========================================

enum NavigationItem: Hashable {
    case allPhotos
    case vipPhotos
    case folder(VirtualFolder)
    case event(EventFolder)
    case keywords
    case peopleTop100
    case peopleOther
    case peopleUnnamed
    case reviewAll
    case reviewDocs
    case reviewDupes
    case reviewOther
    case trash
}

@Observable
@MainActor
class JobState {
    var isScanning = false
    var isDeletingDatabase = false
    var progressStatus = ""
    var progressCount = 0
    var progressTotal = 0
    var currentScanner: ScannerService? = nil
    
    var isActive: Bool {
        isScanning || isDeletingDatabase
    }
    
    func cancel() {
        let scanner = currentScanner
        Task {
            await scanner?.requestCancel()
        }
        isScanning = false
        progressStatus = "Anulowanie..."
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var displayPhotos: [PhotoAsset] = []
    
    @Query(filter: #Predicate<PhotoAsset> { $0.isTrash == true }, sort: \PhotoAsset.trashDate, order: .reverse) private var trashedPhotos: [PhotoAsset]
    @Query private var allFolders: [VirtualFolder]
    @Query private var allEvents: [EventFolder]
    @Query(filter: #Predicate<VirtualFolder> { $0.parentFolder == nil }, sort: \VirtualFolder.name) private var rootFolders: [VirtualFolder]
    @Query(filter: #Predicate<EventFolder> { $0.parentEvent == nil }, sort: \EventFolder.name) private var rootEvents: [EventFolder]
    
    @State private var jobState = JobState()
    @State private var selectedNavItems: Set<NavigationItem> = [.allPhotos]
    @State private var isManualEventsExpanded: Bool = true; @State private var isScanEventsExpanded: Bool = false
    @State private var showingDeletePinAlert = false; @State private var deletePinInput = ""
    @State private var showingRenameAlert = false; @State private var itemToRename: NavigationItem? = nil; @State private var renameText = ""
    @State private var showingCreateRootEventAlert = false; @State private var newRootEventName = ""
    @State private var showingOverwriteAlert = false; @State private var pendingAIPhotos: [PhotoAsset] = []
    @State private var showingMultiMergeAlert = false; @State private var eventsToMerge: [EventFolder] = []; @State private var mergedEventName = ""
    
    @State private var searchKeywords: Set<String> = []
    @State private var activeSearchText: String = ""
    @State private var activeSearchDate: String = ""
    @State private var activeSearchVIP: Bool = false
    @State private var activeSearchColorHex: String? = nil
    @State private var activeRatings: Set<Int> = []
    
    @State private var currentSearchTask: Task<Void, Never>? = nil
    @State private var showingAISettings = false
    @State private var showingCleanupAlert = false
    @State private var showingGlobalAIAlert = false
    @State private var showingGlobalFacesAlert = false
    @State private var showingFaceOverwriteAlert = false
    @State private var pendingFacePhotos: [PhotoAsset] = []
    
    var isSearchActive: Bool { !activeSearchText.isEmpty || !activeSearchDate.isEmpty || activeSearchVIP || activeSearchColorHex != nil || !activeRatings.isEmpty }
    var isPeopleTab: Bool { if selectedNavItems.count == 1, let item = selectedNavItems.first { switch item { case .peopleTop100, .peopleOther, .peopleUnnamed: return true; default: return false } }; return false }
    
    private func loadPhotosFromDatabase() {
        currentSearchTask?.cancel()
        
        if isSearchActive {
            let container = modelContext.container
            let text = activeSearchText.lowercased()
            let date = activeSearchDate.lowercased()
            let hexColor = activeSearchColorHex?.lowercased()
            let ratings = activeRatings
            let isVIPOnly = selectedNavItems.contains(.vipPhotos) || activeSearchVIP
            
            currentSearchTask = Task.detached(priority: .userInitiated) {
                let bgContext = ModelContext(container)
                let predicate: Predicate<PhotoAsset>
                if isVIPOnly {
                    predicate = #Predicate<PhotoAsset> { $0.isTrash == false && $0.isVIP == true }
                } else {
                    predicate = #Predicate<PhotoAsset> { $0.isTrash == false }
                }
                
                let descriptor = FetchDescriptor<PhotoAsset>(predicate: predicate)
                guard let fetched = try? bgContext.fetch(descriptor) else { return }
                
                var resultIDs: [PersistentIdentifier] = []
                for p in fetched {
                    if Task.isCancelled { return }
                    
                    if let hex = hexColor {
                        let fHex = p.folder?.colorHex?.lowercased()
                        let eHex = p.event?.colorHex?.lowercased()
                        if fHex != hex && eHex != hex { continue }
                    }
                    if !ratings.isEmpty && !ratings.contains(p.rating) { continue }
                    if !date.isEmpty {
                        let t1 = p.virtualDateString?.lowercased() ?? ""; let t2 = p.folder?.virtualDateString?.lowercased() ?? ""; let t3 = p.event?.virtualDateString?.lowercased() ?? ""
                        if !t1.contains(date) && !t2.contains(date) && !t3.contains(date) { continue }
                    }
                    if !text.isEmpty {
                        let mName = p.fileName.lowercased().contains(text)
                        let mDesc = p.imageDescription.lowercased().contains(text)
                        let mKey = p.keywords.contains { $0.lowercased().contains(text) }
                        let mPerson = p.people.contains { $0.name.lowercased().contains(text) || $0.firstName.lowercased().contains(text) || $0.lastName.lowercased().contains(text) }
                        if !mName && !mDesc && !mKey && !mPerson { continue }
                    }
                    
                    resultIDs.append(p.persistentModelID)
                    if resultIDs.count >= 200 { break }
                }
                
                if Task.isCancelled { return }
                
                let finalIDs = resultIDs
                await MainActor.run {
                    let mainCtx = container.mainContext
                    var finalPhotos: [PhotoAsset] = []
                    for id in finalIDs {
                        let reg: PhotoAsset? = mainCtx.registeredModel(for: id)
                        if let model = reg {
                            finalPhotos.append(model)
                            continue
                        }
                        if let model = (try? mainCtx.model(for: id)) as? PhotoAsset {
                            finalPhotos.append(model)
                        }
                    }
                    if !Task.isCancelled { self.displayPhotos = finalPhotos }
                }
            }
            return
        }
        
        if selectedNavItems.isEmpty { displayPhotos = []; return }
        if selectedNavItems.count == 1, let item = selectedNavItems.first {
            switch item {
            case .allPhotos:
                var desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false }); desc.fetchLimit = 200
                displayPhotos = (try? modelContext.fetch(desc)) ?? []
            case .vipPhotos:
                var desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.isVIP == true }); desc.fetchLimit = 500
                displayPhotos = (try? modelContext.fetch(desc)) ?? []
            case .folder(let f): displayPhotos = f.photosRecursively(limit: 200)
            case .event(let e): displayPhotos = e.photosRecursively(limit: 200)
            case .trash: displayPhotos = trashedPhotos
            case .reviewAll:
                var desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.reviewCategory != nil }); desc.fetchLimit = 200
                displayPhotos = (try? modelContext.fetch(desc)) ?? []
            case .reviewDocs:
                var desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.reviewCategory == "Dokumenty" }); desc.fetchLimit = 200
                displayPhotos = (try? modelContext.fetch(desc)) ?? []
            case .reviewDupes:
                var desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.reviewCategory == "Duplikaty" }); desc.fetchLimit = 200
                displayPhotos = (try? modelContext.fetch(desc)) ?? []
            case .reviewOther:
                var desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false && $0.reviewCategory != nil && $0.reviewCategory != "Dokumenty" && $0.reviewCategory != "Duplikaty" }); desc.fetchLimit = 200
                displayPhotos = (try? modelContext.fetch(desc)) ?? []
            default: displayPhotos = []
            }
        }
    }
    
    private func onScanCleanupToolbar() { showingCleanupAlert = true }
    private func onAISettingsToolbar() { showingAISettings = true }
    private func onAIGlobalToolbar() { showingGlobalAIAlert = true }
    private func onScanFacesToolbar() { showingGlobalFacesAlert = true }

    var body: some View {
        mainContent
        .onAppear { autoEmptyTrash(); loadPhotosFromDatabase() }
        .onChange(of: selectedNavItems) { _, _ in loadPhotosFromDatabase() }
        .onChange(of: activeSearchText) { _, _ in loadPhotosFromDatabase() }
        .onChange(of: activeSearchDate) { _, _ in loadPhotosFromDatabase() }
        .onChange(of: activeSearchVIP) { _, _ in loadPhotosFromDatabase() }
        .onChange(of: activeSearchColorHex) { _, _ in loadPhotosFromDatabase() }
        .onChange(of: activeRatings) { _, _ in loadPhotosFromDatabase() }
        .alert("Usuwanie bazy", isPresented: $showingDeletePinAlert) { SecureField("PIN", text: $deletePinInput); Button("Anuluj", role: .cancel) { }; Button("Usuń", role: .destructive) { if deletePinInput == "8203" { performDeepClean() } } }
        .alert("Zmień nazwę", isPresented: $showingRenameAlert) { TextField("Nazwa", text: $renameText); Button("Anuluj", role: .cancel) { }; Button("Zapisz") { if let item = itemToRename { switch item { case .folder(let f): f.name = renameText; case .event(let e): e.name = renameText; default: break }; try? modelContext.save() } } }
        .alert("Nowe wydarzenie", isPresented: $showingCreateRootEventAlert) { TextField("Nazwa", text: $newRootEventName); Button("Anuluj", role: .cancel) { }; Button("Utwórz") { guard !newRootEventName.isEmpty else { return }; modelContext.insert(EventFolder(name: newRootEventName, generatedAutomatically: false)); try? modelContext.save() } }
        .alert("Nadpisać opisy?", isPresented: $showingOverwriteAlert) { Button("Anuluj", role: .cancel) { pendingAIPhotos.removeAll() }; Button("Nadpisz", role: .destructive) { executeAIScan(photos: pendingAIPhotos, force: true); pendingAIPhotos.removeAll() } } message: { Text("Te zdjęcia już mają opisy.") }
        .alert("Nadpisać twarze?", isPresented: $showingFaceOverwriteAlert) { Button("Anuluj", role: .cancel) { pendingFacePhotos.removeAll() }; Button("Nadpisz", role: .destructive) { executeFaceScan(photos: pendingFacePhotos, force: true); pendingFacePhotos.removeAll() } } message: { Text("Te zdjęcia zostały już wcześniej zeskanowane. Czy chcesz skasować obecne twarze i wyszukać je ponownie?") }
        .alert("Połącz", isPresented: $showingMultiMergeAlert) { TextField("Nazwa", text: $mergedEventName); Button("Anuluj", role: .cancel) { }; Button("Złącz") { guard !mergedEventName.isEmpty, !eventsToMerge.isEmpty else { return }; let nE = EventFolder(name: mergedEventName, generatedAutomatically: false); modelContext.insert(nE); for e in eventsToMerge { for p in e.photos { p.event = nE }; modelContext.delete(e) }; try? modelContext.save(); selectedNavItems = [.event(nE)] } }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            CustomTopSearchBar(activeSearchText: $activeSearchText, activeSearchDate: $activeSearchDate, activeSearchVIP: $activeSearchVIP, activeSearchColorHex: $activeSearchColorHex, activeRatings: $activeRatings)
            Divider()
            NavigationSplitView {
                List(selection: $selectedNavItems) {
                    Section("Biblioteka") {
                        Label("Wszystkie zdjęcia", systemImage: "photo.on.rectangle").tag(NavigationItem.allPhotos)
                        Label("Ulubione (VIP)", systemImage: "star.fill").foregroundColor(.yellow).tag(NavigationItem.vipPhotos)
                    }
                    Section(header: Text("Albumy (Drzewo)")) { OutlineGroup(rootFolders, children: \.optionalChildFolders) { folder in folderRowView(for: folder) } }
                    Section(header: HStack { Text("Wydarzenia"); Spacer(); Button(action: { newRootEventName = ""; showingCreateRootEventAlert = true }) { Image(systemName: "plus") }.buttonStyle(.plain) }) {
                        DisclosureGroup(isExpanded: $isManualEventsExpanded) { OutlineGroup(rootEvents.filter { !$0.generatedAutomatically }, children: \.optionalChildEvents) { event in eventRowView(for: event) } } label: { Label("Ręczne", systemImage: "person.3.sequence.fill") }
                        DisclosureGroup(isExpanded: $isScanEventsExpanded) { OutlineGroup(rootEvents.filter { $0.generatedAutomatically }, children: \.optionalChildEvents) { event in eventRowView(for: event) } } label: { Label("Skan", systemImage: "sparkles") }
                    }
                    Section("Narzędzia") { Label("Słowa kluczowe", systemImage: "tag").tag(NavigationItem.keywords) }
                    Section("Osoby") {
                        Label("Top 100", systemImage: "star.fill").tag(NavigationItem.peopleTop100)
                        Label("Inne", systemImage: "person.2.fill").tag(NavigationItem.peopleOther)
                        Label("Pozostałe", systemImage: "person.crop.circle.badge.questionmark").tag(NavigationItem.peopleUnnamed)
                    }
                    Section("Do przejrzenia") {
                        Label("Wszystkie", systemImage: "tray.full").tag(NavigationItem.reviewAll)
                        Label("Dokumenty", systemImage: "doc.text.image").tag(NavigationItem.reviewDocs)
                        Label("Duplikaty", systemImage: "doc.on.doc").tag(NavigationItem.reviewDupes)
                        Label("Inne", systemImage: "questionmark.folder").tag(NavigationItem.reviewOther)
                    }
                    Section("Kosz") { Label("Kosz (\(trashedPhotos.count))", systemImage: "trash").tag(NavigationItem.trash).foregroundColor(trashedPhotos.isEmpty ? .primary : .red) }
                }.navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
            } detail: {
                mainDetailView
            }
            .overlay(alignment: .bottomTrailing) {
                if jobState.isActive {
                    VStack(spacing: 12) {
                        if jobState.isDeletingDatabase { Text("Trwa czyszczenie bazy i dysku...").font(.headline) }
                        else { Text("Praca w tle...").font(.headline); Text(jobState.progressStatus).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).lineLimit(3); if jobState.progressTotal > 0 { Text("\(jobState.progressCount) / \(jobState.progressTotal)").font(.caption); ProgressView(value: Double(jobState.progressCount), total: Double(jobState.progressTotal)).frame(width: 250) } else { Text("Skanowanie...").font(.caption); ProgressView().frame(width: 250) }; Button(role: .cancel, action: { jobState.cancel() }) { Text("Anuluj").fontWeight(.bold) }.buttonStyle(.borderedProminent).tint(.red) }
                    }.padding(20).background(.thickMaterial).cornerRadius(16).shadow(radius: 10).padding(24)
                }
            }
        }
    }
    
    @ViewBuilder
    private var mainDetailView: some View {
        if isPeopleTab {
            if let item = selectedNavItems.first { switch item { case .peopleTop100: PeopleView(filterMode: .top100, searchKeywords: $searchKeywords, selectedNavItems: $selectedNavItems, activeSearchText: $activeSearchText); case .peopleOther: PeopleView(filterMode: .other, searchKeywords: $searchKeywords, selectedNavItems: $selectedNavItems, activeSearchText: $activeSearchText); case .peopleUnnamed: PeopleView(filterMode: .unnamed, searchKeywords: $searchKeywords, selectedNavItems: $selectedNavItems, activeSearchText: $activeSearchText); default: EmptyView() } }
        } else if selectedNavItems.count == 1, selectedNavItems.first == .keywords {
            KeywordsView(globalSelectedPhotos: .constant([]), searchKeywords: $searchKeywords)
        } else {
            WorkspaceView(
                photos: displayPhotos, jobState: jobState, selectedNavItems: $selectedNavItems,
                isSearchActive: isSearchActive, isTrashView: selectedNavItems.first == .trash, isPeopleTab: isPeopleTab,
                onDeleteDatabase: { deletePinInput = ""; showingDeletePinAlert = true },
                onImportFolder: importFolder, onScanAI: requestAIScan, onScanCleanup: scanCleanupManually, onScanFaces: requestFaceScan,
                searchKeywords: $searchKeywords, activeSearchText: $activeSearchText,
                onScanFacesToolbar: onScanFacesToolbar, onScanCleanupToolbar: onScanCleanupToolbar, onAISettingsToolbar: onAISettingsToolbar, onAIGlobalToolbar: onAIGlobalToolbar,
                showingAISettings: $showingAISettings, showingCleanupAlert: $showingCleanupAlert, showingGlobalAIAlert: $showingGlobalAIAlert, showingGlobalFacesAlert: $showingGlobalFacesAlert
            )
        }
    }
    
    private func autoEmptyTrash() { if let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) { let toDelete = trashedPhotos.filter { $0.trashDate != nil && $0.trashDate! < thirtyDaysAgo }; for photo in toDelete { for crop in photo.faceCrops { modelContext.delete(crop) }; LocalStorage.deleteThumbnail(id: photo.id); modelContext.delete(photo) }; try? modelContext.save() } }
    private func performDeepClean() {
        jobState.isDeletingDatabase = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                LocalStorage.deleteAllThumbnails()
                let c = try modelContext.fetch(FetchDescriptor<FaceCrop>())
                for x in c { modelContext.delete(x) }
                let pe = try modelContext.fetch(FetchDescriptor<Person>())
                for p in pe { modelContext.delete(p) }
                let ph = try modelContext.fetch(FetchDescriptor<PhotoAsset>())
                for p in ph { modelContext.delete(p) }
                let ev = try modelContext.fetch(FetchDescriptor<EventFolder>())
                for e in ev { modelContext.delete(e) }
                let fo = try modelContext.fetch(FetchDescriptor<VirtualFolder>())
                for f in fo { modelContext.delete(f) }
                try modelContext.save()
                selectedNavItems = [.allPhotos]
                jobState.isDeletingDatabase = false
            } catch {
                jobState.isDeletingDatabase = false
            }
        }
    }
    
    private func requestAIScan(photos: [PhotoAsset], force: Bool = false) {
        if force { let hasExisting = photos.contains { $0.isAiScanned || !$0.imageDescription.isEmpty }; if hasExisting { pendingAIPhotos = photos; showingOverwriteAlert = true; return } }
        executeAIScan(photos: photos, force: force)
    }
    
    private func executeAIScan(photos: [PhotoAsset], force: Bool) {
        let pids = photos.map { $0.persistentModelID }; jobState.isScanning = true; jobState.progressStatus = "Łączenie z AI..."; let c = modelContext.container; let s = ScannerService(); jobState.currentScanner = s; let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Analiza AI w tle")
        Task {
            await s.scanWithAI(photoIDs: pids, container: c, forceOverwrite: force) { d, t, st in Task { @MainActor in self.jobState.progressCount = d; self.jobState.progressTotal = t; self.jobState.progressStatus = st } }
            await MainActor.run {
                self.jobState.isScanning = false
                self.jobState.currentScanner = nil
                ProcessInfo.processInfo.endActivity(activity)
                self.loadPhotosFromDatabase()
            }
        }
    }
    
    private func scanCleanupManually(photos: [PhotoAsset]) {
        let pids = photos.map { $0.persistentModelID }; jobState.isScanning = true; jobState.progressStatus = "Szukanie duplikatów..."; let c = modelContext.container; let s = ScannerService(); jobState.currentScanner = s; let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Porządkowanie bazy w tle")
        Task {
            await s.scanForCleanup(photoIDs: pids, container: c) { d, t, st in Task { @MainActor in self.jobState.progressCount = d; self.jobState.progressTotal = t; self.jobState.progressStatus = st } }
            await MainActor.run {
                self.jobState.isScanning = false
                self.jobState.currentScanner = nil
                ProcessInfo.processInfo.endActivity(activity)
                self.loadPhotosFromDatabase()
            }
        }
    }
    
    private func requestFaceScan(photos: [PhotoAsset], force: Bool = false) {
        if force {
            let hasExisting = photos.contains { $0.isFaceScanned }
            if hasExisting { pendingFacePhotos = photos; showingFaceOverwriteAlert = true; return }
        }
        executeFaceScan(photos: photos, force: force)
    }
    
    private func executeFaceScan(photos: [PhotoAsset], force: Bool) {
        let pids = photos.map { $0.persistentModelID }; jobState.isScanning = true; jobState.progressStatus = "Skan twarzy..."; let c = modelContext.container; let s = ScannerService(); jobState.currentScanner = s; let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Skanowanie Twarzy w tle")
        Task {
            await s.scanFaces(photoIDs: pids, container: c, forceOverwrite: force) { d, t, st in Task { @MainActor in self.jobState.progressCount = d; self.jobState.progressTotal = t; self.jobState.progressStatus = st } }
            await MainActor.run {
                self.jobState.isScanning = false
                self.jobState.currentScanner = nil
                ProcessInfo.processInfo.endActivity(activity)
                self.loadPhotosFromDatabase()
            }
        }
    }
    
    private func importFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false;
        if p.runModal() == .OK, let u = p.url {
            jobState.isScanning = true; jobState.progressStatus = "Czytanie...";
            let c = modelContext.container; let s = ScannerService(); jobState.currentScanner = s; let activityInfo = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Import zdjęć z NAS")
            Task {
                try? await s.scanFolder(url: u, container: c) { d, t, st in Task { @MainActor in self.jobState.progressCount = d; self.jobState.progressTotal = t; self.jobState.progressStatus = st } }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    self.jobState.isScanning = false
                    self.jobState.currentScanner = nil
                    ProcessInfo.processInfo.endActivity(activityInfo)
                    self.loadPhotosFromDatabase()
                }
            }
        }
    }
    
    @ViewBuilder private func folderRowView(for folder: VirtualFolder) -> some View { HStack { Image(systemName: "folder.fill").foregroundStyle(colorFromHex(folder.colorHex)); Text(folder.name) }.tag(NavigationItem.folder(folder)).dropDestination(for: String.self) { _, _ in return false }.contextMenu { Button("Zmień nazwę...") { itemToRename = .folder(folder); renameText = folder.name; showingRenameAlert = true }; Button(role: .destructive) { modelContext.delete(folder); try? modelContext.save() } label: { Label("Usuń album", systemImage: "trash") } } }
    @ViewBuilder private func eventRowView(for event: EventFolder) -> some View { HStack { Image(systemName: "calendar").foregroundStyle(event.colorHex != nil ? colorFromHex(event.colorHex) : (event.generatedAutomatically ? .purple : .green)); Text(event.name) }.tag(NavigationItem.event(event)).draggable("event:\(event.id.uuidString)").dropDestination(for: String.self) { _, _ in return false }.contextMenu { Button("Dodaj wydarzenie...") { newRootEventName = ""; showingCreateRootEventAlert = true }; Button("Zmień nazwę...") { itemToRename = .event(event); renameText = event.name; showingRenameAlert = true }; Button(role: .destructive) { modelContext.delete(event); try? modelContext.save() } label: { Label("Usuń", systemImage: "trash") } } }
    private func colorFromHex(_ hex: String?) -> Color { guard let hex = hex, hex.hasPrefix("#") else { return .accentColor }; let start = hex.index(hex.startIndex, offsetBy: 1); if String(hex[start...]).count == 6 { let s = Scanner(string: String(hex[start...])); var n: UInt64 = 0; if s.scanHexInt64(&n) { return Color(red: Double((n & 0xff0000) >> 16) / 255, green: Double((n & 0x00ff00) >> 8) / 255, blue: Double(n & 0x0000ff) / 255) } }; return .accentColor }
}

struct CustomTopSearchBar: View {
    @Binding var activeSearchText: String; @Binding var activeSearchDate: String; @Binding var activeSearchVIP: Bool; @Binding var activeSearchColorHex: String?; @Binding var activeRatings: Set<Int>
    @State private var draftSearchText: String = ""; @State private var draftSearchDate: String = ""
    let colorFilters = [ ("Czerwony", "#FF3B30", Color.red), ("Niebieski", "#007AFF", Color.blue), ("Zielony", "#34C759", Color.green), ("Pomarańczowy", "#FF9500", Color.orange), ("Fioletowy", "#AF52DE", Color.purple) ]
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(colorFilters, id: \.1) { name, hex, color in
                    Circle().fill(color).frame(width: 14, height: 14).overlay(Circle().stroke(Color.primary.opacity(0.8), lineWidth: activeSearchColorHex == hex ? 2 : 0)).padding(2).onTapGesture { activeSearchColorHex = (activeSearchColorHex == hex) ? nil : hex }.help("Filtruj tag: \(name)")
                }
            }
            Text("|").foregroundColor(.secondary.opacity(0.4))
            Button(action: { activeSearchVIP.toggle() }) {
                HStack(spacing: 4) { Image(systemName: activeSearchVIP ? "star.fill" : "star").foregroundColor(activeSearchVIP ? .yellow : .secondary); Text("VIP").fontWeight(activeSearchVIP ? .bold : .regular).foregroundColor(activeSearchVIP ? .primary : .secondary) }
            }.buttonStyle(.plain)
            Text("|").foregroundColor(.secondary.opacity(0.4))
            HStack(spacing: 2) {
                Text("Ocena:").font(.caption).foregroundColor(.secondary)
                ForEach(1...6, id: \.self) { score in
                    Button(action: { if activeRatings.contains(score) { activeRatings.remove(score) } else { activeRatings.insert(score) } }) {
                        Text("\(score)").font(.caption2.bold()).frame(width: 18, height: 18).background(activeRatings.contains(score) ? Color.accentColor : Color.secondary.opacity(0.2)).foregroundColor(activeRatings.contains(score) ? .white : .primary).cornerRadius(4)
                    }.buttonStyle(.plain)
                }
                if !activeRatings.isEmpty { Button(action: { activeRatings.removeAll() }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.caption) }.buttonStyle(.plain).padding(.leading, 4) }
            }
            Text("|").foregroundColor(.secondary.opacity(0.4))
            HStack {
                Image(systemName: "calendar").foregroundColor(.secondary)
                TextField("Wirtualna Data", text: $draftSearchDate).textFieldStyle(.plain).frame(width: 120).onSubmit { activeSearchDate = draftSearchDate }
                if !draftSearchDate.isEmpty { Button(action: { draftSearchDate = ""; activeSearchDate = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.plain) }
            }.padding(6).background(Color(NSColor.controlBackgroundColor)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            Text("|").foregroundColor(.secondary.opacity(0.4))
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Szukaj tagów...", text: $draftSearchText).textFieldStyle(.plain).onSubmit { activeSearchText = draftSearchText }
                if !draftSearchText.isEmpty { Button(action: { draftSearchText = ""; activeSearchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.plain) }
            }.padding(6).background(Color(NSColor.controlBackgroundColor)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            Spacer()
        }.padding(.horizontal).padding(.vertical, 10).background(Color(NSColor.windowBackgroundColor)).onChange(of: activeSearchText) { _, newValue in draftSearchText = newValue }
    }
}

// ==========================================
// OBSZAR ROBOCZY (WORKSPACEVIEW)
// ==========================================

struct WorkspaceView: View {
    @State private var hasAnyPhoto: Bool = true
    let photos: [PhotoAsset]
    @Bindable var jobState: JobState
    @Binding var selectedNavItems: Set<NavigationItem>
    var isSearchActive: Bool
    var isTrashView: Bool
    var isPeopleTab: Bool
    var onDeleteDatabase: () -> Void
    var onImportFolder: () -> Void
    var onScanAI: ([PhotoAsset], Bool) -> Void
    var onScanCleanup: ([PhotoAsset]) -> Void
    var onScanFaces: ([PhotoAsset], Bool) -> Void
    @Binding var searchKeywords: Set<String>
    @Binding var activeSearchText: String
    
    var onScanFacesToolbar: () -> Void
    var onScanCleanupToolbar: () -> Void
    var onAISettingsToolbar: () -> Void
    var onAIGlobalToolbar: () -> Void
    
    @Binding var showingAISettings: Bool
    @Binding var showingCleanupAlert: Bool
    @Binding var showingGlobalAIAlert: Bool
    @Binding var showingGlobalFacesAlert: Bool
    
    @Environment(\.modelContext) private var modelContext
    @State private var selectedPhotos: Set<PhotoAsset> = []
    @State private var isInspectorPresented = true
    @State private var showingNewEventAlert = false
    @State private var newEventName = ""
    
    // 🚨 REGISTRACJA STANÓW DLA KOPII ZAPASOWEJ (Poprawna obsługa Backupu!)
    @State private var showingBackupSheet = false
    @State private var backupManager = BackupManager.shared
    
    var body: some View {
        ZStack {
            Button("") { guard !selectedPhotos.isEmpty else { return }; for p in selectedPhotos { p.isVIP.toggle() }; try? modelContext.save() }
                .keyboardShortcut(.space, modifiers: []).frame(width: 0, height: 0).opacity(0)
            VStack(spacing: 0) {
                
                // 🚨 BANER INFORMACYJNY KOPII ZAPASOWEJ
                if backupManager.isBackupRequired && hasAnyPhoto {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Twoja baza danych nie była zabezpieczana od ponad 7 dni. Zrób kopię zapasową dla swoich zdjęć.")
                            .font(.subheadline)
                        Spacer()
                        Button("Utwórz Backup") {
                            showingBackupSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
                    Divider()
                }
                
                if isSearchActive { VStack(alignment: .leading) { Text("Wyniki wyszukiwania (\(photos.count) zdjęć)").font(.title3).bold().padding(.horizontal).padding(.top, 16); Text("Wyniki pokazują tylko elementy poza koszem").font(.caption).foregroundStyle(.secondary).padding(.leading) } }
                if isTrashView && !photos.isEmpty { HStack { Text("Pliki w koszu zostaną automatycznie usunięte po 30 dniach.").font(.caption).foregroundColor(.secondary); Spacer(); Button(role: .destructive, action: { permanentlyDelete(Array(photos)) }) { Label("Opróżnij kosz", systemImage: "trash.slash.fill") }.buttonStyle(.bordered) }.padding() }
                PhotoGridView(photos: photos, selectedPhotos: $selectedPhotos, onCreateEvent: { newEventName = ""; showingNewEventAlert = true }, onScanFaces: onScanFaces, onScanAI: onScanAI, moveToTrash: movePhotosToTrash, restoreFromTrash: restorePhotos, deletePermanently: permanentlyDelete)
            }
            .inspector(isPresented: Binding(get: { isInspectorPresented && !isPeopleTab }, set: { if !isPeopleTab { isInspectorPresented = $0 } })) {
                 if selectedPhotos.count == 1, let photo = selectedPhotos.first {
                    PhotoInspectorView(photo: photo, searchKeywords: $searchKeywords, selectedNavItems: $selectedNavItems, searchText: $activeSearchText, onScanAI: onScanAI, onExport: { exportPhotos([$0]) }).inspectorColumnWidth(min: 250, ideal: 300, max: 400)
                } else if selectedPhotos.count > 1 { MultiplePhotosInspectorView(photos: Array(selectedPhotos), onExport: exportPhotos).inspectorColumnWidth(min: 250, ideal: 300, max: 400)
                } else { Text("Brak zaznaczenia").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).inspectorColumnWidth(min: 250, ideal: 300, max: 400) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // 🚨 PRZYCISK KOPII ZAPASOWEJ W TOOLBARZE
                    Button(action: { showingBackupSheet = true }) { Label("Kopia zapasowa", systemImage: "archivebox") }.disabled(jobState.isActive).help("Wykonaj kopię zapasową całego systemu")
                    
                    Button(action: onAISettingsToolbar) { Label("Ustawienia AI", systemImage: "cpu") }.disabled(jobState.isActive).help("Panel klucza API")
                    Button(action: onImportFolder) { Label("Importuj folder", systemImage: "folder.badge.plus") }.disabled(jobState.isActive).help("Importuj folder")
                    Button(action: onAIGlobalToolbar) { Label("Opisz wszystkie (AI)", systemImage: "wand.and.stars.inverse") }.disabled(jobState.isActive).help("Opisy, oceny i tagi AI")
                    Button(action: onScanCleanupToolbar) { Label("Skanuj porządkowo", systemImage: "eraser") }.disabled(jobState.isActive).help("Skanuj duplikaty i dokumenty")
                    Button(action: onScanFacesToolbar) { Label("Skanuj brakujące twarze", systemImage: "person.crop.circle.badge.plus") }.disabled(jobState.isActive).help("Znajdź twarze")
                    Button(role: .destructive, action: { onDeleteDatabase() }) { Label("Usuń całą bazę", systemImage: "trash.circle.fill").foregroundStyle(.red) }.help("USUŃ CAŁĄ BAZĘ")
                }
                ToolbarItem(placement: .navigation) { Button(action: { isInspectorPresented.toggle() }) { Label("Inspektor", systemImage: "sidebar.right") }.disabled(isPeopleTab).help("Panel boczny") }
            }
            .sheet(isPresented: $showingAISettings) { AISettingsView() }
            
            // 🚨 PODPIĘCIE WIDOKU KOPII ZAPASOWEJ
            .sheet(isPresented: $showingBackupSheet) { BackupSheetView() }
            
            .alert("Nowe wydarzenie", isPresented: $showingNewEventAlert) { TextField("Nazwa wydarzenia", text: $newEventName); Button("Anuluj", role: .cancel) { }; Button("Utwórz i przenieś") { guard !newEventName.isEmpty, !selectedPhotos.isEmpty else { return }; let newEvent = EventFolder(name: newEventName, generatedAutomatically: false); modelContext.insert(newEvent); for photo in selectedPhotos { photo.event = newEvent }; try? modelContext.save(); selectedNavItems = [.event(newEvent)]; selectedPhotos.removeAll() } }
            .alert("Kreator Opisów AI", isPresented: $showingGlobalAIAlert) {
                Button("Tylko brakujące") { let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isAiScanned == false && $0.isTrash == false }); if let toScan = try? modelContext.fetch(desc), !toScan.isEmpty { onScanAI(toScan, false) } else { jobState.progressStatus = "✅ Brak nowych zdjęć do opisu!"; jobState.isScanning = true; Task { try? await Task.sleep(nanoseconds: 3_000_000_000); jobState.isScanning = false } } }
                Button("Skanuj WSZYSTKO", role: .destructive) { let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false }); if let toScan = try? modelContext.fetch(desc), !toScan.isEmpty { onScanAI(toScan, true) } }
                Button("Anuluj", role: .cancel) { }
            } message: { Text("Wybierz tryb pracy sztucznej inteligencji. Pomiń zdjęcia, które już wczytały opisy z plików .xmp.") }
            .alert("Kreator Skanowania Twarzy", isPresented: $showingGlobalFacesAlert) {
                Button("Tylko brakujące") { let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isFaceScanned == false && $0.isTrash == false }); if let toScan = try? modelContext.fetch(desc), !toScan.isEmpty { onScanFaces(toScan, false) } else { jobState.progressStatus = "✅ Wszystkie zdjęcia już przeskanowane!"; jobState.isScanning = true; Task { try? await Task.sleep(nanoseconds: 3_000_000_000); jobState.isScanning = false } } }
                Button("Napraw pominięte (Brak twarzy)") {
                    jobState.progressStatus = "Wyszukiwanie pominiętych..."
                    jobState.isScanning = true
                    Task { @MainActor in
                        let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isFaceScanned == true && $0.isTrash == false })
                        let allScanned = (try? modelContext.fetch(desc)) ?? []
                        let toScan = allScanned.filter { $0.faceCrops.isEmpty }
                        jobState.isScanning = false
                        if !toScan.isEmpty { onScanFaces(toScan, true) }
                        else { jobState.progressStatus = "✅ Brak pominiętych zdjęć!"; jobState.isScanning = true; try? await Task.sleep(nanoseconds: 3_000_000_000); jobState.isScanning = false }
                    }
                }
                Button("Skanuj WSZYSTKO (Nadpisz)", role: .destructive) { let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false }); if let toScan = try? modelContext.fetch(desc), !toScan.isEmpty { onScanFaces(toScan, true) } }
                Button("Anuluj", role: .cancel) { }
            } message: { Text("Wybierz tryb pracy skanera. Możesz skanować nowe, nadpisać wszystko, albo naprawić zdjęcia omyłkowo pominięte przez filtry.") }
            .alert("Kreator Porządkowania", isPresented: $showingCleanupAlert) {
                Button("Tylko nieskanowane") { let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isReviewScanned == false && $0.isTrash == false }); if let toScan = try? modelContext.fetch(desc), !toScan.isEmpty { onScanCleanup(toScan) } else { jobState.progressStatus = "✅ Baza jest w pełni uporządkowana!"; jobState.isScanning = true; Task { try? await Task.sleep(nanoseconds: 3_000_000_000); jobState.isScanning = false } } }
                Button("Wymuś pełny skan", role: .destructive) { let desc = FetchDescriptor<PhotoAsset>(predicate: #Predicate<PhotoAsset> { $0.isTrash == false }); if let toScan = try? modelContext.fetch(desc), !toScan.isEmpty { onScanCleanup(toScan) } }
                Button("Anuluj", role: .cancel) { }
            } message: { Text("Wybierz tryb porządkowania bazy.") }
            .task { checkDatabaseState() }
            .onChange(of: photos) { _, _ in checkDatabaseState() }
        }
    }
    private func checkDatabaseState() {
        var fetchDesc = FetchDescriptor<PhotoAsset>()
        fetchDesc.fetchLimit = 1
        if let check = try? modelContext.fetch(fetchDesc) {
            hasAnyPhoto = !check.isEmpty
        }
    }
    private func movePhotosToTrash(_ photos: [PhotoAsset]) { let now = Date(); for photo in photos { photo.isTrash = true; photo.trashDate = now; photo.reviewCategory = nil; photo.folder = nil; photo.event = nil; photo.people.removeAll(); for crop in photo.faceCrops { if let person = crop.person { person.faceCount -= 1 }; modelContext.delete(crop) }; photo.faceCrops.removeAll() }; try? modelContext.save(); selectedPhotos.removeAll() }
    private func restorePhotos(_ photos: [PhotoAsset]) { for photo in photos { photo.isTrash = false; photo.trashDate = nil }; try? modelContext.save(); selectedPhotos.removeAll() }
    private func permanentlyDelete(_ photos: [PhotoAsset]) { for photo in photos { LocalStorage.deleteThumbnail(id: photo.id); for crop in photo.faceCrops { modelContext.delete(crop) }; modelContext.delete(photo) }; try? modelContext.save(); selectedPhotos.removeAll() }
    private func exportPhotos(_ photos: [PhotoAsset]) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; if panel.runModal() == .OK, let destURL = panel.url { Task { for photo in photos { let sourceURL = URL(fileURLWithPath: photo.originalPath); var destFileURL = destURL.appendingPathComponent(photo.fileName); if FileManager.default.fileExists(atPath: destFileURL.path) { let uniqueString = UUID().uuidString.prefix(5); let newName = "\(uniqueString)_\(photo.fileName)"; destFileURL = destURL.appendingPathComponent(newName) }; do { try FileManager.default.copyItem(at: sourceURL, to: destFileURL) } catch { print("Błąd eksportu \(photo.fileName): \(error.localizedDescription)") } }; NSSound(named: "Glass")?.play() } } }
}

// ==========================================
// KOMÓRKI, SIATKI I INSPEKTORY
// ==========================================

struct PhotoCellView: View {
    let photo: PhotoAsset; let isSelected: Bool; @State private var loadedImage: NSImage?
    var body: some View { VStack { ZStack(alignment: .topTrailing) { if let nsImage = loadedImage { Image(nsImage: nsImage).resizable().scaledToFill().frame(width: 150, height: 150).clipped().cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 4 : 0)).opacity(photo.isTrash ? 0.5 : 1.0) } else { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 150, height: 150).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 4 : 0)).task(id: photo.id) { await loadThumbnail() } }; if photo.isVIP { Image(systemName: "star.fill").foregroundColor(.yellow).shadow(radius: 2).padding(6) }; if photo.reviewCategory != nil && !photo.isTrash { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).shadow(radius: 2).padding(6) } }; Text(photo.fileName).font(.caption).lineLimit(1).truncationMode(.middle) } }
    private func loadThumbnail() async { if loadedImage != nil { return }; let cacheKey = NSString(string: photo.id.uuidString); if let cachedImage = ThumbnailCache.shared.object(forKey: cacheKey) { await MainActor.run { self.loadedImage = cachedImage }; return }; let photoID = photo.id; if let img = await Task.detached(priority: .userInitiated, operation: { LocalStorage.loadThumbnail(id: photoID) }).value { ThumbnailCache.shared.setObject(img, forKey: cacheKey); await MainActor.run { self.loadedImage = img } } }
}

struct PhotoGridView: View {
    @Environment(\.modelContext) private var modelContext; let photos: [PhotoAsset]; @Binding var selectedPhotos: Set<PhotoAsset>
    var onCreateEvent: () -> Void; var onScanFaces: ([PhotoAsset], Bool) -> Void; var onScanAI: ([PhotoAsset], Bool) -> Void
    var moveToTrash: (([PhotoAsset]) -> Void); var restoreFromTrash: (([PhotoAsset]) -> Void); var deletePermanently: (([PhotoAsset]) -> Void)
    let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]; @State private var dragStart: CGPoint? = nil; @State private var dragCurrent: CGPoint? = nil; @State private var gridManager = GridManager(); @State private var localDragSelection: Set<PhotoAsset>? = nil; @State private var preDragSelection: Set<PhotoAsset> = []; var dragRect: CGRect { guard let s = dragStart, let c = dragCurrent else { return .zero }; return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y)) }; @State private var previewPhoto: PhotoAsset? = nil
    var body: some View { ZStack { ScrollView { LazyVGrid(columns: columns, spacing: 16) { ForEach(photos) { photo in let isSelected = localDragSelection?.contains(photo) ?? selectedPhotos.contains(photo); PhotoCellView(photo: photo, isSelected: isSelected).background(GeometryReader { geo in Color.clear.onChange(of: geo.frame(in: .named("GridSpace")), initial: true) { _, newFrame in gridManager.cellData[photo.id] = (photo, newFrame) } }).onTapGesture { if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { if selectedPhotos.contains(photo) { selectedPhotos.remove(photo) } else { selectedPhotos.insert(photo) } } else { selectedPhotos = [photo] } }.simultaneousGesture(TapGesture(count: 2).onEnded { previewPhoto = photo }).draggable("photo:\(photo.id.uuidString)").contextMenu { let toProcess = isSelected ? Array(selectedPhotos) : [photo]; if photo.isTrash { Button(action: { restoreFromTrash(toProcess) }) { Label("Przywróć z kosza", systemImage: "arrow.uturn.backward") }; Button(role: .destructive, action: { deletePermanently(toProcess) }) { Label("Usuń trwale", systemImage: "xmark.bin") } } else { if photo.reviewCategory != nil { Button(action: { for p in toProcess { p.reviewCategory = nil }; try? modelContext.save() }) { Label("Oznacz jako sprawdzone (Czyste)", systemImage: "checkmark.circle") }; Divider() }; Button(action: { onScanAI(toProcess, true) }) { Label(isSelected ? "Opisz zaznaczone (AI)" : "Opisz zdjęcie (AI)", systemImage: "wand.and.stars") }; Button(action: { onScanFaces(toProcess, true) }) { Label(isSelected ? "Skanuj twarze (zaznaczone)" : "Skanuj twarze", systemImage: "person.crop.circle.badge.plus") }; Divider(); Button(photo.isVIP ? "Usuń z VIP" : "Oznacz jako VIP") { if isSelected { for p in selectedPhotos { p.isVIP.toggle() } } else { photo.isVIP.toggle() }; try? modelContext.save() }; Divider(); Button(action: { if !isSelected { selectedPhotos = [photo] }; onCreateEvent() }) { Label("Utwórz wydarzenie", systemImage: "calendar.badge.plus") }; Divider(); Button(role: .destructive, action: { moveToTrash(toProcess) }) { Label("Przenieś do kosza", systemImage: "trash") } } } } }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).onTapGesture { selectedPhotos.removeAll() } }.simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("GridSpace")).onChanged { val in if dragStart == nil { dragStart = val.startLocation; preDragSelection = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) ? selectedPhotos : []; localDragSelection = preDragSelection }; dragCurrent = val.location; var newSelection = preDragSelection; let currentRect = dragRect; for (_, data) in gridManager.cellData { if currentRect.intersects(data.frame) { newSelection.insert(data.photo) } }; if localDragSelection != newSelection { localDragSelection = newSelection } }.onEnded { _ in if let finalSelection = localDragSelection { selectedPhotos = finalSelection }; dragStart = nil; dragCurrent = nil; localDragSelection = nil }); if dragStart != nil { Rectangle().fill(Color.accentColor.opacity(0.2)).stroke(Color.accentColor, lineWidth: 1).frame(width: dragRect.width, height: dragRect.height).position(x: dragRect.midX, y: dragRect.midY).allowsHitTesting(false) }; Button("") { selectedPhotos = Set(photos) }.keyboardShortcut("a", modifiers: .command).opacity(0).allowsHitTesting(false) }.coordinateSpace(name: "GridSpace").sheet(item: $previewPhoto) { photo in QuickPhotoPreview(photo: photo) } }
}

struct PhotoInspectorView: View {
    @Environment(\.modelContext) private var modelContext; @Bindable var photo: PhotoAsset; @Binding var searchKeywords: Set<String>; @Binding var selectedNavItems: Set<NavigationItem>; @Binding var searchText: String; var onScanAI: ([PhotoAsset], Bool) -> Void; var onExport: (PhotoAsset) -> Void; @State private var metadata: PhotoMetadata?; @State private var localSelectedKeywords: Set<String> = []; @State private var coordinate: CLLocationCoordinate2D?; @State private var isXMPExpanded: Bool = false
    var body: some View { Form { Section("Plik") { LabeledContent("Nazwa", value: photo.fileName); Text(photo.originalPath).font(.caption2).foregroundStyle(.secondary); Button(action: { onExport(photo) }) { Label("Eksportuj na dysk...", systemImage: "square.and.arrow.up") } }; Section("Inteligentna Analiza") { Button(action: { onScanAI([photo], true) }) { HStack { Image(systemName: "wand.and.stars"); Text(photo.imageDescription.isEmpty ? "Wygeneruj opis i tagi (AI)" : "Przeanalizuj ponownie (AI)") } }.buttonStyle(.plain).foregroundColor(.accentColor) }; if photo.isAiScanned || !photo.imageDescription.isEmpty || !photo.keywords.isEmpty || !photo.people.isEmpty { Section("Dane w programie") { if photo.isAiScanned { LabeledContent("Ocena AI", value: "\(photo.rating) / 6") }; let allTags = Array(Set(photo.keywords + photo.people.map { $0.name })).sorted(); if !allTags.isEmpty { FlowLayout(spacing: 6) { ForEach(allTags, id: \.self) { kw in Button(action: { searchText = ""; searchKeywords = [kw]; selectedNavItems = [.keywords] }) { Text(kw).font(.caption2).padding(.horizontal, 8).padding(.vertical, 4).background(Color.green).foregroundColor(.white).cornerRadius(8) }.buttonStyle(.plain) } }.padding(.vertical, 4) }; if !photo.imageDescription.isEmpty { Text(photo.imageDescription).font(.callout) } } }; Section("Lokalizacja w bibliotece") { HStack { Image(systemName: "calendar").foregroundColor(photo.event?.colorHex != nil ? colorFromHex(photo.event?.colorHex) : .accentColor); LabeledContent("Wydarzenie", value: photo.event?.name ?? "Brak") }; HStack { Image(systemName: "folder.fill").foregroundColor(photo.folder?.colorHex != nil ? colorFromHex(photo.folder?.colorHex) : .accentColor); LabeledContent("Album", value: photo.folder?.name ?? "Brak") } }; Section("Status VIP") { Toggle(isOn: $photo.isVIP) { Label("Oznacz jako VIP", systemImage: photo.isVIP ? "star.fill" : "star").foregroundColor(photo.isVIP ? .yellow : .primary) } }; if let coord = coordinate { Section("Geolokalizacja (GPS)") { Map(initialPosition: .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))) { Marker(photo.fileName, coordinate: coord) }.frame(height: 200).cornerRadius(8).padding(.vertical, 4) } }; if let meta = metadata { Section { DisclosureGroup(isExpanded: $isXMPExpanded) { if !meta.xmpKeywords.isEmpty { FlowLayout(spacing: 6) { ForEach(meta.xmpKeywords, id: \.self) { kw in Button(action: { if localSelectedKeywords.contains(kw) { localSelectedKeywords.remove(kw) } else { localSelectedKeywords.insert(kw) } }) { Text(kw).font(.caption2).padding(.horizontal, 8).padding(.vertical, 4).background(localSelectedKeywords.contains(kw) ? Color.accentColor : Color.secondary.opacity(0.2)).foregroundColor(localSelectedKeywords.contains(kw) ? .white : .primary).cornerRadius(8) }.buttonStyle(.plain) } }.padding(.vertical, 4); if !localSelectedKeywords.isEmpty { Button(action: { searchText = ""; searchKeywords = localSelectedKeywords; selectedNavItems = [.keywords] }) { HStack { Image(systemName: "magnifyingglass"); Text("Szukaj powiązanych (\(localSelectedKeywords.count))") }.font(.callout.bold()).foregroundColor(.accentColor) }.buttonStyle(.plain).padding(.top, 4) } } else { Text("Brak pliku XMP / tagów").foregroundStyle(.secondary) }; if let desc = meta.xmpDescription { Divider(); Text(desc).font(.callout) } } label: { Text("Odczyt z pliku na dysku (.xmp)").font(.headline) } } } else { ProgressView("Wczytywanie XMP...") }; Section("Ustawienia systemowe") { TextField("Wirtualna Data", text: Binding(get: { photo.virtualDateString ?? "" }, set: { photo.virtualDateString = $0.isEmpty ? nil : $0 })) } }.formStyle(.grouped).navigationTitle("Szczegóły Zdjęcia").onChange(of: photo.id) { _, _ in localSelectedKeywords.removeAll(); coordinate = nil; isXMPExpanded = false }.task(id: photo.id) { loadData() }.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AIPhotoUpdated"))) { notification in if let updatedId = notification.object as? UUID, updatedId == photo.id { loadData() } } }
    private func loadData() { let path = photo.originalPath; Task { self.metadata = await Task.detached { MetadataReader.readMetadata(from: path) }.value; self.coordinate = await Task.detached { self.extractGPS(from: path) }.value } }
    nonisolated private func extractGPS(from path: String) -> CLLocationCoordinate2D? { let url = URL(fileURLWithPath: path); guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any], let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any], let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double, let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String, let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double, let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String else { return nil }; return CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat, longitude: lonRef == "W" ? -lon : lon) }
    private func colorFromHex(_ hex: String?) -> Color { guard let hex = hex, hex.hasPrefix("#") else { return .accentColor }; let start = hex.index(hex.startIndex, offsetBy: 1); if String(hex[start...]).count == 6 { let s = Scanner(string: String(hex[start...])); var n: UInt64 = 0; if s.scanHexInt64(&n) { return Color(red: Double((n & 0xff0000) >> 16) / 255, green: Double((n & 0x00ff00) >> 8) / 255, blue: Double(n & 0x0000ff) / 255) } }; return .accentColor }
}

struct FlowLayout: Layout {
    var spacing: CGFloat; func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { return FlowResult(in: proposal.width ?? 100, subviews: subviews, spacing: spacing).size }; func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) { let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing); for (index, subview) in subviews.enumerated() { subview.place(at: CGPoint(x: bounds.minX + result.frames[index].origin.x, y: bounds.minY + result.frames[index].origin.y), proposal: .unspecified) } }; struct FlowResult { var size: CGSize = .zero; var frames: [CGRect] = []; init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) { var cX: CGFloat = 0; var cY: CGFloat = 0; var lH: CGFloat = 0; for subview in subviews { let size = subview.sizeThatFits(.unspecified); if cX + size.width > maxWidth && cX > 0 { cX = 0; cY += lH + spacing; lH = 0 }; frames.append(CGRect(x: cX, y: cY, width: size.width, height: size.height)); lH = max(lH, size.height); cX += size.width + spacing }; self.size = CGSize(width: maxWidth, height: cY + lH) } }
}

// ==========================================
// STRUKTURY POMOCNICZE
// ==========================================

@Observable
class GridManager {
    var cellData: [UUID: (photo: PhotoAsset, frame: CGRect)] = [:]
}

// ==========================================
// BRAKUJĄCE WIDOKI POMOCNICZE
// ==========================================

struct MultiplePhotosInspectorView: View {
    let photos: [PhotoAsset]
    var onExport: ([PhotoAsset]) -> Void
    
    var body: some View {
        Form {
            Section("Zaznaczenie") {
                Text("Wybrano zdjęć: \(photos.count)")
                    .font(.headline)
            }
            
            Section("Akcje") {
                Button(action: { onExport(photos) }) {
                    Label("Eksportuj zaznaczone...", systemImage: "square.and.arrow.up")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Wiele zdjęć")
    }
}

struct QuickPhotoPreview: View {
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoAsset
    @State private var loadedImage: NSImage?
    
    var body: some View {
        VStack {
            HStack {
                Text(photo.fileName).font(.headline)
                Spacer()
                Button("Zamknij") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            
            if let img = loadedImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(minWidth: 500, minHeight: 400)
            } else {
                ProgressView("Ładowanie podglądu...")
                    .frame(minWidth: 500, minHeight: 400)
                    .task {
                        if let img = NSImage(contentsOfFile: photo.originalPath) {
                            loadedImage = img
                        } else if let thumbData = LocalStorage.loadThumbnailData(id: photo.id), let tImg = NSImage(data: thumbData) {
                            loadedImage = tImg
                        }
                    }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }
}
