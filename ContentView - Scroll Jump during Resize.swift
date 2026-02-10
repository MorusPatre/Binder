import Cocoa
import UniformTypeIdentifiers

// MARK: - App Entry Point

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var finderController: FinderWindowController!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        finderController = FinderWindowController()
        finderController.showWindow(nil)
        window = finderController.window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func setupMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Finder Clone", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "New Folder", action: #selector(FinderViewController.createNewFolder), keyEquivalent: "N")
        fileMenu.addItem(withTitle: "Delete", action: #selector(FinderViewController.deleteSelected), keyEquivalent: "\u{8}")
        fileMenu.addItem(withTitle: "Get Info", action: #selector(FinderViewController.getInfo), keyEquivalent: "i")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(FinderViewController.copySelected), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(FinderViewController.pasteItems), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(FinderViewController.selectAllItems), keyEquivalent: "a")

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "as Icons", action: #selector(FinderViewController.viewAsIcons), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "as List", action: #selector(FinderViewController.viewAsList), keyEquivalent: "2")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Show Hidden Files", action: #selector(FinderViewController.toggleHiddenFiles), keyEquivalent: ".")

        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu
        goMenu.addItem(withTitle: "Back", action: #selector(FinderViewController.goBack), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward", action: #selector(FinderViewController.goForward), keyEquivalent: "]")
        goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(FinderViewController.goUp), keyEquivalent: "\u{1b}")
        goMenu.addItem(NSMenuItem.separator())
        goMenu.addItem(withTitle: "Home", action: #selector(FinderViewController.goHome), keyEquivalent: "H")
        goMenu.addItem(withTitle: "Desktop", action: #selector(FinderViewController.goDesktop), keyEquivalent: "D")
        goMenu.addItem(withTitle: "Documents", action: #selector(FinderViewController.goDocuments), keyEquivalent: "O")
        goMenu.addItem(withTitle: "Downloads", action: #selector(FinderViewController.goDownloads), keyEquivalent: "L")
        goMenu.addItem(NSMenuItem.separator())
        goMenu.addItem(withTitle: "Go to Folder…", action: #selector(FinderViewController.goToFolder), keyEquivalent: "G")

        NSApp.mainMenu = mainMenu
    }

    @objc func newWindow() {
        let controller = FinderWindowController()
        controller.showWindow(nil)
    }

    @objc func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

// MARK: - File Item Model

struct FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    let size: Int64
    let modificationDate: Date
    let icon: NSImage

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let resourceValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isHiddenKey, .fileSizeKey,
            .contentModificationDateKey, .effectiveIconKey
        ])

        self.isDirectory = resourceValues?.isDirectory ?? false
        self.isHidden = resourceValues?.isHidden ?? url.lastPathComponent.hasPrefix(".")
        self.size = Int64(resourceValues?.fileSize ?? 0)
        self.modificationDate = resourceValues?.contentModificationDate ?? Date()
        self.icon = (resourceValues?.effectiveIcon as? NSImage) ?? NSWorkspace.shared.icon(for: UTType.data)
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }

    var kindDescription: String {
        if isDirectory { return "Folder" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift": return "Swift Source"
        case "py": return "Python Script"
        case "js": return "JavaScript"
        case "txt": return "Plain Text"
        case "pdf": return "PDF Document"
        case "png", "jpg", "jpeg", "gif", "tiff": return "Image"
        case "mp3", "wav", "aac", "m4a": return "Audio"
        case "mp4", "mov", "avi": return "Video"
        case "zip", "tar", "gz": return "Archive"
        case "app": return "Application"
        case "dmg": return "Disk Image"
        default: return ext.isEmpty ? "Document" : "\(ext.uppercased()) File"
        }
    }
}

// MARK: - View Mode

enum ViewMode {
    case icon
    case list
}

// MARK: - Finder Window Controller

class FinderWindowController: NSWindowController {
    convenience init() {
        let viewController = FinderViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Finder Clone"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.contentViewController = viewController
        window.center()
        window.setFrameAutosaveName("FinderCloneWindow")
        window.minSize = NSSize(width: 600, height: 400)
        window.isMovableByWindowBackground = false
        window.toolbar = viewController.createToolbar()

        self.init(window: window)
    }
}

// MARK: - Finder View Controller

class FinderViewController: NSViewController {
    // Views
    var splitView: NSSplitView!
    var sidebarScrollView: NSScrollView!
    var sidebarOutlineView: NSOutlineView!
    var contentView: NSView!
    var collectionScrollView: NSScrollView!
    var collectionView: NSCollectionView!
    var tableScrollView: NSScrollView!
    var tableView: NSTableView!
    var pathControl: NSPathControl!
    var statusBar: NSTextField!
    var searchField: NSSearchField!
    var rightContainer: NSView!

    // State
    var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var items: [FileItem] = []
    var filteredItems: [FileItem] = []
    var viewMode: ViewMode = .icon
    var showHiddenFiles = false
    var navigationHistory: [URL] = []
    var navigationIndex = -1
    var clipboard: [URL] = []
    var searchText = ""

    // Sidebar items
    struct SidebarItem {
        let name: String
        let icon: NSImage
        let url: URL?
        var children: [SidebarItem]
        var isHeader: Bool

        init(name: String, icon: NSImage, url: URL?, children: [SidebarItem] = [], isHeader: Bool = false) {
            self.name = name
            self.icon = icon
            self.url = url
            self.children = children
            self.isHeader = isHeader
        }
    }

    var sidebarItems: [SidebarItem] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSidebarItems()
        setupUI()
        navigateTo(currentURL)
    }

    // MARK: - Sidebar Items Setup

    func setupSidebarItems() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let favIcon = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) ?? NSImage()
        let desktopIcon = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil) ?? NSImage()
        let docIcon = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil) ?? NSImage()
        let downIcon = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil) ?? NSImage()
        let homeIcon = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil) ?? NSImage()
        let appIcon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
        let musicIcon = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage()
        let picIcon = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil) ?? NSImage()
        let movieIcon = NSImage(systemSymbolName: "film.fill", accessibilityDescription: nil) ?? NSImage()

        let favorites = SidebarItem(name: "Favorites", icon: favIcon, url: nil, children: [
            SidebarItem(name: "Desktop", icon: desktopIcon, url: home.appendingPathComponent("Desktop")),
            SidebarItem(name: "Documents", icon: docIcon, url: home.appendingPathComponent("Documents")),
            SidebarItem(name: "Downloads", icon: downIcon, url: home.appendingPathComponent("Downloads")),
            SidebarItem(name: "Home", icon: homeIcon, url: home),
            SidebarItem(name: "Applications", icon: appIcon, url: URL(fileURLWithPath: "/Applications")),
            SidebarItem(name: "Music", icon: musicIcon, url: home.appendingPathComponent("Music")),
            SidebarItem(name: "Pictures", icon: picIcon, url: home.appendingPathComponent("Pictures")),
            SidebarItem(name: "Movies", icon: movieIcon, url: home.appendingPathComponent("Movies")),
        ], isHeader: true)

        let diskIcon = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil) ?? NSImage()
        let macName = Host.current().localizedName ?? "My Mac"
        let locations = SidebarItem(name: "Locations", icon: diskIcon, url: nil, children: [
            SidebarItem(name: macName, icon: diskIcon, url: URL(fileURLWithPath: "/")),
        ], isHeader: true)

        sidebarItems = [favorites, locations]
    }

    // MARK: - UI Setup

    func setupUI() {
        // Main split view
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)

        // Sidebar
        setupSidebar()

        // Content area (right side)
        rightContainer = NSView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false

        setupCollectionView()
        setupTableView()
        setupPathControl()
        setupStatusBar()

        rightContainer.addSubview(collectionScrollView)
        rightContainer.addSubview(tableScrollView)
        rightContainer.addSubview(pathControl)
        rightContainer.addSubview(statusBar)

        collectionScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: rightContainer.topAnchor, constant: 4),
            pathControl.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor, constant: -8),
            pathControl.heightAnchor.constraint(equalToConstant: 24),

            collectionScrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 4),
            collectionScrollView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            collectionScrollView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            collectionScrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            tableScrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 4),
            tableScrollView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        splitView.addArrangedSubview(sidebarScrollView)
        splitView.addArrangedSubview(rightContainer)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Set holding priorities so the RIGHT side (content) keeps its size when resizing,
        // and the LEFT side (sidebar) is the one that adjusts
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)   // right keeps size
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)    // left adjusts

        // Set initial sidebar position after layout
        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(200, ofDividerAt: 0)
        }

        updateViewMode()
    }

    func setupSidebar() {
        sidebarOutlineView = NSOutlineView()
        sidebarOutlineView.headerView = nil
        sidebarOutlineView.indentationPerLevel = 14
        sidebarOutlineView.rowSizeStyle = .default
        sidebarOutlineView.floatsGroupRows = false
        sidebarOutlineView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.isEditable = false
        sidebarOutlineView.addTableColumn(column)
        sidebarOutlineView.outlineTableColumn = column

        sidebarOutlineView.delegate = self
        sidebarOutlineView.dataSource = self

        sidebarScrollView = NSScrollView()
        sidebarScrollView.documentView = sidebarOutlineView
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.autohidesScrollers = true
        sidebarScrollView.drawsBackground = false
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Give the sidebar a fixed width constraint that can be overridden by the split view dragging
        let widthConstraint = sidebarScrollView.widthAnchor.constraint(equalToConstant: 200)
        widthConstraint.priority = .defaultLow  // low priority so split view divider wins
        widthConstraint.isActive = true

        // Expand all headers
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for item in self.sidebarItems {
                self.sidebarOutlineView.expandItem(item.name)
            }
        }
    }

    func setupCollectionView() {
        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.itemSize = NSSize(width: 100, height: 100)
        flowLayout.minimumInteritemSpacing = 10
        flowLayout.minimumLineSpacing = 10
        flowLayout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.dataSource = self

        collectionView.register(FileCollectionViewItem.self,
                                forItemWithIdentifier: NSUserInterfaceItemIdentifier("FileCell"))

        collectionScrollView = NSScrollView()
        collectionScrollView.documentView = collectionView
        collectionScrollView.hasVerticalScroller = true
        collectionScrollView.autohidesScrollers = true
        collectionScrollView.drawsBackground = true
        collectionScrollView.backgroundColor = .controlBackgroundColor
    }

    func setupTableView() {
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowSizeStyle = .small
        tableView.style = .fullWidth
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(tableViewDoubleClick)
        tableView.target = self

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameCol.title = "Name"
        nameCol.width = 250
        nameCol.minWidth = 120
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        tableView.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        dateCol.title = "Date Modified"
        dateCol.width = 160
        dateCol.minWidth = 100
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        tableView.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        tableView.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Kind"))
        kindCol.title = "Kind"
        kindCol.width = 120
        kindCol.minWidth = 80
        kindCol.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        tableView.addTableColumn(kindCol)

        tableScrollView = NSScrollView()
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.drawsBackground = true
    }

    func setupPathControl() {
        pathControl = NSPathControl()
        pathControl.pathStyle = .standard
        pathControl.backgroundColor = .clear
        pathControl.url = currentURL
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked)
        pathControl.doubleAction = #selector(pathControlDoubleClicked)
    }

    func setupStatusBar() {
        statusBar = NSTextField(labelWithString: "")
        statusBar.font = NSFont.systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        statusBar.alignment = .left
    }

    // MARK: - Toolbar

    func createToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "FinderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    // MARK: - Navigation

    func navigateTo(_ url: URL) {
        currentURL = url

        // Update history
        if navigationIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory[0...navigationIndex])
        }
        navigationHistory.append(url)
        navigationIndex = navigationHistory.count - 1

        loadContents()
        updateTitle()
        pathControl?.url = url
    }

    func loadContents() {
        let fm = FileManager.default
        items = []

        do {
            let urls = try fm.contentsOfDirectory(at: currentURL,
                                                   includingPropertiesForKeys: [
                                                       .isDirectoryKey, .isHiddenKey, .fileSizeKey,
                                                       .contentModificationDateKey, .effectiveIconKey
                                                   ],
                                                   options: showHiddenFiles ? [] : [.skipsHiddenFiles])
            items = urls.map { FileItem(url: $0) }
            sortItems()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot access folder"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }

        applyFilter()
    }

    func sortItems() {
        // Folders first, then alphabetical
        items.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func applyFilter() {
        if searchText.isEmpty {
            filteredItems = items
        } else {
            filteredItems = items.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        collectionView?.reloadData()
        tableView?.reloadData()
        updateStatusBar()
    }

    func updateTitle() {
        view.window?.title = currentURL.lastPathComponent.isEmpty ? "/" : currentURL.lastPathComponent
        view.window?.representedURL = currentURL
    }

    func updateStatusBar() {
        let count = filteredItems.count
        let selected = viewMode == .icon
            ? collectionView.selectionIndexPaths.count
            : tableView.selectedRowIndexes.count
        var text = "\(count) item\(count == 1 ? "" : "s")"
        if selected > 0 {
            text += ", \(selected) selected"
        }
        statusBar.stringValue = text
    }

    func updateViewMode() {
        switch viewMode {
        case .icon:
            collectionScrollView.isHidden = false
            tableScrollView.isHidden = true
            collectionView.reloadData()
        case .list:
            collectionScrollView.isHidden = true
            tableScrollView.isHidden = false
            tableView.reloadData()
        }
    }

    func openItem(_ item: FileItem) {
        if item.isDirectory {
            navigateTo(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func selectedItems() -> [FileItem] {
        switch viewMode {
        case .icon:
            return collectionView.selectionIndexPaths.compactMap { indexPath in
                let idx = indexPath.item
                guard idx < filteredItems.count else { return nil }
                return filteredItems[idx]
            }
        case .list:
            return tableView.selectedRowIndexes.compactMap { idx in
                guard idx < filteredItems.count else { return nil }
                return filteredItems[idx]
            }
        }
    }

    // MARK: - Actions

    @objc func goBack(_ sender: Any?) {
        guard navigationIndex > 0 else { return }
        navigationIndex -= 1
        currentURL = navigationHistory[navigationIndex]
        loadContents()
        updateTitle()
        pathControl?.url = currentURL
    }

    @objc func goForward(_ sender: Any?) {
        guard navigationIndex < navigationHistory.count - 1 else { return }
        navigationIndex += 1
        currentURL = navigationHistory[navigationIndex]
        loadContents()
        updateTitle()
        pathControl?.url = currentURL
    }

    @objc func goUp(_ sender: Any?) {
        let parent = currentURL.deletingLastPathComponent()
        if parent != currentURL {
            navigateTo(parent)
        }
    }

    @objc func goHome(_ sender: Any?) {
        navigateTo(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func goDesktop(_ sender: Any?) {
        navigateTo(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    }

    @objc func goDocuments(_ sender: Any?) {
        navigateTo(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
    }

    @objc func goDownloads(_ sender: Any?) {
        navigateTo(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    }

    @objc func goToFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Enter the path of the folder you want to open:"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = currentURL.path
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let path = (input.stringValue as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                navigateTo(url)
            } else {
                let err = NSAlert()
                err.messageText = "Folder not found"
                err.informativeText = "The folder \"\(path)\" doesn't exist."
                err.runModal()
            }
        }
    }

    @objc func viewAsIcons(_ sender: Any?) {
        viewMode = .icon
        updateViewMode()
    }

    @objc func viewAsList(_ sender: Any?) {
        viewMode = .list
        updateViewMode()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        showHiddenFiles.toggle()
        loadContents()
    }

    @objc func createNewFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = "untitled folder"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.isEmpty ? "untitled folder" : input.stringValue
            let newURL = currentURL.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
                loadContents()
            } catch {
                let err = NSAlert(error: error)
                err.runModal()
            }
        }
    }

    @objc func deleteSelected(_ sender: Any?) {
        let selected = selectedItems()
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Trash?"
        alert.informativeText = "Are you sure you want to move \(selected.count) item\(selected.count == 1 ? "" : "s") to the Trash?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            for item in selected {
                do {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                } catch {
                    let err = NSAlert(error: error)
                    err.runModal()
                }
            }
            loadContents()
        }
    }

    @objc func copySelected(_ sender: Any?) {
        let selected = selectedItems()
        guard !selected.isEmpty else { return }
        clipboard = selected.map { $0.url }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(clipboard.map { $0 as NSURL } as [NSPasteboardWriting])
    }

    @objc func pasteItems(_ sender: Any?) {
        guard !clipboard.isEmpty else { return }
        let fm = FileManager.default
        for url in clipboard {
            let dest = currentURL.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    // Generate unique name
                    let name = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    var counter = 2
                    var newDest = dest
                    while fm.fileExists(atPath: newDest.path) {
                        let newName = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
                        newDest = currentURL.appendingPathComponent(newName)
                        counter += 1
                    }
                    try fm.copyItem(at: url, to: newDest)
                } else {
                    try fm.copyItem(at: url, to: dest)
                }
            } catch {
                let err = NSAlert(error: error)
                err.runModal()
            }
        }
        loadContents()
    }

    @objc func selectAllItems(_ sender: Any?) {
        switch viewMode {
        case .icon:
            let allPaths = Set((0..<filteredItems.count).map { IndexPath(item: $0, section: 0) })
            collectionView.selectionIndexPaths = allPaths
        case .list:
            tableView.selectAll(nil)
        }
        updateStatusBar()
    }

    @objc func getInfo(_ sender: Any?) {
        let selected = selectedItems()
        guard let item = selected.first else { return }

        let alert = NSAlert()
        alert.messageText = item.name
        alert.icon = item.icon

        var info = "Kind: \(item.kindDescription)\n"
        info += "Size: \(item.formattedSize)\n"
        info += "Modified: \(item.formattedDate)\n"
        info += "Path: \(item.url.path)"

        if item.isDirectory {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: item.url.path)
            info += "\nContents: \(contents?.count ?? 0) items"
        }

        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open in Finder")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    @objc func pathControlClicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url {
            navigateTo(url)
        }
    }

    @objc func pathControlDoubleClicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url {
            navigateTo(url)
        }
    }

    @objc func tableViewDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredItems.count else { return }
        openItem(filteredItems[row])
    }

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        applyFilter()
    }

    // MARK: - Context Menu

    func buildContextMenu(for items: [FileItem]) -> NSMenu {
        let menu = NSMenu()

        if items.isEmpty {
            menu.addItem(withTitle: "New Folder", action: #selector(createNewFolder), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Paste", action: #selector(pasteItems), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Get Info", action: #selector(getInfo), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Open", action: #selector(openSelectedFromMenu), keyEquivalent: "")
            if items.count == 1 {
                menu.addItem(withTitle: "Open With…", action: nil, keyEquivalent: "")
                menu.addItem(withTitle: "Rename…", action: #selector(renameSelected), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Copy", action: #selector(copySelected), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(deleteSelected), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Get Info", action: #selector(getInfo), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Show in Finder", action: #selector(showInRealFinder), keyEquivalent: "")
        }

        return menu
    }

    @objc func openSelectedFromMenu(_ sender: Any?) {
        for item in selectedItems() {
            openItem(item)
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let item = selectedItems().first else { return }

        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = item.name
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue
            guard !newName.isEmpty, newName != item.name else { return }
            let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: item.url, to: newURL)
                loadContents()
            } catch {
                let err = NSAlert(error: error)
                err.runModal()
            }
        }
    }

    @objc func showInRealFinder(_ sender: Any?) {
        let urls = selectedItems().map { $0.url }
        if urls.isEmpty {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: currentURL.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return key - open selected
            let selected = selectedItems()
            if selected.count == 1 {
                openItem(selected[0])
            }
        } else if event.keyCode == 51 { // Delete key
            deleteSelected(nil)
        } else if event.keyCode == 49 { // Space - Quick Look
            quickLookSelected()
        } else {
            super.keyDown(with: event)
        }
    }

    func quickLookSelected() {
        guard let item = selectedItems().first else { return }
        // Use QLPreviewPanel if available, otherwise open
        NSWorkspace.shared.open(item.url)
    }
}

// MARK: - NSSplitViewDelegate

extension FinderViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Minimum sidebar width
        return 150
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Maximum sidebar width — no more than 40% of the split view or 350pt, whichever is smaller
        return min(splitView.bounds.width * 0.4, 350)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Allow collapsing the sidebar
        return subview === sidebarScrollView
    }
}

// MARK: - NSOutlineView DataSource & Delegate (Sidebar)

extension FinderViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sidebarItems.count
        }
        if let name = item as? String {
            return sidebarItems.first(where: { $0.name == name })?.children.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sidebarItems[index].name
        }
        if let name = item as? String,
           let parent = sidebarItems.first(where: { $0.name == name }) {
            return parent.children[index]
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let name = item as? String {
            return sidebarItems.contains(where: { $0.name == name })
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if let name = item as? String {
            return sidebarItems.contains(where: { $0.name == name })
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let name = item as? String {
            // Header
            let cell = NSTableCellView()
            let textField = NSTextField(labelWithString: name.uppercased())
            textField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        if let sidebarItem = item as? SidebarItem {
            let cell = NSTableCellView()

            let imageView = NSImageView()
            imageView.image = sidebarItem.icon
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown

            let textField = NSTextField(labelWithString: sidebarItem.name)
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            return cell
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if item is String { return false }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarOutlineView.selectedRow
        guard row >= 0 else { return }
        let item = sidebarOutlineView.item(atRow: row)
        if let sidebarItem = item as? SidebarItem, let url = sidebarItem.url {
            navigateTo(url)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        return false
    }
}

// MARK: - NSCollectionView DataSource & Delegate

extension FinderViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return filteredItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("FileCell"), for: indexPath)
        if let fileItem = item as? FileCollectionViewItem {
            let file = filteredItems[indexPath.item]
            fileItem.configure(with: file)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateStatusBar()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateStatusBar()
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout

extension FinderViewController: NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        return NSSize(width: 100, height: 100)
    }
}

// MARK: - NSTableView DataSource & Delegate

extension FinderViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredItems.count else { return nil }
        let item = filteredItems[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("Name")

        let cell = NSTableCellView()

        switch identifier.rawValue {
        case "Name":
            let imageView = NSImageView()
            imageView.image = item.icon
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown

            let textField = NSTextField(labelWithString: item.name)
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

        case "Date":
            let textField = NSTextField(labelWithString: item.formattedDate)
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

        case "Size":
            let textField = NSTextField(labelWithString: item.formattedSize)
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor
            textField.alignment = .right
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

        case "Kind":
            let textField = NSTextField(labelWithString: item.kindDescription)
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first else { return }

        switch sortDescriptor.key {
        case "name":
            filteredItems.sort {
                let result = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortDescriptor.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case "date":
            filteredItems.sort {
                sortDescriptor.ascending
                    ? $0.modificationDate < $1.modificationDate
                    : $0.modificationDate > $1.modificationDate
            }
        case "size":
            filteredItems.sort {
                sortDescriptor.ascending ? $0.size < $1.size : $0.size > $1.size
            }
        case "kind":
            filteredItems.sort {
                let result = $0.kindDescription.localizedCaseInsensitiveCompare($1.kindDescription)
                return sortDescriptor.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        default:
            break
        }

        tableView.reloadData()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatusBar()
    }

    // Context menu for table view
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        if edge == .trailing {
            let delete = NSTableViewRowAction(style: .destructive, title: "Trash") { [weak self] _, row in
                guard let self = self, row < self.filteredItems.count else { return }
                let item = self.filteredItems[row]
                do {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    self.loadContents()
                } catch {
                    let err = NSAlert(error: error)
                    err.runModal()
                }
            }
            return [delete]
        }
        return []
    }
}

// MARK: - Toolbar Delegate

extension FinderViewController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "BackForward":
            let group = NSToolbarItem(itemIdentifier: itemIdentifier)

            let backButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: self, action: #selector(goBack))
            backButton.bezelStyle = .texturedRounded
            backButton.isBordered = true

            let forwardButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!, target: self, action: #selector(goForward))
            forwardButton.bezelStyle = .texturedRounded
            forwardButton.isBordered = true

            let segmented = NSStackView(views: [backButton, forwardButton])
            segmented.spacing = 1
            group.view = segmented
            group.label = "Back/Forward"
            return group

        case "ViewMode":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let segmented = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
            ], trackingMode: .selectOne, target: self, action: #selector(viewModeChanged))
            segmented.selectedSegment = viewMode == .icon ? 0 : 1
            segmented.segmentStyle = .texturedRounded
            item.view = segmented
            item.label = "View"
            return item

        case "Search":
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged)
            self.searchField = item.searchField
            return item

        case "Path":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let btn = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Go to Folder")!, target: self, action: #selector(goToFolder))
            btn.bezelStyle = .texturedRounded
            item.view = btn
            item.label = "Go to Folder"
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("BackForward"),
            .flexibleSpace,
            NSToolbarItem.Identifier("ViewMode"),
            .flexibleSpace,
            NSToolbarItem.Identifier("Path"),
            NSToolbarItem.Identifier("Search"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    @objc func viewModeChanged(_ sender: NSSegmentedControl) {
        viewMode = sender.selectedSegment == 0 ? .icon : .list
        updateViewMode()
    }
}

// MARK: - NSSearchFieldDelegate

extension FinderViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField {
            searchText = field.stringValue
            applyFilter()
        }
    }
}

// MARK: - File Collection View Item

class FileCollectionViewItem: NSCollectionViewItem {
    private var iconView: NSImageView!
    private var label: NSTextField!
    private var fileItem: FileItem?
    private var trackingArea: NSTrackingArea?

    override func loadView() {
        view = FileCollectionItemView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8

        iconView = NSImageView(frame: .zero)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)

        label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.cell?.truncatesLastVisibleLine = true
        view.addSubview(label)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])
    }

    func configure(with item: FileItem) {
        self.fileItem = item
        iconView.image = item.icon
        label.stringValue = item.name
        label.textColor = .labelColor
    }

    override var isSelected: Bool {
        didSet {
            if isSelected {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
                label.textColor = .labelColor
            } else {
                view.layer?.backgroundColor = nil
                label.textColor = .labelColor
            }
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            switch highlightState {
            case .forSelection:
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            case .forDeselection, .none:
                if !isSelected {
                    view.layer?.backgroundColor = nil
                }
            case .asDropTarget:
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            @unknown default:
                break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let item = fileItem {
            if let vc = collectionView?.delegate as? FinderViewController {
                vc.openItem(item)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        if let vc = collectionView?.delegate as? FinderViewController {
            // Select this item if not already selected
            if let indexPath = collectionView?.indexPath(for: self),
               !(collectionView?.selectionIndexPaths.contains(indexPath) ?? false) {
                collectionView?.selectionIndexPaths = [indexPath]
            }
            let menu = vc.buildContextMenu(for: vc.selectedItems())
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }
}

// MARK: - Custom view for collection item (handles right-click on empty space)

class FileCollectionItemView: NSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        // Find the FinderViewController
        var responder: NSResponder? = self
        while let r = responder {
            if let vc = r as? FinderViewController {
                return vc.buildContextMenu(for: [])
            }
            responder = r.nextResponder
        }
        return super.menu(for: event)
    }
}

// MARK: - Drag and Drop support for Collection View

extension FinderViewController {
    // Enable drag from collection view
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = filteredItems[indexPath.item]
        return item.url as NSURL
    }

    // Validate drop
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        return .copy
    }

    // Accept drop
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }

        let fm = FileManager.default
        for url in urls {
            let dest = currentURL.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                print("Drop error: \(error)")
            }
        }
        loadContents()
        return true
    }
}
