import AppKit
import UniformTypeIdentifiers
import WorkspaceModel

@MainActor
protocol TabCollectionViewDelegate: AnyObject {
    func tabList(_ list: TabCollectionView, didSelect id: TabID)
    func tabList(_ list: TabCollectionView, didRequestClose id: TabID)
    func tabList(_ list: TabCollectionView, didRename id: TabID, to title: String)
    func tabList(_ list: TabCollectionView, didMove id: TabID, to index: Int)
    func tabListDidRequestNewTab(_ list: TabCollectionView)
    /// An inline rename ended (Enter, Escape, or focus loss); keyboard focus should go back to the terminal.
    func tabListDidEndRenaming(_ list: TabCollectionView)
}

/// One NSCollectionView that lays out vertically (sidebar) or horizontally (strip).
/// Drag-to-reorder works in both because the flow layout handles both scroll directions.
@MainActor
final class TabCollectionView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, TabItemDelegate {
    private static let dragType = NSPasteboard.PasteboardType("dev.promptty.tab-id")

    weak var delegate: TabCollectionViewDelegate?
    let layoutMode: TabLayout
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private var tabs: [Tab] = []
    private var selected: TabID?
    /// Model updates that arrived during an inline rename; applied when the rename ends.
    private var pendingUpdate: (tabs: [Tab], selected: TabID?)?

    init(layout: TabLayout) {
        layoutMode = layout
        super.init(frame: .zero)
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = layout == .sidebar ? .vertical : .horizontal
        flow.minimumLineSpacing = 2
        flow.minimumInteritemSpacing = 2
        flow.sectionInset = layout == .sidebar ? NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8) : NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsEmptySelection = false
        collection.backgroundColors = [.clear]
        collection.register(TabItem.self, forItemWithIdentifier: TabItem.identifier)
        collection.register(NewTabItem.self, forItemWithIdentifier: NewTabItem.identifier)
        collection.registerForDraggedTypes([Self.dragType])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = layout == .sidebar
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [Tab], selected: TabID?) {
        // Reloading mid-rename would reuse the editing row; defer until the rename ends.
        if collection.visibleItems().contains(where: { ($0 as? TabItem)?.isRenaming == true }) {
            pendingUpdate = (tabs, selected)
            return
        }
        pendingUpdate = nil
        self.tabs = tabs
        self.selected = selected
        collection.reloadData()
        if let selected, let i = tabs.firstIndex(where: { $0.id == selected }) {
            collection.selectionIndexPaths = [IndexPath(item: i, section: 0)]
        }
    }

    override func layout() {
        super.layout()
        collection.collectionViewLayout?.invalidateLayout()
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { tabs.count + 1 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        if indexPath.item == tabs.count {
            let item = collectionView.makeItem(withIdentifier: NewTabItem.identifier, for: indexPath) as! NewTabItem
            item.onTap = { [weak self] in
                guard let self else { return }
                self.delegate?.tabListDidRequestNewTab(self)
            }
            return item
        }
        let item = collectionView.makeItem(withIdentifier: TabItem.identifier, for: indexPath) as! TabItem
        let tab = tabs[indexPath.item]
        item.delegate = self
        item.configure(tab: tab, compact: layoutMode == .strip, selected: tab.id == selected)
        return item
    }

    // MARK: Layout

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let isNewTab = indexPath.item == tabs.count
        switch layoutMode {
        case .sidebar:
            let w = max(1, bounds.width - 16)
            return NSSize(width: w, height: isNewTab ? 28 : 42)
        case .strip:
            return NSSize(width: isNewTab ? 28 : 150, height: 28)
        }
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        indexPaths.filter { $0.item < tabs.count }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.item < tabs.count else { return }
        delegate?.tabList(self, didSelect: tabs[ip.item].id)
    }

    // MARK: Drag to reorder

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { $0.item < tabs.count }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < tabs.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(tabs[indexPath.item].id.rawValue.uuidString, forType: Self.dragType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        dropOperation.pointee = .before
        if proposedIndexPath.pointee.item > tabs.count {
            proposedIndexPath.pointee = NSIndexPath(forItem: tabs.count, inSection: 0)
        }
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let raw = draggingInfo.draggingPasteboard.string(forType: Self.dragType),
              let uuid = UUID(uuidString: raw) else { return false }
        let id = TabID(rawValue: uuid)
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        var to = min(indexPath.item, tabs.count)
        if to > from { to -= 1 }
        delegate?.tabList(self, didMove: id, to: to)
        return true
    }

    // MARK: TabItemDelegate

    func tabItemDidRequestClose(_ item: TabItem) {
        guard let id = item.tabID else { return }
        delegate?.tabList(self, didRequestClose: id)
    }

    func tabItem(_ item: TabItem, didRename id: TabID, to title: String) {
        delegate?.tabList(self, didRename: id, to: title)
    }

    func tabItemDidEndRenaming(_ item: TabItem) {
        if let pending = pendingUpdate {
            update(tabs: pending.tabs, selected: pending.selected)
        }
        delegate?.tabListDidEndRenaming(self)
    }
}
