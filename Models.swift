import Foundation
import SwiftData
import AppKit
import CryptoKit

extension UUID {
    static func deterministic(from string: String) -> UUID {
        let data = Data(string.utf8)
        let hash = Insecure.MD5.hash(data: data)
        var bytes = [UInt8](repeating: 0, count: 16)
        hash.withUnsafeBytes { buffer in
            for i in 0..<16 {
                bytes[i] = buffer[i]
            }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

@Model
final class PhotoAsset {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var originalPath: String
    
    var keywords: [String]
    var imageDescription: String
    var virtualDateString: String?
    var isVIP: Bool = false
    
    var rating: Int = 0         // Ocena AI (0-6)
    var colorLabel: String? = nil // Etykieta koloru (#hex), np. "#FF3B30"
    
    var isFaceScanned: Bool = false
    var isAiScanned: Bool = false
    
    var isTrash: Bool = false
    var trashDate: Date? = nil
    var reviewCategory: String? = nil
    var isReviewScanned: Bool = false
    
    var folder: VirtualFolder?
    var event: EventFolder?
    
    @Relationship(inverse: \Person.photos) var people: [Person] = []
    @Relationship(deleteRule: .cascade, inverse: \FaceCrop.photo) var faceCrops: [FaceCrop] = []
    
    init(fileName: String, originalPath: String) {
        self.id = UUID.deterministic(from: originalPath)
        self.fileName = fileName
        self.originalPath = originalPath
        self.keywords = []
        self.imageDescription = ""
    }
}

@Model
final class VirtualFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String?
    var keywords: [String]
    var folderDescription: String
    var virtualDateString: String?
    var parentFolder: VirtualFolder?
    @Relationship(deleteRule: .cascade, inverse: \VirtualFolder.parentFolder) var childFolders: [VirtualFolder] = []
    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.folder) var photos: [PhotoAsset] = []
    init(name: String) { self.id = UUID(); self.name = name; self.keywords = []; self.folderDescription = "" }
    
    // NOWE: Funkcja rekursywna pobierająca zdjęcia z podfolderów
    func photosRecursively(limit: Int = 0) -> [PhotoAsset] {
        var allPhotos = self.photos
        if limit > 0 && allPhotos.count >= limit { return Array(allPhotos.prefix(limit)) }
        for child in childFolders {
            let needed = limit > 0 ? limit - allPhotos.count : 0
            if limit > 0 && needed <= 0 { break }
            allPhotos.append(contentsOf: child.photosRecursively(limit: needed))
        }
        if limit > 0 && allPhotos.count > limit { return Array(allPhotos.prefix(limit)) }
        return allPhotos
    }
    
    var optionalChildFolders: [VirtualFolder]? {
        return childFolders.isEmpty ? nil : childFolders
    }
}

@Model
final class EventFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String?
    var keywords: [String]
    var eventDescription: String
    var virtualDateString: String?
    var generatedAutomatically: Bool
    var parentEvent: EventFolder?
    @Relationship(deleteRule: .cascade, inverse: \EventFolder.parentEvent) var childEvents: [EventFolder] = []
    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.event) var photos: [PhotoAsset] = []
    init(name: String, generatedAutomatically: Bool = true) { self.id = UUID(); self.name = name; self.keywords = []; self.eventDescription = ""; self.generatedAutomatically = generatedAutomatically }
    
    // NOWE: Funkcja rekursywna pobierająca zdjęcia z pod-wydarzeń
    func photosRecursively(limit: Int = 0) -> [PhotoAsset] {
        var allPhotos = self.photos
        if limit > 0 && allPhotos.count >= limit { return Array(allPhotos.prefix(limit)) }
        for child in childEvents {
            let needed = limit > 0 ? limit - allPhotos.count : 0
            if limit > 0 && needed <= 0 { break }
            allPhotos.append(contentsOf: child.photosRecursively(limit: needed))
        }
        if limit > 0 && allPhotos.count > limit { return Array(allPhotos.prefix(limit)) }
        return allPhotos
    }
    
    var optionalChildEvents: [EventFolder]? {
        return childEvents.isEmpty ? nil : childEvents
    }
}

@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var name: String
    var firstName: String = ""
    var lastName: String = ""
    var birthDateString: String = ""
    var relationship: String = ""
    var personDescription: String = ""
    var isTop100: Bool = false
    var faceCount: Int = 0
    
    @Relationship(deleteRule: .cascade, inverse: \FaceCrop.person)
    var faceCrops: [FaceCrop] = []
    
    var photos: [PhotoAsset] = []
    
    init(name: String) {
        self.id = UUID()
        self.name = name
    }
}

@Model
final class FaceCrop {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var cropData: Data
    var featurePrintData: Data?
    var person: Person?
    var photo: PhotoAsset?
    var isConfirmed: Bool = false
    var isIgnored: Bool = false
    
    init(cropData: Data, featurePrintData: Data?) {
        self.id = UUID()
        self.cropData = cropData
        self.featurePrintData = featurePrintData
    }
}

// BEZPIECZNY DLA SWIFT 6 MENEDŻER DYSKU
public struct LocalStorage: Sendable {
    public static var thumbnailsDir: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appDir = paths[0].appendingPathComponent("AIPhotoManager/Thumbnails")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }
    
    public static func saveThumbnail(id: UUID, image: NSImage) {
        guard let data = image.tiffRepresentation else { return }
        let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        try? data.write(to: url)
    }
    
    public static func saveThumbnail(data: Data, id: UUID) {
        let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        try? data.write(to: url)
    }
    
    public static func loadThumbnail(id: UUID) -> NSImage? {
        let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        if let data = try? Data(contentsOf: url) { return NSImage(data: data) }
        return nil
    }
    
    public static func loadThumbnailData(id: UUID) -> Data? {
        let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        return try? Data(contentsOf: url)
    }
    
    public static func deleteThumbnail(id: UUID) {
        let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        try? FileManager.default.removeItem(at: url)
    }
    
    public static func deleteAllThumbnails() {
        try? FileManager.default.removeItem(at: thumbnailsDir)
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
    }
}
