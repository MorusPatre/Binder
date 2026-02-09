import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import QuickLookThumbnailing
import ImageIO

// MARK: - 1. DATA MODEL
struct CachedFile: Hashable, Identifiable, Sendable {
    var id: URL { imageURL }
    let imageURL: URL
    let content: String
    let fileName: String
    let fileSize: Int64
    let dateAdded: Date
    
    var localMetadataURL: URL {
        return imageURL.deletingPathExtension().appendingPathExtension("json")
    }
}

// MARK: - 1.5 DISK CACHE
class DiskCache {
    static let shared = DiskCache()
    private let fileManager = FileManager.default
    private let cacheURL: URL
    
    private init() {
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheURL = urls[0].appendingPathComponent("com.binder.thumbnails")
        try? fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }
    
    func get(for url: URL) -> NSImage? {
        let key = cacheKey(for: url)
        let fileURL = cacheURL.appendingPathComponent(key)
        
        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            return image
        }
        return nil
    }
    
    func save(_ image: NSImage, for url: URL) {
        let key = cacheKey(for: url)
        let fileURL = cacheURL.appendingPathComponent(key)
        
        DispatchQueue.global(qos: .utility).async {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                return
            }
            try? data.write(to: fileURL)
        }
    }
    
    private func cacheKey(for url: URL) -> String {
        let modDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path.hashValue)_\(Int(modDate)).cache"
    }
}

// MARK: - 1.55 PREFETCH MANAGER
class PrefetchManager {
    static let shared = PrefetchManager()
    private var prefetchedURLs: Set<URL> = []
    private let lock = NSLock()
    
    func prefetch(
        indices: Range<Int>,
        items: [CachedFile],
        cellSize: CGFloat
    ) {
        let size = CGSize(width: cellSize, height: cellSize)
        
        for index in indices {
            guard index >= 0 && index < items.count else { continue }
            let url = items[index].imageURL
            
            if ThumbnailCache.shared.get(url) != nil { continue }
            
            lock.lock()
            let alreadyPrefetched = prefetchedURLs.contains(url)
            if !alreadyPrefetched {
                prefetchedURLs.insert(url)
            }
            lock.unlock()
            
            if alreadyPrefetched { continue }
            
            SmartImageLoader.shared.load(url: url, index: index, size: size) { _ in }
        }
    }
    
    func clear() {
        lock.lock()
        prefetchedURLs.removeAll()
        lock.unlock()
    }
}

// MARK: - 1.6 ICON FACTORY
class IconFactory {
    static let shared = IconFactory()
    private var cache: [String: NSImage] = [:]
    
    func icon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        if let cached = cache[ext] {
            return cached
        }
        
        let type = UTType(filenameExtension: ext) ?? .content
        let icon = NSWorkspace.shared.icon(for: type)
        cache[ext] = icon
        return icon
    }
}

// MARK: - 1.7 DIMENSION HELPER & CACHE
class DimensionCache {
    static let shared = DimensionCache()
    private var cache: [URL: String] = [:]
    
    func get(_ url: URL) -> String? {
        return cache[url]
    }
    
    func set(_ value: String, for url: URL) {
        cache[url] = value
    }
    
    func clear() {
        cache.removeAll()
    }
}

struct ImageUtils {
    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()
    
    static let byteFormatter: ByteCountFormatter = {
        let b = ByteCountFormatter()
        b.countStyle = .file
        b.allowedUnits = [.useMB, .useKB, .useGB]
        return b
    }()
    
    static let rawByteFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()
    
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    
    static let detailedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
    
    static nonisolated func getDimensionString(for url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, propertiesOptions) as? [CFString: Any] else { return nil }
        
        if var width = properties[kCGImagePropertyPixelWidth] as? Int,
           var height = properties[kCGImagePropertyPixelHeight] as? Int {
            
            if let orientation = properties[kCGImagePropertyOrientation] as? Int {
                if [5, 6, 7, 8].contains(orientation) {
                    swap(&width, &height)
                }
            }
            
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            
            let wStr = formatter.string(from: NSNumber(value: width)) ?? "\(width)"
            let hStr = formatter.string(from: NSNumber(value: height)) ?? "\(height)"
            
            return "\(wStr)\u{200A}×\u{200A}\(hStr)"
        }
        return nil
    }
}

// MARK: - 1.7.5 VIEW STATE & SORTING
enum GridDisplayMode: Int {
    case dimensions = 0
    case readableSize = 1
    case rawBytes = 2
    case dateAdded = 3
}

enum SortOrder: Int {
    case name = 0
    case sizeDescending = 1
    case dateAddedDescending = 2
    
    var preferredDisplayMode: GridDisplayMode {
        switch self {
        case .name:
            return .dimensions
        case .sizeDescending:
            return .readableSize
        case .dateAddedDescending:
            return .dateAdded
        }
    }
}

class ViewState: ObservableObject {
    @Published var displayMode: GridDisplayMode = .dimensions
    @Published var currentModifiers: NSEvent.ModifierFlags = []
    
    var activeMode: GridDisplayMode {
        return displayMode
    }
    
    var isDetailed: Bool {
        return currentModifiers.contains(.option)
    }
    
    var showReadableSize: Bool { activeMode == .readableSize }
    var showRawBytes: Bool { activeMode == .rawBytes }
    var showFileSize: Bool {
        activeMode == .readableSize || activeMode == .rawBytes || activeMode == .dateAdded || activeMode == .dimensions
    }
}

// MARK: - 1.8 METADATA MODEL & TAXONOMY
class TagTaxonomy: ObservableObject {
    static let shared = TagTaxonomy()
    
    struct TagDefinition: Hashable, Identifiable {
        var id: String { display }
        let display: String
        let category: String
        let synonyms: [String]
    }
    
    @Published var definitions: [TagDefinition] = []
    
    init() {
        definitions = [
            TagDefinition(display: "Golden Hour", category: "Lighting", synonyms: ["sunset", "dusk", "warm light"]),
        ]
    }
    
    func search(query: String) -> [TagDefinition] {
        let q = query.lowercased()
        return definitions.filter { def in
            def.display.lowercased().contains(q) ||
            def.category.lowercased().contains(q) ||
            def.synonyms.contains { $0.lowercased().contains(q) }
        }
    }
}

struct ImageMetadata: Codable, Equatable, Sendable {
    var generation_prompts: GenerationPrompts = GenerationPrompts()
    
    struct GenerationPrompts: Codable, Equatable, Sendable {
        var short: String = ""
        var detailed: DetailedPrompts = DetailedPrompts()
    }
    
    struct DetailedPrompts: Codable, Equatable, Sendable {
        var subject_identity: [String: String] = [:]
        var anthropometry: [String: String] = [:]
        var facial_features: [String: String] = [:]
        var environment: [String: String] = [:]
        var lighting_and_atmosphere: [String: String] = [:]
        var photography_technical: [String: String] = [:]
    }
}

// MARK: - 1.8.5 CENTRAL STORAGE & IDENTITY

class CentralStorage {
    static let shared = CentralStorage()
    private let fileManager = FileManager.default
    let metadataDirectory: URL
    
    private init() {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = urls[0].appendingPathComponent("com.binder.metadata")
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        metadataDirectory = appSupport
    }
    
    func fileURL(for uuid: String) -> URL {
        return metadataDirectory.appendingPathComponent("\(uuid).json")
    }
}

class FileIdentityManager {
    static let shared = FileIdentityManager()
    private let xattrKey = "com.binder.uuid"
    
    func getOrAssignUUID(for url: URL) -> String? {
        if let existing = readXattr(url: url, key: xattrKey) {
            return existing
        }
        
        let newUUID = UUID().uuidString
        if writeXattr(url: url, key: xattrKey, value: newUUID) {
            return newUUID
        }
        return nil
    }
    
    private func readXattr(url: URL, key: String) -> String? {
        return url.withUnsafeFileSystemRepresentation { fileSystemPath -> String? in
            guard let fileSystemPath = fileSystemPath else { return nil }
            let length = getxattr(fileSystemPath, key, nil, 0, 0, 0)
            if length == -1 { return nil }
            var data = Data(count: length)
            let result = data.withUnsafeMutableBytes {
                getxattr(fileSystemPath, key, $0.baseAddress, length, 0, 0)
            }
            if result == -1 { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
    
    private func writeXattr(url: URL, key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return url.withUnsafeFileSystemRepresentation { fileSystemPath -> Bool in
            guard let fileSystemPath = fileSystemPath else { return false }
            let result = data.withUnsafeBytes {
                setxattr(fileSystemPath, key, $0.baseAddress, data.count, 0, 0)
            }
            return result == 0
        }
    }
}

// MARK: - 1.9 METADATA MANAGER
class SidecarManager {
    static let shared = SidecarManager()
    
    func jsonURL(for imageURL: URL) -> URL? {
        guard let uuid = FileIdentityManager.shared.getOrAssignUUID(for: imageURL) else {
            return nil
        }
        return CentralStorage.shared.fileURL(for: uuid)
    }
    
    func load(for imageURL: URL) -> ImageMetadata {
        if let storageURL = jsonURL(for: imageURL),
           let data = try? Data(contentsOf: storageURL),
           let metadata = try? JSONDecoder().decode(ImageMetadata.self, from: data) {
            return metadata
        }
        
        let legacySidecar = imageURL.deletingPathExtension().appendingPathExtension("json")
        if let data = try? Data(contentsOf: legacySidecar),
           let metadata = try? JSONDecoder().decode(ImageMetadata.self, from: data) {
            save(metadata, for: imageURL)
            return metadata
        }
        
        return ImageMetadata()
    }
    
    func save(_ metadata: ImageMetadata, for imageURL: URL) {
        guard let storageURL = jsonURL(for: imageURL) else { return }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        if let data = try? encoder.encode(metadata) {
            DispatchQueue.global(qos: .utility).async {
                try? data.write(to: storageURL)
            }
        }
    }
}

// MARK: - 2. THE CACHE
class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    
    private init() {
        cache.countLimit = 5000
    }
    
    func get(_ url: URL) -> NSImage? {
        return cache.object(forKey: url as NSURL)
    }
    
    func set(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

// MARK: - 3. THE LOADER
// MARK: - 3. THE LOADER (FIXED)
class SmartImageLoader: ObservableObject {
    static let shared = SmartImageLoader()
    
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInteractive
        return q
    }()
    
    private var activeOperations: [URL: Operation] = [:]
    // Track all waiting callbacks for a specific URL
    private var completionBlocks: [URL: [(NSImage?) -> Void]] = [:]
    private var unfairLock = os_unfair_lock()
    
    func load(url: URL, index: Int, size: CGSize, completion: @escaping (NSImage?) -> Void) {
        // 1. Check Memory Cache
        if let cached = ThumbnailCache.shared.get(url) {
            completion(cached)
            return
        }
        
        // 2. Check Disk/Schedule
        DispatchQueue.global(qos: .userInteractive).async {
            if let diskCached = DiskCache.shared.get(for: url) {
                DispatchQueue.main.async {
                    ThumbnailCache.shared.set(diskCached, for: url)
                    completion(diskCached)
                }
                return
            }
            self.scheduleGeneration(url: url, size: size, completion: completion)
        }
    }
    
    private func scheduleGeneration(url: URL, size: CGSize, completion: @escaping (NSImage?) -> Void) {
        os_unfair_lock_lock(&unfairLock)
        
        // If operation is already running, just add this completion to the list
        if activeOperations[url] != nil {
            completionBlocks[url, default: []].append(completion)
            os_unfair_lock_unlock(&unfairLock)
            return
        }
        
        // Start a new operation
        completionBlocks[url] = [completion]
        let operation = ThumbnailOperation(url: url, size: size)
        
        operation.completionBlock = { [weak self, weak operation] in
            guard let self = self else { return }
            
            let generated = operation?.generatedImage
            
            // Capture all blocks that were waiting for this URL
            os_unfair_lock_lock(&self.unfairLock)
            let blocks = self.completionBlocks.removeValue(forKey: url) ?? []
            self.activeOperations.removeValue(forKey: url)
            os_unfair_lock_unlock(&self.unfairLock)
            
            if let img = generated {
                ThumbnailCache.shared.set(img, for: url)
                DiskCache.shared.save(img, for: url)
            }
            
            // Notify EVERYONE who requested this image
            DispatchQueue.main.async {
                for block in blocks {
                    block(generated)
                }
            }
        }
        
        activeOperations[url] = operation
        queue.addOperation(operation)
        os_unfair_lock_unlock(&unfairLock)
    }
    
    func cancel(url: URL) {
        os_unfair_lock_lock(&unfairLock)
        // Only cancel if no one else is waiting for this image
        // (If multiple views or prefetchers want it, keep it alive)
        if let blocks = completionBlocks[url], blocks.count <= 1 {
            if let op = activeOperations[url] {
                op.cancel()
                activeOperations.removeValue(forKey: url)
                completionBlocks.removeValue(forKey: url)
            }
        }
        os_unfair_lock_unlock(&unfairLock)
    }
    
    func purge() {
        queue.cancelAllOperations()
        os_unfair_lock_lock(&unfairLock)
        activeOperations.removeAll()
        completionBlocks.removeAll()
        os_unfair_lock_unlock(&unfairLock)
    }
}

// MARK: - THUMBNAIL OPERATION
class ThumbnailOperation: Operation, @unchecked Sendable {
    let url: URL
    let targetSize: CGSize
    var generatedImage: NSImage?
    
    private var _isExecuting = false
    private var _isFinished = false
    
    init(url: URL, size: CGSize) {
        self.url = url
        self.targetSize = size
        super.init()
    }
    
    override var isAsynchronous: Bool { true }
    override var isExecuting: Bool { _isExecuting }
    override var isFinished: Bool { _isFinished }
    
    func finish() {
        willChangeValue(forKey: "isExecuting")
        willChangeValue(forKey: "isFinished")
        _isExecuting = false
        _isFinished = true
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
    
    func startExecuting() {
        willChangeValue(forKey: "isExecuting")
        _isExecuting = true
        didChangeValue(forKey: "isExecuting")
    }
    
    override func start() {
        if isCancelled {
            finish()
            return
        }
        
        startExecuting()
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        if let embedded = fetchEmbeddedThumbnail() {
            self.generatedImage = embedded
            self.finish()
            return
        }
        
        if isCancelled {
            finish()
            return
        }
        
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: targetSize,
            scale: 2.0,
            representationTypes: .thumbnail
        )
        
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] (thumb, error) in
            guard let self = self else { return }
            
            if !self.isCancelled, let t = thumb {
                self.generatedImage = t.nsImage
            }
            self.finish()
        }
    }
    
    private func fetchEmbeddedThumbnail() -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        
        let maxDimension = max(targetSize.width, targetSize.height) * 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }
}

// MARK: - SEARCH ENGINE
private final class FileCollector: @unchecked Sendable {
    private var files: [CachedFile] = []
    private let lock = NSLock()
    private var lastUpdate = Date()
    private let onProgress: (Int) -> Void
    
    init(onProgress: @escaping (Int) -> Void) {
        self.onProgress = onProgress
    }
    
    func append(_ batch: [CachedFile]) {
        guard !batch.isEmpty else { return }
        
        lock.lock()
        files.append(contentsOf: batch)
        
        let now = Date()
        if now.timeIntervalSince(lastUpdate) > 0.1 {
            let count = files.count
            lastUpdate = now
            DispatchQueue.main.async { [onProgress] in
                onProgress(count)
            }
        }
        lock.unlock()
    }
    
    var allFiles: [CachedFile] {
        lock.lock()
        defer { lock.unlock() }
        return files
    }
}

class InMemorySearcher: ObservableObject {
    @MainActor @Published var filteredResults: [CachedFile] = []
    @MainActor @Published var isIndexing = false
    @MainActor @Published var progress: Double = 0.0
    @MainActor @Published var statusMessage = "Select a folder to build the index."
    @MainActor @Published var selectedFolder: URL?
    @MainActor @Published var filesWithMetadata: Set<URL> = []
    @MainActor @Published var sortOrder: SortOrder = .name
    
    @MainActor @Published var historyStack: [URL] = []
    @MainActor @Published var forwardStack: [URL] = []
    
    @MainActor var canGoBack: Bool { !historyStack.isEmpty }
    @MainActor var canGoForward: Bool { !forwardStack.isEmpty }
    
    private var masterIndex: [CachedFile] = []
    private var searchTask: Task<Void, Never>?
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                navigateTo(url, addToHistory: true)
            }
        }
    }
    
    @MainActor
    func navigateTo(_ folder: URL, addToHistory: Bool) {
        if addToHistory, let current = selectedFolder {
            historyStack.append(current)
            forwardStack.removeAll()
        }
        selectedFolder = folder
        buildIndex()
    }
    
    @MainActor
    func goBack() {
        guard !isIndexing, let previous = historyStack.popLast() else { return }
        if let current = selectedFolder {
            forwardStack.append(current)
        }
        selectedFolder = previous
        buildIndex()
    }
    
    @MainActor
    func goForward() {
        guard !isIndexing, let next = forwardStack.popLast() else { return }
        if let current = selectedFolder {
            historyStack.append(current)
        }
        selectedFolder = next
        buildIndex()
    }
    
    func applySort() {
        let sortFn: (CachedFile, CachedFile) -> Bool
        switch sortOrder {
        case .name:
            sortFn = { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .sizeDescending:
            sortFn = {
                if $0.fileSize != $1.fileSize { return $0.fileSize > $1.fileSize }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        case .dateAddedDescending:
            sortFn = {
                if $0.dateAdded != $1.dateAdded { return $0.dateAdded > $1.dateAdded }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        }
        masterIndex.sort(by: sortFn)
        filteredResults.sort(by: sortFn)
    }
    
    func buildIndex() {
        guard let folder = selectedFolder else { return }
        let currentSortOrder = sortOrder
        SmartImageLoader.shared.purge()
        DimensionCache.shared.clear()
        PrefetchManager.shared.clear()
        
        Task { @MainActor in
            self.isIndexing = true
            self.masterIndex.removeAll()
            self.filteredResults.removeAll()
            self.statusMessage = "Scanning..."
            self.progress = 0
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fileManager = FileManager.default
            let _ = folder.startAccessingSecurityScopedResource()
            defer { folder.stopAccessingSecurityScopedResource() }
            
            guard let topLevel = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                Task { @MainActor in self.isIndexing = false }
                return
            }
            
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "gif", "webp", "bmp"]
            
            let collector = FileCollector { count in
                Task { @MainActor in
                    self.statusMessage = "Found \(count) images..."
                }
            }
            
            DispatchQueue.concurrentPerform(iterations: topLevel.count) { i in
                let item = topLevel[i]
                var localBatch: [CachedFile] = []
                
                func process(_ url: URL) {
                    if imageExtensions.contains(url.pathExtension.lowercased()) {
                        let name = url.lastPathComponent
                        
                        let resources = try? url.resourceValues(forKeys: [.fileSizeKey, .addedToDirectoryDateKey, .creationDateKey])
                        let size = Int64(resources?.fileSize ?? 0)
                        let date = resources?.addedToDirectoryDate ?? resources?.creationDate ?? Date()
                        
                        // Dimensions computed lazily now, not here.
                        
                        localBatch.append(CachedFile(
                            imageURL: url,
                            content: name.lowercased(),
                            fileName: name,
                            fileSize: size,
                            dateAdded: date
                        ))
                    }
                }
                
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let enumerator = fileManager.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                            for case let fileURL as URL in enumerator {
                                process(fileURL)
                            }
                        }
                    } else {
                        process(item)
                    }
                }
                collector.append(localBatch)
            }
            
            var processingFiles = collector.allFiles
            let sortCount = processingFiles.count
            
            Task { @MainActor in
                self.statusMessage = "Sorting \(sortCount) images..."
            }
            
            switch currentSortOrder {
            case .name:
                processingFiles.sort {
                    $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }
            case .sizeDescending:
                processingFiles.sort {
                    if $0.fileSize != $1.fileSize { return $0.fileSize > $1.fileSize }
                    return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }
            case .dateAddedDescending:
                processingFiles.sort {
                    if $0.dateAdded != $1.dateAdded { return $0.dateAdded > $1.dateAdded }
                    return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }
            }
            
            let finalSortedFiles = processingFiles
            
            Task { @MainActor in
                self.masterIndex = finalSortedFiles
                self.filteredResults = finalSortedFiles
                self.isIndexing = false
                self.statusMessage = "Ready. \(sortCount) images loaded."
                self.progress = 1.0
                self.scanForMetadata(in: finalSortedFiles)
            }
        }
    }
    
    func performSearch(text: String) {
        searchTask?.cancel()
        
        if text.isEmpty {
            self.filteredResults = self.masterIndex
            return
        }
        
        let snapshot = self.masterIndex
        searchTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            if Task.isCancelled { return }
            
            let query = text.lowercased()
            let results = snapshot.filter { $0.content.contains(query) }
            
            if !Task.isCancelled {
                await MainActor.run {
                    self.filteredResults = results
                }
            }
        }
    }
    
    private func scanForMetadata(in files: [CachedFile]) {
        let imageURLs = files.map { $0.imageURL }

        Task.detached(priority: .background) {
            let fileManager = FileManager.default
            var foundMetadataURLs: [URL] = []
            
            for (index, url) in imageURLs.enumerated() {
                if Task.isCancelled { return }
                
                let jsonPath = url.deletingPathExtension().appendingPathExtension("json").path
                
                if fileManager.fileExists(atPath: jsonPath) {
                    foundMetadataURLs.append(url)
                }
                
                if foundMetadataURLs.count >= 500 || index == imageURLs.count - 1 {
                    if !foundMetadataURLs.isEmpty {
                        let batch = foundMetadataURLs
                        foundMetadataURLs.removeAll(keepingCapacity: true)
                        
                        await MainActor.run {
                            self.filesWithMetadata.formUnion(batch)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - LAYOUT HELPERS

// MARK: - FLOW LAYOUT FOR TAGS
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        
        for (index, subview) in subviews.enumerated() {
            if index < result.positions.count {
                let position = result.positions[index]
                subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
            }
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }
        
        return (positions, CGSize(width: maxX, height: currentY + lineHeight))
    }
}

// MARK: - COMPACT METADATA FIELD EDITOR
struct MetadataFieldEditor: View {
    let label: String
    @Binding var dict: [String: String]
    
    @State private var isExpanded = false
    @State private var newKey = ""
    @State private var newValue = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                
                if !dict.isEmpty {
                    Text("(\(dict.count))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "minus.circle" : "plus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            if !dict.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(dict.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 2) {
                            Text("\(key): \(value)")
                                .font(.system(size: 10))
                                .lineLimit(1)
                            
                            Button(action: { dict.removeValue(forKey: key) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .opacity(0.6)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
            
            if isExpanded {
                HStack(spacing: 6) {
                    TextField("Key", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 60)
                    
                    TextField("Value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                    
                    Button(action: {
                        if !newKey.isEmpty && !newValue.isEmpty {
                            dict[newKey] = newValue
                            newKey = ""
                            newValue = ""
                        }
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newKey.isEmpty || newValue.isEmpty)
                }
                .padding(.top, 4)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }
}

// MARK: - SYNTAX HIGHLIGHTING EDITOR
struct JSONCodeEditor: NSViewRepresentable {
    @Binding var text: String
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        
        textView.delegate = context.coordinator
        
        textView.layoutManager?.delegate = context.coordinator
        
        scrollView.documentView = textView
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            textView.string = text
            context.coordinator.applyFormattingAndHighlight(textView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: JSONCodeEditor
        private let hangingIndentSpaces = 4
        private var charWidth: CGFloat = 6.6
        
        init(_ parent: JSONCodeEditor) {
            self.parent = parent
            super.init()
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyFormattingAndHighlight(textView)
        }
        
        func applyFormattingAndHighlight(_ textView: NSTextView) {
            calculateCharWidth(for: textView)
            applyHangingIndents(textView)
            highlight(textView)
        }
        
        private func calculateCharWidth(for textView: NSTextView) {
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            charWidth = ("M" as NSString).size(withAttributes: attributes).width
        }
        
        private func applyHangingIndents(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            
            let text = textView.string as NSString
            
            var lineStart = 0
            while lineStart < text.length {
                var lineEnd = 0
                var contentEnd = 0
                text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd, for: NSRange(location: lineStart, length: 0))
                
                let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let lineContent = text.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
                
                let leadingWhitespace = countLeadingWhitespace(in: lineContent)
                
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineBreakMode = .byWordWrapping
                
                paragraphStyle.headIndent = CGFloat(leadingWhitespace + hangingIndentSpaces) * charWidth
                
                paragraphStyle.firstLineHeadIndent = 0
                
                paragraphStyle.lineSpacing = 4
                
                textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
                
                lineStart = lineEnd
            }
        }
        
        private func countLeadingWhitespace(in string: String) -> Int {
            var count = 0
            for char in string {
                if char == " " {
                    count += 1
                } else if char == "\t" {
                    count += 4
                } else {
                    break
                }
            }
            return count
        }
        
        func highlight(_ textView: NSTextView) {
            let text = textView.string as NSString
            let textStorage = textView.textStorage
            let fullRange = NSRange(location: 0, length: text.length)
            
            textStorage?.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: fullRange)
            
            let punctuationPattern = "[\\[\\]\\{\\},:]"
            let stringPattern = "\"(?:[^\"\\\\]|\\\\.)*\""
            let keyPattern = "\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)"
            let numberPattern = "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
            let keywordPattern = "\\b(true|false|null)\\b"
            
            func apply(pattern: String, color: NSColor) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
                regex.enumerateMatches(in: text as String, options: [], range: fullRange) { match, _, _ in
                    if let matchRange = match?.range {
                        textStorage?.addAttribute(.foregroundColor, value: color, range: matchRange)
                    }
                }
            }

            apply(pattern: punctuationPattern, color: NSColor(white: 1, alpha: 1.0))
            apply(pattern: numberPattern, color: NSColor(red: 0.85, green: 0.8, blue: 0.55, alpha: 1.0))
            apply(pattern: keywordPattern, color: NSColor(red: 1.0, green: 0.2, blue: 0.6, alpha: 1.0))
            apply(pattern: stringPattern, color: NSColor(red: 1.0, green: 0.5, blue: 0.45, alpha: 1.0))
            apply(pattern: keyPattern, color: NSColor(red: 0.8, green: 0.6, blue: 0.4, alpha: 1.0))
        }
    }
}

// MARK: - RESIZABLE INSPECTOR PANEL (TEXT EDITOR STYLE)
struct ResizablePanelView: View {
    @Binding var isOpen: Bool
    @Binding var panelWidth: CGFloat
    
    let selectionCount: Int
    let firstSelectedURL: URL?
    let getFullSelection: () -> Set<URL>
    
    var maxAllowedWidth: CGFloat
    
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isCursorPushed = false
    
    @State private var metadata: ImageMetadata = ImageMetadata()
    @State private var isInternalUpdate = false
    
    @State private var rawTextMode = false
    @State private var rawJSON: String = ""
    
    private let minWidth: CGFloat = 300
    
    private func updateCursor(hovering: Bool, dragging: Bool) {
        let shouldShowCursor = hovering || dragging
        
        if shouldShowCursor && !isCursorPushed {
            NSCursor.resizeLeftRight.push()
            isCursorPushed = true
        } else if !shouldShowCursor && isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
    }
    
    private var wordCount: Int {
        metadata.generation_prompts.short
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
    
    private var charCount: Int {
        metadata.generation_prompts.short.count
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                // MARK: - RESIZE HANDLE
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .overlay(
                        Color.clear
                            .frame(width: 6)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                isHovering = inside
                                updateCursor(hovering: inside, dragging: dragStartWidth != nil)
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragStartWidth == nil {
                                            dragStartWidth = panelWidth
                                            updateCursor(hovering: isHovering, dragging: true)
                                        }
                                        
                                        if let start = dragStartWidth {
                                            let newWidth = start - value.translation.width
                                            panelWidth = min(max(newWidth, minWidth), maxAllowedWidth)
                                        }
                                    }
                                    .onEnded { _ in
                                        dragStartWidth = nil
                                        updateCursor(hovering: isHovering, dragging: false)
                                    }
                            )
                    )
                    .zIndex(2)

                // MARK: - TEXT EDITOR CONTENT
                VStack(alignment: .leading, spacing: 0) {
                    
                    // MARK: Header Bar
                    HStack(spacing: 12) {
                        if let url = firstSelectedURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Image(systemName: "doc")
                                .foregroundColor(.secondary)
                            Text("No Selection")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if selectionCount > 1 {
                            Text("\(selectionCount) files")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        
                        Button(action: {
                            rawTextMode.toggle()
                            if rawTextMode {
                                let encoder = JSONEncoder()
                                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                if let data = try? encoder.encode(metadata),
                                   let string = String(data: data, encoding: .utf8) {
                                    rawJSON = string
                                }
                            } else {
                                if let data = rawJSON.data(using: .utf8),
                                   let parsed = try? JSONDecoder().decode(ImageMetadata.self, from: data) {
                                    metadata = parsed
                                }
                            }
                        }) {
                            Image(systemName: rawTextMode ? "text.alignleft" : "curlybraces")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(rawTextMode ? "Switch to Caption Mode" : "Switch to JSON Mode")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    if selectionCount == 0 {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("Select an image to edit its metadata")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        // MARK: Editor Area
                        if rawTextMode {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("JSON")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 6)
                                
                                JSONCodeEditor(text: $rawJSON)
                                    .background(Color(NSColor.textBackgroundColor))
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                
                                Text("CAPTION")
                                    .font(.system(size: 10, weight: .semibold, design: .default))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                                
                                TextEditor(text: $metadata.generation_prompts.short)
                                    .font(.system(size: 14, design: .serif))
                                    .lineSpacing(6)
                                    .scrollContentBackground(.hidden)
                                    .background(Color.clear)
                                    .padding(.horizontal, 12)
                                    .frame(maxHeight: .infinity)
                                
                                Divider()
                                    .padding(.horizontal, 16)
                                
                                DisclosureGroup("Metadata Fields") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        MetadataFieldEditor(label: "Subject", dict: $metadata.generation_prompts.detailed.subject_identity)
                                        MetadataFieldEditor(label: "Body Type", dict: $metadata.generation_prompts.detailed.anthropometry)
                                        MetadataFieldEditor(label: "Environment", dict: $metadata.generation_prompts.detailed.environment)
                                        MetadataFieldEditor(label: "Lighting", dict: $metadata.generation_prompts.detailed.lighting_and_atmosphere)
                                        MetadataFieldEditor(label: "Technical", dict: $metadata.generation_prompts.detailed.photography_technical)
                                    }
                                    .padding(.top, 8)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                        
                        Divider()
                        
                        // MARK: Footer Stats
                        HStack {
                            if !rawTextMode {
                                Text("\(wordCount) words")
                                Text("•")
                                Text("\(charCount) characters")
                            } else {
                                Text("\(rawJSON.count) bytes")
                            }
                            Spacer()
                            
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green.opacity(0.6))
                                .font(.system(size: 10))
                            Text("Saved")
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(NSColor.controlBackgroundColor))
                    }
                }
                .frame(width: panelWidth)
                .background(Color(NSColor.textBackgroundColor))
            }
            .frame(width: panelWidth + 1)
        }
        .frame(width: isOpen ? (panelWidth + 1) : 0, alignment: .leading)
        .clipped()
        .onDisappear {
            if isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .onChange(of: firstSelectedURL) { _, newURL in
            isInternalUpdate = true
            loadMetadata(for: newURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isInternalUpdate = false }
        }
        .onChange(of: metadata) { _, newValue in
            if !isInternalUpdate && selectionCount > 0 {
                saveMetadata(newValue)
            }
        }
        .onChange(of: rawJSON) { _, newValue in
            if rawTextMode && !isInternalUpdate && selectionCount > 0 {
                if let data = newValue.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(ImageMetadata.self, from: data) {
                    metadata = parsed
                }
            }
        }
    }
    
    private func loadMetadata(for url: URL?) {
        guard let url = url else {
            metadata = ImageMetadata()
            rawJSON = "{}"
            return
        }
        metadata = SidecarManager.shared.load(for: url)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metadata),
           let string = String(data: data, encoding: .utf8) {
            rawJSON = string
        }
    }
    
    private func saveMetadata(_ data: ImageMetadata) {
        let allSelected = getFullSelection()
        for url in allSelected {
            SidecarManager.shared.save(data, for: url)
        }
    }
}

// MARK: - UI SUPPORT COMPONENTS
struct InstantSelectButtonStyle: ButtonStyle {
    let isSelected: Bool
    let onPress: () -> Void
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && !isSelected {
                    onPress()
                }
            }
    }
}

struct AnimatableWidthReader<Content: View>: View, Animatable {
    var targetWidth: CGFloat
    
    var animatableData: CGFloat {
        get { targetWidth }
        set { targetWidth = newValue }
    }
    
    @ViewBuilder let content: (CGFloat) -> Content
    
    var body: some View {
        content(targetWidth)
    }
}

struct ScrollViewAccessor: NSViewRepresentable {
    let onConnect: (NSScrollView) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let sv = view.enclosingScrollView {
                onConnect(sv)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - WINDOW TITLE ACCESSOR
struct WindowAccessor: NSViewRepresentable {
    let representedURL: URL?
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            
            window.representedURL = representedURL
            
            if let url = representedURL {
                window.title = url.lastPathComponent
            } else {
                window.title = "Binder"
            }
        }
    }
}

class AutoScrollHandler: ObservableObject {
    private var timer: Timer?
    private weak var scrollView: NSScrollView?
    
    private let zoneHeight: CGFloat = 50.0
    private let maxSpeed: CGFloat = 25.0
    var onScroll: ((CGPoint) -> Void)?
    var onScrollSelectionUpdate: (() -> Void)?
    
    // Prefetch support
    var prefetchContext: PrefetchContext?
    
    struct PrefetchContext {
        let getItems: () -> [CachedFile]
        let gridColumnsCount: () -> Int
        let rowHeight: () -> CGFloat
        let cellSize: CGFloat
        let prefetchRowCount: Int
    }
    
    func connect(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }
    
    func processDragLocation(_ screenPoint: CGPoint) {
        guard let sv = scrollView, let window = sv.window else { return }
        
        let svFrameInScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
        var delta: CGFloat = 0
        
        if screenPoint.y > (svFrameInScreen.maxY - zoneHeight) {
            let dist = screenPoint.y - (svFrameInScreen.maxY - zoneHeight)
            delta = -maxSpeed * min(1.0, dist / zoneHeight)
        } else if screenPoint.y < (svFrameInScreen.minY + zoneHeight) {
            let dist = (svFrameInScreen.minY + zoneHeight) - screenPoint.y
            delta = maxSpeed * min(1.0, dist / zoneHeight)
        }
        
        if delta != 0 {
            startTimer(delta: delta)
        } else {
            stopTimer()
        }
    }
    
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private var currentDelta: CGFloat = 0
    
    private func startTimer(delta: CGFloat) {
        self.currentDelta = delta
        if timer != nil { return }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.performScroll()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    private func performScroll() {
        guard let sv = scrollView,
              let docView = sv.documentView,
              let window = sv.window else { return }
        
        let contentView = sv.contentView
        var newOrigin = contentView.bounds.origin
        let isFlipped = docView.isFlipped
        
        let scrollDelta = isFlipped ? currentDelta : -currentDelta
        newOrigin.y = min(max(0, newOrigin.y + scrollDelta), max(0, docView.bounds.height - contentView.bounds.height))
        
        if contentView.bounds.origin.y != newOrigin.y {
            contentView.scroll(to: newOrigin)
            sv.reflectScrolledClipView(contentView)
            
            let mouseLoc = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let docPoint = docView.convert(mouseLoc, from: nil)
            onScroll?(docPoint)
            onScrollSelectionUpdate?()
            
            // Prefetch rows ahead of scroll direction
            prefetchAhead(scrollView: sv, scrollingDown: currentDelta > 0)
        }
    }
    
    private func prefetchAhead(scrollView sv: NSScrollView, scrollingDown: Bool) {
        guard let ctx = prefetchContext else { return }
        
        let items = ctx.getItems()
        guard !items.isEmpty else { return }
        
        let cols = ctx.gridColumnsCount()
        let rh = ctx.rowHeight()
        guard cols > 0, rh > 0 else { return }
        
        let visibleRect = sv.contentView.bounds
        let topPadding: CGFloat = 12
        
        if scrollingDown {
            let bottomEdge = visibleRect.maxY
            let firstRowBelow = max(0, Int((bottomEdge - topPadding) / rh))
            let lastRowToFetch = firstRowBelow + ctx.prefetchRowCount
            
            let startIndex = firstRowBelow * cols
            let endIndex = min(items.count, (lastRowToFetch + 1) * cols)
            
            if startIndex < endIndex {
                PrefetchManager.shared.prefetch(
                    indices: startIndex..<endIndex,
                    items: items,
                    cellSize: ctx.cellSize
                )
            }
        } else {
            let topEdge = visibleRect.minY
            let firstRowAbove = max(0, Int((topEdge - topPadding) / rh))
            let lastRowToFetch = max(0, firstRowAbove - ctx.prefetchRowCount)
            
            let startIndex = max(0, lastRowToFetch * cols)
            let endIndex = min(items.count, (firstRowAbove + 1) * cols)
            
            if startIndex < endIndex {
                PrefetchManager.shared.prefetch(
                    indices: startIndex..<endIndex,
                    items: items,
                    cellSize: ctx.cellSize
                )
            }
        }
    }
}

// MARK: - KEYBOARD HANDLER
class KeyboardHandler: ObservableObject {
    @Published var selectAllTriggered = false
    private var monitor: Any?
    
    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" {
                DispatchQueue.main.async {
                    self?.selectAllTriggered = true
                }
                return nil
            }
            return event
        }
    }
    
    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct ClickThroughBackground: NSViewRepresentable {
    var sortOrder: SortOrder
    var displayMode: GridDisplayMode // <--- NEW: Pass current display mode
    var onSortOrderChanged: ((SortOrder) -> Void)? = nil
    var onDisplayModeChanged: ((GridDisplayMode) -> Void)? = nil // <--- NEW: Callback

    func makeNSView(context: Context) -> FirstMouseView {
        let view = FirstMouseView()
        view.coordinator = context.coordinator
        view.currentSortOrder = sortOrder
        view.currentDisplayMode = displayMode
        return view
    }

    func updateNSView(_ nsView: FirstMouseView, context: Context) {
        nsView.currentSortOrder = sortOrder
        nsView.currentDisplayMode = displayMode
        context.coordinator.onSortOrderChanged = onSortOrderChanged
        context.coordinator.onDisplayModeChanged = onDisplayModeChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSortOrderChanged: onSortOrderChanged, onDisplayModeChanged: onDisplayModeChanged)
    }

    class Coordinator: NSObject {
        var onSortOrderChanged: ((SortOrder) -> Void)?
        var onDisplayModeChanged: ((GridDisplayMode) -> Void)?

        init(onSortOrderChanged: ((SortOrder) -> Void)?, onDisplayModeChanged: ((GridDisplayMode) -> Void)?) {
            self.onSortOrderChanged = onSortOrderChanged
            self.onDisplayModeChanged = onDisplayModeChanged
            super.init()
        }

        // Sorting Actions
        @objc func sortByName() { onSortOrderChanged?(.name) }
        @objc func sortBySize() { onSortOrderChanged?(.sizeDescending) }
        @objc func sortByDate() { onSortOrderChanged?(.dateAddedDescending) }
        
        // Item Info Actions
        @objc func showDimensions() { onDisplayModeChanged?(.dimensions) }
        @objc func showReadable() { onDisplayModeChanged?(.readableSize) }
        @objc func showDate() { onDisplayModeChanged?(.dateAdded) }
    }

    class FirstMouseView: NSView {
        var coordinator: Coordinator?
        var currentSortOrder: SortOrder = .name
        var currentDisplayMode: GridDisplayMode = .dimensions

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
        
        private func makeIcon(_ name: String) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let coordinator = coordinator else { return nil }

            let menu = NSMenu()

            // MARK: - SECTION 1: SORT BY
            let sortMenu = NSMenu()
            
            let nameItem = NSMenuItem(title: "Name", action: #selector(Coordinator.sortByName), keyEquivalent: "")
            nameItem.target = coordinator
            nameItem.state = currentSortOrder == .name ? .on : .off
            sortMenu.addItem(nameItem)

            let sizeItem = NSMenuItem(title: "Size", action: #selector(Coordinator.sortBySize), keyEquivalent: "")
            sizeItem.target = coordinator
            sizeItem.state = currentSortOrder == .sizeDescending ? .on : .off
            sortMenu.addItem(sizeItem)
            
            let dateItem = NSMenuItem(title: "Date Added", action: #selector(Coordinator.sortByDate), keyEquivalent: "")
            dateItem.target = coordinator
            dateItem.state = currentSortOrder == .dateAddedDescending ? .on : .off
            sortMenu.addItem(dateItem)

            let sortMenuItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            sortMenuItem.submenu = sortMenu
            sortMenuItem.image = makeIcon("arrow.up.arrow.down")
            menu.addItem(sortMenuItem)

            menu.addItem(NSMenuItem.separator())

            // MARK: - SECTION 2: SHOW ITEM INFO
            let infoMenu = NSMenu()

            let dimItem = NSMenuItem(title: "Dimensions", action: #selector(Coordinator.showDimensions), keyEquivalent: "")
            dimItem.target = coordinator
            dimItem.state = currentDisplayMode == .dimensions ? .on : .off
            infoMenu.addItem(dimItem)

            let readableItem = NSMenuItem(title: "File Size", action: #selector(Coordinator.showReadable), keyEquivalent: "")
            readableItem.target = coordinator
            readableItem.state = currentDisplayMode == .readableSize ? .on : .off
            infoMenu.addItem(readableItem)

            let dateDisplayItem = NSMenuItem(title: "Date Added", action: #selector(Coordinator.showDate), keyEquivalent: "")
            dateDisplayItem.target = coordinator
            dateDisplayItem.state = currentDisplayMode == .dateAdded ? .on : .off
            infoMenu.addItem(dateDisplayItem)

            // The specific name you requested
            let infoMenuItem = NSMenuItem(title: "Show Item Info", action: nil, keyEquivalent: "")
            infoMenuItem.submenu = infoMenu
            infoMenuItem.image = makeIcon("info.circle")
            menu.addItem(infoMenuItem)

            return menu
        }
    }
}

// MARK: - THUMBNAIL & GRID ITEMS
struct ThumbnailView: View {
    let url: URL
    let index: Int
    let isSelected: Bool
    let cellSize: CGFloat
    var onSizeChange: ((CGSize) -> Void)? = nil
    
    @State private var thumbnail: NSImage?
    @State private var isLoaded = false
    @State private var loadTask: Task<Void, Never>?
    
    private let tolerancePadding: CGFloat = 13.0
    
    var body: some View {
        let maxAvail = CGSize(width: max(0, cellSize - 52), height: max(0, cellSize - 52))
        
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isSelected ? Color(NSColor.quaternaryLabelColor) : Color.clear)
            
            if let img = thumbnail {
                let fitted = img.size.aspectFitted(to: maxAvail)
                
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                    .shadow(radius: 2, y: 1)
                    .background(
                        Color.clear
                            .frame(width: fitted.width + (tolerancePadding * 2),
                                   height: fitted.height + (tolerancePadding * 2))
                            .contentShape(Rectangle())
                    )
                    .task(id: isLoaded) {
                        onSizeChange?(fitted)
                    }
            } else {
                Image(nsImage: IconFactory.shared.icon(for: url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxAvail.width, maxHeight: maxAvail.height)
                    .scaleEffect(1.12)
                    .background(
                        Color.clear
                            .padding(-tolerancePadding)
                            .contentShape(Rectangle())
                    )
            }
        }
        .frame(width: cellSize, height: cellSize)
        .onAppear {
            startLoading()
        }
        .onChange(of: url) { _, _ in
            loadTask?.cancel()
            loadTask = nil
            self.thumbnail = nil
            self.isLoaded = false
            
            startLoading()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            SmartImageLoader.shared.cancel(url: url)
        }
    }
    
    // NEW: Extracted logic to support both onAppear and onChange
    private func startLoading() {
        if thumbnail != nil { return }
        
        // Check memory cache synchronously (instant, no delay needed)
        if let fast = ThumbnailCache.shared.get(url) {
            self.thumbnail = fast
            self.isLoaded = true
            return
        }
        
        // DEBOUNCE: Wait before hitting the loader.
        // If the user is scrubbing the scroll thumb, this cell will
        // disappear within ~50ms and the task gets cancelled —
        // so we never touch SmartImageLoader at all.
        loadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if Task.isCancelled { return }
            
            // Still here — user stopped scrolling near this cell, load it
            let size = CGSize(width: cellSize, height: cellSize)
            SmartImageLoader.shared.load(url: url, index: index, size: size) { img in
                // Ensure the image we just loaded still matches the URL this cell is currently showing
                // (Protects against fast scrolling cell-reuse)
                if let img = img {
                    DispatchQueue.main.async {
                        self.thumbnail = img
                        self.isLoaded = true
                    }
                }
            }
        }
    }
}

// MARK: - LAZY DIMENSION TEXT
struct LazyDimensionText: View {
    let url: URL
    @State private var dimensions: String?
    @State private var loadTask: Task<Void, Never>?
    
    var body: some View {
        Text(dimensions ?? "1920\u{200A}×\u{200A}1920")
            .onAppear {
                if let cached = DimensionCache.shared.get(url) {
                    dimensions = cached
                    return
                }
                loadTask = Task.detached(priority: .utility) {
                    let dims = ImageUtils.getDimensionString(for: url)
                    await MainActor.run {
                        if let dims = dims {
                            DimensionCache.shared.set(dims, for: url)
                        }
                        dimensions = dims
                    }
                }
            }
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
            }
    }
}

struct GridItemView: View {
    let item: CachedFile
    let index: Int
    let isSelected: Bool
    let showFileSize: Bool
    let cellSize: CGFloat
    let onSelect: (Bool) -> Void
    
    @EnvironmentObject var viewState: ViewState
    
    @State private var localImageSize = CGSize(width: 150, height: 150)
    
    var body: some View {
        Button(action: {
            if isSelected { onSelect(true) }
        }) {
            VStack(spacing: 1.5) {
                ThumbnailView(
                    url: item.imageURL,
                    index: index,
                    isSelected: isSelected,
                    cellSize: cellSize,
                    onSizeChange: { newSize in
                        localImageSize = newSize
                    }
                )
                .frame(width: cellSize, height: cellSize)
                
                // MARK: - FILENAME CONTAINER
                Text(item.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(isSelected ? .white : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color(NSColor.selectedContentBackgroundColor) : .clear)
                    )
                    .frame(width: cellSize)
                    .frame(height: 18)
                
                // MARK: - INFO TEXT CONTAINER
                Group {
                    switch viewState.activeMode {
                    case .rawBytes:
                        let raw = ImageUtils.rawByteFormatter.string(from: NSNumber(value: item.fileSize)) ?? "0"
                        Text("\(raw) B")
                            .foregroundColor(Color.orange)
                            
                    case .readableSize:
                        if viewState.isDetailed {
                            let raw = ImageUtils.rawByteFormatter.string(from: NSNumber(value: item.fileSize)) ?? "0"
                            Text("\(raw) bytes")
                                .foregroundColor(Color(nsColor: .linkColor))
                        } else {
                            Text(ImageUtils.byteFormatter.string(fromByteCount: item.fileSize))
                                .foregroundColor(Color(nsColor: .linkColor))
                        }
                        
                    case .dimensions:
                        LazyDimensionText(url: item.imageURL)
                            .foregroundColor(Color(nsColor: .linkColor))
                            
                    case .dateAdded:
                        if viewState.isDetailed {
                            Text(ImageUtils.detailedDateFormatter.string(from: item.dateAdded))
                                .foregroundColor(Color(nsColor: .linkColor))
                        } else {
                            Text(ImageUtils.dateFormatter.string(from: item.dateAdded))
                                .foregroundColor(Color(nsColor: .linkColor))
                        }
                    }
                }
                .font(.system(size: 9.75, weight: .light))
                .tracking(0.2)
                .lineLimit(1)
                .padding(.horizontal, 1.5)
                .padding(.vertical, 0)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.clear)
                )
                .frame(width: cellSize)
                .frame(height: 10)
            }
            .overlay(
                NativeContextMenu(item: item, viewState: viewState, renderedImageSize: localImageSize)
            )
        }
        .buttonStyle(InstantSelectButtonStyle(isSelected: isSelected, onPress: { onSelect(false) }))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            NSWorkspace.shared.open(item.imageURL)
        })
        .onDrag({
            onSelect(false)
            return NSItemProvider(object: item.imageURL as NSURL)
        })
    }
}

struct EquatableGridItemView: View, Equatable {
    let item: CachedFile
    let index: Int
    let isSelected: Bool
    let showFileSize: Bool
    let cellSize: CGFloat  // NEW
    let onSelect: (Bool) -> Void
    
    static func == (lhs: EquatableGridItemView, rhs: EquatableGridItemView) -> Bool {
        return lhs.isSelected == rhs.isSelected &&
               lhs.index == rhs.index &&
               lhs.item.id == rhs.item.id &&
               lhs.showFileSize == rhs.showFileSize &&
               lhs.cellSize == rhs.cellSize
    }
    
    var body: some View {
        GridItemView(item: item, index: index, isSelected: isSelected, showFileSize: showFileSize, cellSize: cellSize, onSelect: onSelect)
    }
}

// MARK: - STRING EXTENSION FOR MEASUREMENT
extension String {
    func width(font: NSFont) -> CGFloat {
        let attributes = [NSAttributedString.Key.font: font]
        let size = (self as NSString).size(withAttributes: attributes)
        return size.width
    }
}

// MARK: - SELECTION OPTIMIZATION MANAGER
class SelectionManager: ObservableObject {
    @Published var isDragging = false
    @Published var dragStart: CGPoint?
    @Published var dragCurrent: CGPoint?
    
    @Published var selectedItems: Set<URL> = []
    @Published var isAllSelected: Bool = false
    
    // The result of the drag calculation (O(1) access for views)
    @Published var dragSelectedIndices: Set<Int> = []
    
    // Layout constants
    var gridColumnsCount: Int = 1
    var itemFixedWidth: CGFloat = 180
    var actualGridSpacing: CGFloat = 24
    var sidePadding: CGFloat = 24
    var rowHeight: CGFloat = 220
    
    // Cache calculated geometry to avoid recalculating during drag
    private var geometryCache: [Int: (imageRect: CGRect, nameRect: CGRect, infoRect: CGRect)] = [:]
    
    func clearCache() {
        geometryCache.removeAll()
        dragSelectedIndices.removeAll()
    }
    
    var currentDragRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }
    
    func updateLayout(cols: Int, itemWidth: CGFloat, spacing: CGFloat, padding: CGFloat, rowHeight: CGFloat) {
        self.gridColumnsCount = cols
        self.itemFixedWidth = itemWidth
        self.actualGridSpacing = spacing
        self.sidePadding = padding
        self.rowHeight = rowHeight
    }
    
    func getFastItemFrame(index: Int) -> CGRect {
        let col = index % gridColumnsCount
        let row = index / gridColumnsCount
        
        let cellX = sidePadding + CGFloat(col) * (itemFixedWidth + actualGridSpacing)
        let cellY = 12 + CGFloat(row) * rowHeight
        
        return CGRect(x: cellX, y: cellY, width: itemFixedWidth, height: rowHeight)
    }
    
    // Precise Text Measurement Helper
    private func measure(_ text: String, font: NSFont, tracking: CGFloat = 0) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // Ceil to match pixel rendering
        return ceil(size.width)
    }
    
    func getPreciseFrames(index: Int, item: CachedFile, viewState: ViewState) -> (imageRect: CGRect, nameRect: CGRect, infoRect: CGRect) {
        if let cached = geometryCache[index] { return cached }
        
        let cellFrame = getFastItemFrame(index: index)
        let tolerance: CGFloat = 13
        
        // 1. IMAGE GEOMETRY
        // Matches ThumbnailView logic: max dimension is cellSize - 52
        let maxImgDim = max(0, itemFixedWidth - 52)
        let imageSize = ThumbnailCache.shared.get(item.imageURL)?.size ?? CGSize(width: maxImgDim, height: maxImgDim)
        
        // Calculate Aspect Fit
        let scale = min(maxImgDim / imageSize.width, maxImgDim / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        
        // Center the image within the cellSize square
        let imgX = cellFrame.minX + (itemFixedWidth - fittedSize.width) / 2
        let imgY = cellFrame.minY + (itemFixedWidth - fittedSize.height) / 2
        
        let imageRect = CGRect(origin: CGPoint(x: imgX, y: imgY), size: fittedSize)
            .insetBy(dx: -tolerance, dy: -tolerance)
        
        // 2. NAME GEOMETRY
        // Matches Text(fileName).padding(.horizontal, 6).frame(height: 18)
        let nameFont = NSFont.systemFont(ofSize: 12)
        let rawNameWidth = measure(item.fileName, font: nameFont)
        let nameWidth = min(rawNameWidth + 12, itemFixedWidth) // +12 for 6px padding on each side
        
        let nameX = cellFrame.minX + (itemFixedWidth - nameWidth) / 2
        
        // Y Position: Image Frame (cellSize) + VStack Spacing (1.5)
        let nameY = cellFrame.minY + itemFixedWidth + 1.5
        let nameRect = CGRect(x: nameX, y: nameY, width: nameWidth, height: 18)
        
        // 3. INFO GEOMETRY
        // Matches Group { ... }.padding(.horizontal, 1.5).frame(height: 10)
        let infoFont = NSFont.systemFont(ofSize: 9.75, weight: .light)
        let infoText: String
        
        switch viewState.activeMode {
        case .rawBytes:
            let raw = ImageUtils.rawByteFormatter.string(from: NSNumber(value: item.fileSize)) ?? "0"
            infoText = "\(raw) B"
        case .readableSize:
            if viewState.isDetailed {
                let raw = ImageUtils.rawByteFormatter.string(from: NSNumber(value: item.fileSize)) ?? "0"
                infoText = "\(raw) bytes"
            } else {
                infoText = ImageUtils.byteFormatter.string(fromByteCount: item.fileSize)
            }
        case .dimensions:
            infoText = DimensionCache.shared.get(item.imageURL) ?? "1920\u{200A}×\u{200A}1920"
        case .dateAdded:
            if viewState.isDetailed {
                infoText = ImageUtils.detailedDateFormatter.string(from: item.dateAdded)
            } else {
                infoText = ImageUtils.dateFormatter.string(from: item.dateAdded)
            }
        }
        
        let rawInfoWidth = measure(infoText, font: infoFont, tracking: 0.2)
        let infoWidth = min(rawInfoWidth + 3, itemFixedWidth) // +3 for 1.5px padding on each side
        
        let infoX = cellFrame.minX + (itemFixedWidth - infoWidth) / 2
        
        // Y Position: Name Y + Name Height (18) + VStack Spacing (1.5)
        let infoY = nameY + 18 + 1.5
        let infoRect = CGRect(x: infoX, y: infoY, width: infoWidth, height: 10)
        
        let result = (imageRect, nameRect, infoRect)
        geometryCache[index] = result
        return result
    }
    
    // HIGH PERFORMANCE LOOP
    func updateDragSelection(items: [CachedFile], viewState: ViewState) {
        guard let dragRect = currentDragRect else {
            if !dragSelectedIndices.isEmpty { dragSelectedIndices = [] }
            return
        }
        
        let topPadding: CGFloat = 12
        let startRow = max(0, Int((dragRect.minY - topPadding) / rowHeight))
        let endRow = Int((dragRect.maxY - topPadding) / rowHeight)
        
        let minIndex = max(0, startRow * gridColumnsCount)
        let maxIndex = min(items.count - 1, ((endRow + 1) * gridColumnsCount) - 1)
        
        if minIndex > maxIndex {
            if !dragSelectedIndices.isEmpty { dragSelectedIndices = [] }
            return
        }
        
        var newIndices = Set<Int>()
        
        for index in minIndex...maxIndex {
            // 1. Coarse Check
            let cellFrame = getFastItemFrame(index: index)
            if dragRect.intersects(cellFrame) {
                
                // 2. Precise Check (using cached geometry)
                let (imgRect, nameRect, infoRect) = getPreciseFrames(index: index, item: items[index], viewState: viewState)
                
                if dragRect.intersects(imgRect) || dragRect.intersects(nameRect) || dragRect.intersects(infoRect) {
                    newIndices.insert(index)
                }
            }
        }
        
        if dragSelectedIndices != newIndices {
            dragSelectedIndices = newIndices
        }
    }
}

// MARK: - EQUATABLE GRID WRAPPER
struct FilesGridView: View, Equatable {
    let items: [CachedFile]
    let columnCount: Int
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let sidePadding: CGFloat
    let gridContentWidth: CGFloat?
    let cellSize: CGFloat
    
    @ObservedObject var selectionManager: SelectionManager
    
    let onSelect: (CachedFile, Bool) -> Void
    
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: columnSpacing), count: columnCount)
    }
    
    static func == (lhs: FilesGridView, rhs: FilesGridView) -> Bool {
        return lhs.items == rhs.items &&
               lhs.columnCount == rhs.columnCount &&
               lhs.columnSpacing == rhs.columnSpacing &&
               lhs.gridContentWidth == rhs.gridContentWidth &&
               lhs.sidePadding == rhs.sidePadding &&
               lhs.rowSpacing == rhs.rowSpacing &&
               lhs.cellSize == rhs.cellSize
    }
    
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: rowSpacing) {
            ForEach(0..<items.count, id: \.self) { index in
                SmartGridItem(
                    item: items[index],
                    index: index,
                    manager: selectionManager,
                    cellSize: cellSize,
                    onSelect: onSelect
                )
            }
        }
        .padding(.horizontal, sidePadding)
        .padding(.bottom, 42)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading) // Force leading alignment
        .frame(width: gridContentWidth)
    }
}

// MARK: - SMART GRID ITEM
struct SmartGridItem: View {
    let item: CachedFile
    let index: Int
    @ObservedObject var manager: SelectionManager
    let cellSize: CGFloat
    let onSelect: (CachedFile, Bool) -> Void
    
    @EnvironmentObject var viewState: ViewState
    
    private var isDragSelected: Bool {
        // FAST: Lookup in Set
        return manager.dragSelectedIndices.contains(index)
    }
    
    var body: some View {
        let externalIsSelected = manager.isAllSelected || manager.selectedItems.contains(item.imageURL)
        let finalSelected = externalIsSelected || isDragSelected
        
        return EquatableGridItemView(
            item: item,
            index: index,
            isSelected: finalSelected,
            showFileSize: viewState.showFileSize,
            cellSize: cellSize,
            onSelect: { isClick in onSelect(item, isClick) }
        )
    }
}

// MARK: - MAIN CONTENT VIEW
struct ContentView: View {
    @StateObject private var searcher = InMemorySearcher()
    @StateObject private var scrollHandler = AutoScrollHandler()
    @StateObject private var keyboardHandler = KeyboardHandler()
    
    @StateObject private var selectionManager = SelectionManager()
    
    @StateObject private var viewState = ViewState()
    
    @State private var searchText = ""
    
    @State private var isPanelOpen = false
    @State private var panelWidth: CGFloat = 350
    
    @State private var previousIsAllSelected = false
    @State private var previousSelection: Set<URL> = []
    
    let itemFixedWidth: CGFloat = 180
    let rowSpacing: CGFloat = 36
    let minPadding: CGFloat = 24
    private let minPanelWidth: CGFloat = 300
    
    @State private var gridColumnsCount: Int = 1
    @State private var actualGridSpacing: CGFloat = 24
    @State private var sidePadding: CGFloat = 24
    @State private var rowHeight: CGFloat = 220
    @State private var gridContentWidth: CGFloat? = nil
    
    private var baseMinimumWidth: CGFloat {
        itemFixedWidth + (minPadding * 2) + 20
    }
    
    private var minimumWidthWithPanel: CGFloat {
        baseMinimumWidth + minPanelWidth
    }
    
    private var minimumWindowWidth: CGFloat {
        isPanelOpen ? minimumWidthWithPanel : baseMinimumWidth
    }
    
    private var selectionCount: Int {
        selectionManager.isAllSelected ? searcher.filteredResults.count : selectionManager.selectedItems.count
    }
    
    private var firstSelectedURL: URL? {
        if selectionManager.isAllSelected {
            return searcher.filteredResults.first?.imageURL
        }
        return selectionManager.selectedItems.first
    }
    
    private func materializeSelection() -> Set<URL> {
        if selectionManager.isAllSelected {
            return Set(searcher.filteredResults.map { $0.imageURL })
        }
        return selectionManager.selectedItems
    }
    
    private func clearSelection() {
        selectionManager.isAllSelected = false
        selectionManager.selectedItems.removeAll()
    }

    var body: some View {
        GeometryReader { windowGeo in
            
            let minGridWidth: CGFloat = itemFixedWidth + (minPadding * 2) + 1
            let dynamicMaxPanelWidth = max(minPanelWidth, windowGeo.size.width - minGridWidth)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Button(action: searcher.selectFolder) {
                            Label(searcher.isIndexing ? "Indexing..." : "Select Folder", systemImage: "folder.badge.gear")
                        }
                        .disabled(searcher.isIndexing)
                        
                        Divider().frame(height: 24)
                        
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(.gray)
                            TextField("Search...", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .onChange(of: searchText) { _, newValue in
                            searcher.performSearch(text: newValue)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    if searcher.isIndexing {
                        ProgressView(value: searcher.progress)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                    
                    HStack {
                        Text(searcher.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(selectionCount) Selected / \(searcher.filteredResults.count) Total")
                            .font(.caption)
                            .fontWeight(.bold)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    AnimatableWidthReader(targetWidth: windowGeo.size.width - (isPanelOpen ? (panelWidth + 1) : 0)) { animatedWidth in
                        ScrollView {
                            ZStack(alignment: .topLeading) {
                                ClickThroughBackground(
                                    sortOrder: searcher.sortOrder,
                                    displayMode: viewState.displayMode, // Pass the display mode
                                    onSortOrderChanged: { newOrder in
                                        // Only change the sort order, do NOT change displayMode here
                                        searcher.sortOrder = newOrder
                                        searcher.applySort()
                                    },
                                    onDisplayModeChanged: { newMode in
                                        // Handle the "Show Item Info" change manually
                                        viewState.displayMode = newMode
                                        // Clear geometry cache because text width might change
                                        selectionManager.clearCache()
                                    }
                                )
                                .frame(maxWidth: .infinity, minHeight: 800)
                                .onTapGesture { clearSelection() }
                                
                                FilesGridView(
                                    items: searcher.filteredResults,
                                    columnCount: gridColumnsCount,
                                    columnSpacing: actualGridSpacing,
                                    rowSpacing: rowSpacing,
                                    sidePadding: sidePadding,
                                    gridContentWidth: gridContentWidth,
                                    cellSize: itemFixedWidth,
                                    selectionManager: selectionManager,
                                    onSelect: handleItemSelection
                                )
                                .environmentObject(viewState)
                                .environmentObject(selectionManager)
                                
                                // Selection Rectangle
                                if let start = selectionManager.dragStart, let current = selectionManager.dragCurrent {
                                    let rect = CGRect.from(start, current)
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.1))
                                        .border(Color.primary.opacity(0.3), width: 1)
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .coordinateSpace(name: "GridSpace")
                            .background(ScrollViewAccessor { scrollHandler.connect(scrollView: $0) })
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("GridSpace"))
                                    .onChanged { value in
                                        if !selectionManager.isDragging {
                                            selectionManager.isDragging = true
                                            selectionManager.dragStart = value.startLocation
                                            
                                            let modifiers = NSEvent.modifierFlags
                                            if !modifiers.intersection([.command, .shift]).isEmpty {
                                                previousIsAllSelected = selectionManager.isAllSelected
                                                previousSelection = selectionManager.selectedItems
                                            } else {
                                                clearSelection()
                                                previousIsAllSelected = false
                                                previousSelection = []
                                            }
                                        }
                                        selectionManager.dragCurrent = value.location
                                        
                                        // UPDATED CALL: Pass items AND viewState
                                        selectionManager.updateDragSelection(items: searcher.filteredResults, viewState: viewState)
                                        
                                        scrollHandler.processDragLocation(NSEvent.mouseLocation)
                                    }
                                    .onEnded { _ in
                                        finalizeDragSelection()
                                    }
                            )
                        }
                        .frame(width: animatedWidth)
                        .onChange(of: animatedWidth) { _, newW in
                            recalcLayout(width: newW)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                ResizablePanelView(
                    isOpen: $isPanelOpen,
                    panelWidth: $panelWidth,
                    selectionCount: selectionCount,
                    firstSelectedURL: firstSelectedURL,
                    getFullSelection: materializeSelection,
                    maxAllowedWidth: dynamicMaxPanelWidth
                )
            }
            .animation(.easeInOut(duration: 0.25), value: isPanelOpen)
            .onChange(of: searcher.filteredResults) { _, _ in
                // Clear cache on filter/sort change so indices don't mismatch
                selectionManager.clearCache()
                recalcLayout(width: windowGeo.size.width - (isPanelOpen ? (panelWidth + 1) : 0))
            }
            .onChange(of: searcher.selectedFolder) { _, _ in
                clearSelection()
                selectionManager.clearCache()
            }
            .onChange(of: windowGeo.size.width) { _, newWindowWidth in
                let currentMax = newWindowWidth - minGridWidth
                if isPanelOpen && panelWidth > currentMax {
                    panelWidth = max(minPanelWidth, currentMax)
                }
                
                recalcLayout(width: newWindowWidth - (isPanelOpen ? (panelWidth + 1) : 0))
            }
            .onAppear {
                isPanelOpen = UserDefaults.standard.bool(forKey: "InspectorOpen")
                
                if let saved = UserDefaults.standard.value(forKey: "InspectorWidth") as? CGFloat {
                    panelWidth = min(max(saved, minPanelWidth), dynamicMaxPanelWidth)
                }
                
                recalcLayout(width: windowGeo.size.width - (isPanelOpen ? (panelWidth + 1) : 0))
                
                scrollHandler.onScroll = { point in
                    self.selectionManager.dragCurrent = point
                }
                
                // NEW: recalculate drag selection after each auto-scroll frame
                scrollHandler.onScrollSelectionUpdate = { [selectionManager, searcher, viewState] in
                    selectionManager.updateDragSelection(items: searcher.filteredResults, viewState: viewState)
                }
                
                scrollHandler.prefetchContext = AutoScrollHandler.PrefetchContext(
                    getItems: { [searcher] in searcher.filteredResults },
                    gridColumnsCount: { [weak selectionManager] in selectionManager?.gridColumnsCount ?? 1 },
                    rowHeight: { [weak selectionManager] in selectionManager?.rowHeight ?? 220 },
                    cellSize: itemFixedWidth,
                    prefetchRowCount: 3
                )
                
                keyboardHandler.start()
                
                NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    DispatchQueue.main.async {
                        let meaningful = event.modifierFlags.intersection([.option, .command, .shift])
                        if viewState.currentModifiers != meaningful {
                            viewState.currentModifiers = meaningful
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                keyboardHandler.stop()
            }
            .onChange(of: keyboardHandler.selectAllTriggered) { _, triggered in
                if triggered {
                    selectAllItems()
                    keyboardHandler.selectAllTriggered = false
                }
            }
            .onChange(of: panelWidth) { _, newW in
                UserDefaults.standard.set(newW, forKey: "InspectorWidth")
            }
            .onChange(of: isPanelOpen) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "InspectorOpen")
            }
        }
        .background(WindowAccessor(representedURL: searcher.selectedFolder))
        .frame(minWidth: minimumWindowWidth, minHeight: 200)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(action: { searcher.goBack() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!searcher.canGoBack || searcher.isIndexing)
                    .help("Back")
                    .keyboardShortcut("[", modifiers: .command)
                    
                    Button(action: { searcher.goForward() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!searcher.canGoForward || searcher.isIndexing)
                    .help("Forward")
                    .keyboardShortcut("]", modifiers: .command)
                }
                .controlGroupStyle(.navigation)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleInspectorPanel) {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
    
    private func toggleInspectorPanel() {
        if isPanelOpen {
            withAnimation(.easeInOut(duration: 0.25)) {
                isPanelOpen = false
            }
        } else {
            openPanelWithScreenCheck()
        }
    }
    
    private func openPanelWithScreenCheck() {
        guard let window = NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else {
            withAnimation(.easeInOut(duration: 0.25)) { isPanelOpen = true }
            return
        }
        
        let screenFrame = screen.visibleFrame
        var newFrame = window.frame
        let requiredWidth = minimumWidthWithPanel
        
        if newFrame.width < requiredWidth {
            newFrame.size.width = requiredWidth
        }
        
        if newFrame.maxX > screenFrame.maxX {
            newFrame.origin.x = screenFrame.maxX - newFrame.width
        }
        
        if newFrame.origin.x < screenFrame.minX {
            newFrame.origin.x = screenFrame.minX
            if newFrame.width > screenFrame.width {
                newFrame.size.width = screenFrame.width
            }
        }
        
        if newFrame != window.frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }
        }
        
        withAnimation(.easeInOut(duration: 0.25)) {
            isPanelOpen = true
        }
    }
    
    private func recalcLayout(width: CGFloat) {
        // 1. Setup available space
        // We subtract 20 to account for the scrollbar/safe area, ensuring
        // the layout fits comfortably without horizontal scrolling.
        let availableWidth = width - 20
        let minTotalSidePadding = minPadding * 2
        
        // 2. Calculate columns
        let maxPossibleColumns = max(1, Int((availableWidth - minTotalSidePadding + minPadding) / (itemFixedWidth + minPadding)))
        let totalItems = searcher.filteredResults.count

        if totalItems > 0 && totalItems <= maxPossibleColumns {
            // Case A: Few items (Everything fits in one row or less than max cols)
            gridColumnsCount = totalItems
            sidePadding = minPadding
            actualGridSpacing = minPadding
            
            let gaps = max(0, CGFloat(totalItems - 1))
            let requiredWidth = (CGFloat(totalItems) * itemFixedWidth) + (gaps * minPadding) + minTotalSidePadding
            
            gridContentWidth = requiredWidth
            
        } else {
            // Case B: Fill the width
            gridColumnsCount = maxPossibleColumns
            gridContentWidth = nil
            
            let totalItemsWidth = CGFloat(gridColumnsCount) * itemFixedWidth
            let remainingSpace = availableWidth - totalItemsWidth
            let numberOfGaps = CGFloat(gridColumnsCount + 1)
            
            // FIX: Removed floor() to restore smooth resize animation.
            // SwiftUI handles sub-pixel rendering gracefully; snapping to integers
            // causes the grid to "jump" discontinuously during resize.
            let spacePerGap = remainingSpace / numberOfGaps
            
            sidePadding = spacePerGap
            actualGridSpacing = spacePerGap
        }
        
        // 3. Update Height and Selection Manager
        let textStackHeight: CGFloat = 31.0
        rowHeight = itemFixedWidth + textStackHeight + rowSpacing
        
        // Update the manager so it knows where items are for drag-selection
        selectionManager.updateLayout(
            cols: gridColumnsCount,
            itemWidth: itemFixedWidth,
            spacing: actualGridSpacing,
            padding: sidePadding,
            rowHeight: rowHeight
        )
    }

    private func handleItemSelection(item: CachedFile, isClick: Bool) {
        let flags = NSEvent.modifierFlags
        
        if flags.contains(.command) {
            if selectionManager.isAllSelected {
                selectionManager.selectedItems = Set(searcher.filteredResults.map { $0.imageURL })
                selectionManager.selectedItems.remove(item.imageURL)
                selectionManager.isAllSelected = false
            } else {
                selectionManager.selectedItems.formSymmetricDifference([item.imageURL])
            }
        } else if flags.contains(.shift) {
            if !selectionManager.isAllSelected {
                selectionManager.selectedItems.insert(item.imageURL)
            }
        } else if !isClick {
            selectionManager.isAllSelected = false
            selectionManager.selectedItems = [item.imageURL]
        }
    }

    private func finalizeDragSelection() {
        guard selectionManager.isDragging else { return }
        
        let wasPreviouslyAllSelected = previousIsAllSelected
        let currentPreviousSelection = previousSelection
        
        // Use the calculated indices from Manager
        let finalIndices = selectionManager.dragSelectedIndices
        
        // Reset State
        selectionManager.isDragging = false
        selectionManager.dragStart = nil
        selectionManager.dragCurrent = nil
        selectionManager.dragSelectedIndices.removeAll()
        
        previousIsAllSelected = false
        previousSelection = []
        scrollHandler.stopTimer()
        
        if wasPreviouslyAllSelected {
            selectionManager.isAllSelected = true
            selectionManager.selectedItems.removeAll()
            return
        }
        
        var newSelection = currentPreviousSelection
        
        for index in finalIndices {
            if index < searcher.filteredResults.count {
                newSelection.insert(searcher.filteredResults[index].imageURL)
            }
        }
        
        selectionManager.selectedItems = newSelection
        selectionManager.isAllSelected = false
    }
    
    private func selectAllItems() {
        selectionManager.isAllSelected = true
        selectionManager.selectedItems.removeAll()
    }
}

// MARK: - EXTENSIONS
extension CGRect {
    static func from(_ p1: CGPoint, _ p2: CGPoint) -> CGRect {
        return CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p1.x - p2.x),
            height: abs(p1.y - p2.y)
        )
    }
}

// MARK: - NATIVE CONTEXT MENU BRIDGE
struct NativeContextMenu: NSViewRepresentable {
    let item: CachedFile
    @ObservedObject var viewState: ViewState
    let renderedImageSize: CGSize
    
    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.coordinator = context.coordinator
        return view
    }
    
    func updateNSView(_ view: RightClickView, context: Context) {
        view.item = item
        view.viewState = viewState
        view.renderedImageSize = renderedImageSize
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        var parentViewState: ViewState?
        var currentItem: CachedFile?
        
        @objc func showInFinder() {
            guard let url = currentItem?.imageURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        
        @objc func revealMetadata() {
            guard let url = currentItem?.imageURL else { return }
            if let jsonURL = SidecarManager.shared.jsonURL(for: url),
               FileManager.default.fileExists(atPath: jsonURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([jsonURL])
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
        }
    }
    
    class RightClickView: NSView {
        var item: CachedFile?
        var viewState: ViewState?
        var coordinator: Coordinator?
        var renderedImageSize: CGSize = .zero

        override var isFlipped: Bool { true }

        private func makeIcon(_ name: String) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = self.convert(point, from: self.superview)
            guard self.bounds.contains(localPoint) else { return nil }

            let event = NSApp.currentEvent
            guard event?.type == .rightMouseDown ||
                  (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true) else {
                return nil
            }

            let tolerance: CGFloat = 13
            let textStackHeight: CGFloat = 31.0
            let imageSquareHeight = bounds.height - textStackHeight

            let imgRect = CGRect(
                x: (bounds.width - renderedImageSize.width) / 2 - tolerance,
                y: (imageSquareHeight - renderedImageSize.height) / 2 - tolerance,
                width: renderedImageSize.width + tolerance * 2,
                height: renderedImageSize.height + tolerance * 2
            )

            let textRect = CGRect(
                x: 0,
                y: imageSquareHeight,
                width: bounds.width,
                height: textStackHeight
            )

            guard imgRect.contains(localPoint) || textRect.contains(localPoint) else { return nil }

            return self
        }
        
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let item = item, let viewState = viewState else { return nil }
            
            coordinator?.parentViewState = viewState
            coordinator?.currentItem = item
            
            let menu = NSMenu()
            
            let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(Coordinator.showInFinder), keyEquivalent: "")
            finderItem.target = coordinator
            finderItem.image = makeIcon("folder")
            menu.addItem(finderItem)
            
            let metaItem = NSMenuItem(title: "Reveal Metadata JSON", action: #selector(Coordinator.revealMetadata), keyEquivalent: "")
            metaItem.target = coordinator
            metaItem.image = makeIcon("doc.text")
            menu.addItem(metaItem)
            
            return menu
        }
    }
}

extension CGSize {
    func aspectFitted(to max: CGSize) -> CGSize {
        let scale = min(max.width / self.width, max.height / self.height)
        return CGSize(width: self.width * scale, height: self.height * scale)
    }
}

@main
struct BinderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
