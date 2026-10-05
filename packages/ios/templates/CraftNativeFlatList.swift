import UIKit

private final class CraftNativeFlatListLayout: UICollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let current = collectionView?.bounds else { return true }
        return scrollDirection == .vertical
            ? abs(current.width - newBounds.width) > .ulpOfOne
            : abs(current.height - newBounds.height) > .ulpOfOne
    }
}

/// A keyed, recycling native list used by the stx-native FlatList primitive.
/// The screen controller owns rendered row state; this view owns collection
/// diffs, viewport state, and UICollectionView cell reuse.
final class CraftNativeFlatList: UICollectionView, UICollectionViewDelegateFlowLayout {
    typealias RenderItem = (_ node: [String: Any], _ identity: String, _ previous: UIView?) -> UIView

    private final class Cell: UICollectionViewCell {
        static let reuseIdentifier = "CraftNativeFlatListCell"

        private(set) var representedIdentity: String?
        private(set) var hostedView: UIView?
        var onRecycle: ((String) -> Void)?

        override func prepareForReuse() {
            super.prepareForReuse()
            releaseHostedView()
        }

        func host(_ view: UIView, identity: String) {
            if representedIdentity != identity { releaseHostedView() }
            representedIdentity = identity
            guard hostedView !== view else { return }
            hostedView?.removeFromSuperview()
            hostedView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        func releaseHostedView() {
            if let identity = representedIdentity { onRecycle?(identity) }
            hostedView?.removeFromSuperview()
            hostedView = nil
            representedIdentity = nil
            onRecycle = nil
        }

        override func preferredLayoutAttributesFitting(
            _ layoutAttributes: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutAttributes {
            guard let hostedView = hostedView else { return layoutAttributes }
            let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            let target = CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height)
            let measured = hostedView.systemLayoutSizeFitting(
                target,
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            attributes.size.height = max(1, measured.height)
            return attributes
        }
    }

    private struct Item {
        let identity: String
        let node: [String: Any]
        let signature: Data
        let isChrome: Bool
    }

    private struct ViewportAnchor {
        let identity: String
        let distanceFromOrigin: CGFloat
    }

    private let flowLayout: UICollectionViewFlowLayout
    private var diffableDataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var items: [Item] = []
    private var itemsByIdentity: [String: Item] = [:]
    private var renderItem: RenderItem?
    private var recycleItem: ((String) -> Void)?
    private var endReached: (() -> Void)?
    private var endReachedThreshold = 0.1
    private var endReachedSignature: String?
    private var columns = 1

    init() {
        let layout = CraftNativeFlatListLayout()
        layout.estimatedItemSize = CGSize(width: 320, height: 44)
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        flowLayout = layout
        super.init(frame: .zero, collectionViewLayout: layout)
        backgroundColor = .clear
        alwaysBounceVertical = true
        delegate = self
        register(Cell.self, forCellWithReuseIdentifier: Cell.reuseIdentifier)
        diffableDataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: self) {
            [weak self] collectionView, indexPath, identity in
            guard let self = self,
                  let item = self.itemsByIdentity[identity],
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: Cell.reuseIdentifier,
                    for: indexPath
                  ) as? Cell,
                  let renderItem = self.renderItem else { return UICollectionViewCell() }
            let view = renderItem(item.node, identity, cell.hostedView)
            cell.onRecycle = self.recycleItem
            cell.host(view, identity: identity)
            return cell
        }
    }

    required init?(coder: NSCoder) { nil }

    var visibleItemIdentities: [String] {
        indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .compactMap { diffableDataSource.itemIdentifier(for: $0) }
    }

    func apply(
        nodes: [[String: Any]],
        horizontal: Bool,
        columns: Int,
        inverted: Bool,
        endReachedThreshold: Double,
        renderItem: @escaping RenderItem,
        recycleItem: @escaping (String) -> Void,
        endReached: (() -> Void)?
    ) {
        self.renderItem = renderItem
        self.recycleItem = recycleItem
        self.endReached = endReached
        self.endReachedThreshold = max(0, endReachedThreshold)
        self.columns = max(1, columns)

        layoutIfNeeded()
        let oldItems = itemsByIdentity
        let viewportAnchor = currentViewportAnchor()
        var seen: [String: Int] = [:]
        var next = nodes.enumerated().map { index, node -> Item in
            let base = Self.identity(for: node) ?? "index:\(index)"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            let identity = occurrence == 0 ? base : "\(base)#\(occurrence)"
            let props = node["props"] as? [String: Any] ?? [:]
            let role = props["listRole"] as? String
            let signature = (try? JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])) ?? Data()
            return Item(identity: identity, node: node, signature: signature, isChrome: role != nil && role != "item")
        }
        if inverted { next.reverse() }
        items = next
        itemsByIdentity = Dictionary(uniqueKeysWithValues: next.map { ($0.identity, $0) })

        flowLayout.scrollDirection = horizontal ? .horizontal : .vertical
        alwaysBounceHorizontal = horizontal
        alwaysBounceVertical = !horizontal
        showsHorizontalScrollIndicator = horizontal
        showsVerticalScrollIndicator = !horizontal
        flowLayout.invalidateLayout()

        let nextIds = Set(itemsByIdentity.keys)
        for identity in oldItems.keys where !nextIds.contains(identity) { recycleItem(identity) }
        let changed = next.compactMap { item -> String? in
            guard let old = oldItems[item.identity], old.signature != item.signature else { return nil }
            return item.identity
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(next.map(\.identity), toSection: 0)
        let retainedOffset = contentOffset
        diffableDataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self = self else { return }
            let live = Set(self.diffableDataSource.snapshot().itemIdentifiers)
            let changedLive = changed.filter { live.contains($0) }
            let restoreViewport = { [weak self] in
                guard let self = self else { return }
                self.layoutIfNeeded()
                if let viewportAnchor = viewportAnchor {
                    self.restore(viewportAnchor)
                } else {
                    self.setContentOffset(self.clamped(retainedOffset), animated: false)
                }
                self.evaluateEndReached()
            }
            if !changedLive.isEmpty {
                var update = self.diffableDataSource.snapshot()
                update.reconfigureItems(changedLive)
                self.diffableDataSource.apply(update, animatingDifferences: false, completion: restoreViewport)
            } else {
                restoreViewport()
            }
        }

        let contentSignature = "\(next.count):\(next.last?.identity ?? "empty")"
        if contentSignature != endReachedSignature { endReachedSignature = nil }
    }

    func discardAll() {
        visibleCells.compactMap { $0 as? Cell }.forEach { $0.releaseHostedView() }
        itemsByIdentity.keys.forEach { recycleItem?($0) }
        items = []
        itemsByIdentity = [:]
        renderItem = nil
        recycleItem = nil
        endReached = nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { evaluateEndReached() }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard items.indices.contains(indexPath.item) else { return CGSize(width: bounds.width, height: 44) }
        let item = items[indexPath.item]
        if flowLayout.scrollDirection == .horizontal {
            return CGSize(width: max(1, bounds.width * 0.8), height: max(1, bounds.height))
        }
        let count = item.isChrome ? 1 : columns
        let spacing = flowLayout.minimumInteritemSpacing * CGFloat(count - 1)
        return CGSize(width: max(1, (bounds.width - spacing) / CGFloat(count)), height: 44)
    }

    private func evaluateEndReached() {
        guard let endReached = endReached, !items.isEmpty,
              let last = indexPathsForVisibleItems.map(\.item).max() else { return }
        let remaining = items.count - last - 1
        let thresholdItems = max(1, Int(ceil(Double(items.count) * endReachedThreshold)))
        guard remaining <= thresholdItems else { return }
        let signature = "\(items.count):\(items.last?.identity ?? "empty")"
        guard endReachedSignature != signature else { return }
        endReachedSignature = signature
        endReached()
    }

    private func clamped(_ offset: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(-adjustedContentInset.left, offset.x), max(-adjustedContentInset.left, contentSize.width - bounds.width + adjustedContentInset.right)),
            y: min(max(-adjustedContentInset.top, offset.y), max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom))
        )
    }

    private func currentViewportAnchor() -> ViewportAnchor? {
        let horizontal = flowLayout.scrollDirection == .horizontal
        let ordered = indexPathsForVisibleItems.sorted { lhs, rhs in
            let left = layoutAttributesForItem(at: lhs)?.frame
            let right = layoutAttributesForItem(at: rhs)?.frame
            return horizontal ? (left?.minX ?? 0) < (right?.minX ?? 0) : (left?.minY ?? 0) < (right?.minY ?? 0)
        }
        guard let indexPath = ordered.first,
              let identity = diffableDataSource.itemIdentifier(for: indexPath),
              let frame = layoutAttributesForItem(at: indexPath)?.frame else { return nil }
        let distance = horizontal ? frame.minX - contentOffset.x : frame.minY - contentOffset.y
        return ViewportAnchor(identity: identity, distanceFromOrigin: distance)
    }

    private func restore(_ anchor: ViewportAnchor) {
        guard let indexPath = diffableDataSource.indexPath(for: anchor.identity),
              let frame = layoutAttributesForItem(at: indexPath)?.frame else { return }
        var offset = contentOffset
        if flowLayout.scrollDirection == .horizontal {
            offset.x = frame.minX - anchor.distanceFromOrigin
        } else {
            offset.y = frame.minY - anchor.distanceFromOrigin
        }
        setContentOffset(clamped(offset), animated: false)
    }

    private static func identity(for node: [String: Any]) -> String? {
        let props = node["props"] as? [String: Any] ?? [:]
        return [node["id"], node["key"], props["key"], props["testID"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }
}
