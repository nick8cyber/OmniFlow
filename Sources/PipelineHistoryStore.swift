import CoreData
import Foundation

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var intent: String?
    @NSManaged var selectedText: String?
    @NSManaged var capturedSelection: String?
    @NSManaged var timestamp: Date?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingPrompt: String?
    @NSManaged var systemPrompt: String?
    @NSManaged var contextSummary: String?
    @NSManaged var contextSystemPrompt: String?
    @NSManaged var contextPrompt: String?
    @NSManaged var contextScreenshotDataURL: String?
    @NSManaged var contextScreenshotStatus: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var debugStatus: String?
    @NSManaged var customVocabulary: String?
    @NSManaged var audioFileName: String?
    @NSManaged var contextAppName: String?
    @NSManaged var contextBundleIdentifier: String?
    @NSManaged var contextWindowTitle: String?
}

final class PipelineHistoryStore {
    private let container: NSPersistentContainer
    private var isStoreLoaded = false

    init() {
        let container = NSPersistentContainer(name: "PipelineHistory",
                                              managedObjectModel: Self.makeModel())
        if let directory = Self.dataDirectory() {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            let description = NSPersistentStoreDescription(
                url: directory.appendingPathComponent("PipelineHistory.sqlite"))
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        } else {
            container.persistentStoreDescriptions = [NSPersistentStoreDescription()]
        }

        if Self.loadPersistentStoresSynchronously(container) == nil {
            isStoreLoaded = true
        } else {
            let storePath = container.persistentStoreDescriptions.first?.url?.path ?? "unknown"
            print("[PipelineHistoryStore] Failed to load persistent store at \(storePath). Attempting recovery.")
            Self.destroySQLiteStoreFiles(at: storePath)
            // The history rows that owned the recordings are gone with the
            // store — remove the WAV files too instead of orphaning them.
            Self.removeOrphanedAudioFiles()
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
            if let directory = Self.dataDirectory() {
                let description = NSPersistentStoreDescription(
                    url: directory.appendingPathComponent("PipelineHistory.sqlite"))
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                container.persistentStoreDescriptions = [description]
            }
            if Self.loadPersistentStoresSynchronously(container) == nil {
                isStoreLoaded = true
            } else {
                print("[PipelineHistoryStore] Failed to recover persistent store. Falling back to in-memory history.")
                for store in coordinator.persistentStores {
                    try? coordinator.remove(store)
                }
                let memoryDescription = NSPersistentStoreDescription()
                memoryDescription.type = NSInMemoryStoreType
                container.persistentStoreDescriptions = [memoryDescription]
                isStoreLoaded = Self.loadPersistentStoresSynchronously(container) == nil
            }
        }

        self.container = container
    }

    // MARK: - Public API

    func loadAllHistory() -> [PipelineHistoryItem] {
        guard isStoreLoaded else { return [] }
        var items: [PipelineHistoryItem] = []
        container.viewContext.performAndWait {
            let request = NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            let entries = (try? container.viewContext.fetch(request)) ?? []
            items = entries.compactMap(Self.makeHistoryItem)
        }
        return items
    }

    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [String] {
        guard isStoreLoaded else { return [] }
        var evictedAudioFileNames: [String] = []
        try container.viewContext.performAndWait {
            let entry = NSEntityDescription.insertNewObject(
                forEntityName: "PipelineHistoryEntry",
                into: container.viewContext) as! PipelineHistoryEntry
            Self.apply(item, to: entry)
            evictedAudioFileNames = try trimWithoutSave(to: maxCount)
            try saveContext()
        }
        return evictedAudioFileNames
    }

    func update(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }
        try container.viewContext.performAndWait {
            let request = NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
            request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
            guard let entry = try container.viewContext.fetch(request).first else { return }
            entry.intent = item.intent.rawValue
            entry.selectedText = item.selectedText
            entry.capturedSelection = item.capturedSelection
            entry.rawTranscript = item.rawTranscript
            entry.postProcessedTranscript = item.postProcessedTranscript
            entry.postProcessingPrompt = item.postProcessingPrompt
            entry.systemPrompt = item.systemPrompt
            entry.contextSystemPrompt = item.contextSystemPrompt
            entry.postProcessingStatus = item.postProcessingStatus
            entry.debugStatus = item.debugStatus
            entry.contextAppName = item.contextAppName
            entry.contextBundleIdentifier = item.contextBundleIdentifier
            entry.contextWindowTitle = item.contextWindowTitle
            try saveContext()
        }
    }

    @discardableResult
    func delete(id: UUID) throws -> String? {
        guard isStoreLoaded else { return nil }
        var deletedAudioFileName: String?
        try container.viewContext.performAndWait {
            let request = NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let entry = try container.viewContext.fetch(request).first else { return }
            deletedAudioFileName = entry.audioFileName
            container.viewContext.delete(entry)
            try saveContext()
        }
        return deletedAudioFileName
    }

    func clearAll() throws -> [String] {
        guard isStoreLoaded else { return [] }
        var evictedAudioFileNames: [String] = []
        try container.viewContext.performAndWait {
            evictedAudioFileNames = try deleteAllWithoutSave()
            try saveContext()
        }
        return evictedAudioFileNames
    }

    func trim(to maxCount: Int) throws -> [String] {
        guard isStoreLoaded else { return [] }
        var evictedAudioFileNames: [String] = []
        try container.viewContext.performAndWait {
            evictedAudioFileNames = try trimWithoutSave(to: maxCount)
            try saveContext()
        }
        return evictedAudioFileNames
    }

    // MARK: - Internals

    private func trimWithoutSave(to maxCount: Int) throws -> [String] {
        if maxCount <= 0 {
            return try deleteAllWithoutSave()
        }
        let request = NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        let entities = try container.viewContext.fetch(request)
        guard entities.count > maxCount else { return [] }
        var evictedAudioFileNames: [String] = []
        for entry in entities[maxCount...] {
            if let audioFileName = entry.audioFileName {
                evictedAudioFileNames.append(audioFileName)
            }
            container.viewContext.delete(entry)
        }
        return evictedAudioFileNames
    }

    private func deleteAllWithoutSave() throws -> [String] {
        let request = NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        let entities = try container.viewContext.fetch(request)
        var evictedAudioFileNames: [String] = []
        for entry in entities {
            if let audioFileName = entry.audioFileName {
                evictedAudioFileNames.append(audioFileName)
            }
            container.viewContext.delete(entry)
        }
        return evictedAudioFileNames
    }

    private func saveContext() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func makeHistoryItem(_ entry: PipelineHistoryEntry) -> PipelineHistoryItem? {
        guard let timestamp = entry.timestamp else { return nil }
        let intent = entry.intent.flatMap(PipelineHistoryItemIntent.init(rawValue:)) ?? .dictation
        return PipelineHistoryItem(
            intent: intent,
            selectedText: entry.selectedText,
            capturedSelection: entry.capturedSelection,
            id: entry.id,
            timestamp: timestamp,
            rawTranscript: entry.rawTranscript ?? "",
            postProcessedTranscript: entry.postProcessedTranscript ?? "",
            postProcessingPrompt: entry.postProcessingPrompt,
            systemPrompt: entry.systemPrompt,
            contextSummary: entry.contextSummary ?? "",
            contextSystemPrompt: entry.contextSystemPrompt,
            contextPrompt: entry.contextPrompt,
            contextScreenshotDataURL: entry.contextScreenshotDataURL,
            contextScreenshotStatus: entry.contextScreenshotStatus ?? "available (image)",
            postProcessingStatus: entry.postProcessingStatus ?? "",
            debugStatus: entry.debugStatus ?? "",
            customVocabulary: entry.customVocabulary ?? "",
            audioFileName: entry.audioFileName,
            contextAppName: entry.contextAppName,
            contextBundleIdentifier: entry.contextBundleIdentifier,
            contextWindowTitle: entry.contextWindowTitle)
    }

    private static func apply(_ item: PipelineHistoryItem, to entry: PipelineHistoryEntry) {
        entry.id = item.id
        entry.intent = item.intent.rawValue
        entry.selectedText = item.selectedText
        entry.capturedSelection = item.capturedSelection
        entry.timestamp = item.timestamp
        entry.rawTranscript = item.rawTranscript
        entry.postProcessedTranscript = item.postProcessedTranscript
        entry.postProcessingPrompt = item.postProcessingPrompt
        entry.systemPrompt = item.systemPrompt
        entry.contextSummary = item.contextSummary
        entry.contextSystemPrompt = item.contextSystemPrompt
        entry.contextPrompt = item.contextPrompt
        entry.contextScreenshotDataURL = item.contextScreenshotDataURL
        entry.contextScreenshotStatus = item.contextScreenshotStatus
        entry.postProcessingStatus = item.postProcessingStatus
        entry.debugStatus = item.debugStatus
        entry.customVocabulary = item.customVocabulary
        entry.audioFileName = item.audioFileName
        entry.contextAppName = item.contextAppName
        entry.contextBundleIdentifier = item.contextBundleIdentifier
        entry.contextWindowTitle = item.contextWindowTitle
    }

    private static func loadPersistentStoresSynchronously(_ container: NSPersistentContainer) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var remainingCallbacks = max(1, container.persistentStoreDescriptions.count)
        var firstError: Error?
        container.loadPersistentStores { _, error in
            lock.lock()
            if firstError == nil {
                firstError = error
            }
            remainingCallbacks -= 1
            let finished = remainingCallbacks <= 0
            lock.unlock()
            if finished {
                semaphore.signal()
            }
        }
        semaphore.wait()
        return firstError
    }

    private static func destroySQLiteStoreFiles(at path: String) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: path + suffix)
        }
    }

    /// After a store reset every `audio/<name>.wav` has lost its owning row,
    /// so the whole catalog can go. Recording only ever writes here through
    /// pipeline history, and the store loads before any recording can start.
    private static func removeOrphanedAudioFiles() {
        guard let directory = dataDirectory() else { return }
        let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: audioDirectory.path) else { return }
        for fileName in contents where fileName.hasSuffix(".wav") {
            try? fileManager.removeItem(atPath: audioDirectory.appendingPathComponent(fileName).path)
        }
    }

    private static func dataDirectory() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "OmniFlow"
        return base?.appendingPathComponent(name, isDirectory: true)
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "PipelineHistoryEntry"
        entity.managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)

        func attribute(_ name: String,
                       _ type: NSAttributeType,
                       optional: Bool,
                       defaultValue: Any? = nil) -> NSAttributeDescription {
            let description = NSAttributeDescription()
            description.name = name
            description.attributeType = type
            description.isOptional = optional
            description.defaultValue = defaultValue
            return description
        }

        entity.properties = [
            attribute("intent", .stringAttributeType, optional: true, defaultValue: "dictation"),
            attribute("selectedText", .stringAttributeType, optional: true),
            attribute("capturedSelection", .stringAttributeType, optional: true),
            attribute("id", .UUIDAttributeType, optional: false),
            attribute("timestamp", .dateAttributeType, optional: false),
            attribute("rawTranscript", .stringAttributeType, optional: false),
            attribute("postProcessedTranscript", .stringAttributeType, optional: false),
            attribute("postProcessingPrompt", .stringAttributeType, optional: true),
            attribute("systemPrompt", .stringAttributeType, optional: true),
            attribute("contextSummary", .stringAttributeType, optional: false),
            attribute("contextSystemPrompt", .stringAttributeType, optional: true),
            attribute("contextPrompt", .stringAttributeType, optional: true),
            attribute("contextScreenshotDataURL", .stringAttributeType, optional: true),
            attribute("contextScreenshotStatus", .stringAttributeType, optional: false),
            attribute("postProcessingStatus", .stringAttributeType, optional: false),
            attribute("debugStatus", .stringAttributeType, optional: false),
            attribute("customVocabulary", .stringAttributeType, optional: false),
            attribute("audioFileName", .stringAttributeType, optional: true),
            attribute("contextAppName", .stringAttributeType, optional: true),
            attribute("contextBundleIdentifier", .stringAttributeType, optional: true),
            attribute("contextWindowTitle", .stringAttributeType, optional: true)
        ]
        model.entities = [entity]
        return model
    }
}
