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
final class CraftNativeFlatList: UICollectionView, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    typealias RenderItem = (_ node: [String: Any], _ identity: String, _ previous: UIView?) -> UIView

    private final class Cell: UICollectionViewCell {
        static let reuseIdentifier = "CraftNativeFlatListCell"

        private(set) var representedIdentity: String?
        private(set) var hostedView: UIView?
        var onRecycle: ((String) -> Void)?
        /// The width (or, sideways, height) the list gives this row, so a row
        /// is measured at the list's width rather than the layout's estimate.
        var fittingExtent: CGFloat?

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
            // A cell has no collectionView property; the list is its nearest
            // collection view ancestor.
            var ancestor = superview
            while let view = ancestor, !(view is UICollectionView) { ancestor = view.superview }
            if let collectionView = ancestor as? UICollectionView,
               let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
               flowLayout.scrollDirection == .horizontal {
                let height = fittingExtent ?? layoutAttributes.size.height
                let measured = CraftNativeFlexLayout.measure(
                    hostedView,
                    width: nil,
                    height: height,
                    maxWidth: CraftNativeFlexLayout.unbounded,
                    maxHeight: height
                )
                attributes.size = CGSize(width: max(1, ceil(measured.width)), height: max(1, height))
            } else {
                let width = fittingExtent ?? layoutAttributes.size.width
                let measured = CraftNativeFlexLayout.measure(
                    hostedView,
                    width: width,
                    height: nil,
                    maxWidth: width,
                    maxHeight: CraftNativeFlexLayout.unbounded
                )
                attributes.size = CGSize(width: max(1, width), height: max(1, ceil(measured.height)))
            }
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
    var onScrollEvent: ((UIScrollView) -> Void)?
    /// Called as the visible rows move, for a screen that lays out around them.
    var onLayoutChanged: (() -> Void)?
    var onScrollBeginDrag: ((UIScrollView) -> Void)?
    var onScrollEndDrag: ((UIScrollView) -> Void)?
    var onMomentumScrollBegin: ((UIScrollView) -> Void)?
    var onMomentumScrollEnd: ((UIScrollView) -> Void)?
    private var endReachedThreshold = 0.1
    private var endReachedSignature: String?
    private var dataContentSignature = ""
    private var columns = 1
    private var isApplyingSnapshot = false
    private var pendingApply: (() -> Void)?
    private var pendingThemeRefresh = false
    private let nativeRefreshControl = UIRefreshControl()
    private var refreshHandler: (() -> Void)?
    private let keyboardTapGesture = UITapGestureRecognizer()
    private var keyboardShouldPersistTaps = "never"

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
        keyboardTapGesture.cancelsTouchesInView = false
        keyboardTapGesture.delegate = self
        keyboardTapGesture.addTarget(self, action: #selector(keyboardTap))
        addGestureRecognizer(keyboardTapGesture)
        register(Cell.self, forCellWithReuseIdentifier: Cell.reuseIdentifier)
        nativeRefreshControl.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)
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
            cell.fittingExtent = self.itemExtent(isChrome: item.isChrome)
            cell.host(view, identity: identity)
            return cell
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Called when a list that does not scroll changes height, so the
    /// containers around it make room.
    var onFittingHeightChanged: (() -> Void)?

    override var contentSize: CGSize {
        didSet {
            guard !isScrollEnabled, abs(oldValue.height - contentSize.height) > 0.5 else { return }
            invalidateIntrinsicContentSize()
            onFittingHeightChanged?()
        }
    }

    override var isScrollEnabled: Bool {
        didSet {
            guard isScrollEnabled != oldValue else { return }
            alwaysBounceVertical = isScrollEnabled && flowLayout.scrollDirection == .vertical
            onFittingHeightChanged?()
        }
    }

    /// The height of every row at `width`: what a list that does not scroll
    /// (`scrollEnabled={false}`) takes inside a scroll view or a column.
    /// Rows not measured yet count at their estimate, and the list asks for
    /// room again as they are.
    func fittingHeight(width: CGFloat) -> CGFloat {
        guard !isScrollEnabled else { return 0 }
        if abs(bounds.width - width) > 0.5 { frame.size.width = width }
        layoutIfNeeded()
        let content = flowLayout.collectionViewContentSize.height
        return max(0, ceil(content + contentInset.top + contentInset.bottom))
    }

    /// The width a row gets: the list's own width inside its content padding,
    /// shared between columns for data rows.
    private func itemExtent(isChrome: Bool) -> CGFloat {
        if flowLayout.scrollDirection == .horizontal {
            return max(1, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
        }
        let width = max(1, bounds.width - adjustedContentInset.left - adjustedContentInset.right)
        let count = isChrome ? 1 : columns
        let spacing = flowLayout.minimumInteritemSpacing * CGFloat(count - 1)
        return max(1, (width - spacing) / CGFloat(count))
    }

    override func layoutSubviews() {
        let estimate = flowLayout.scrollDirection == .horizontal
            ? CGSize(width: 44, height: itemExtent(isChrome: true))
            : CGSize(width: itemExtent(isChrome: false), height: 44)
        if flowLayout.estimatedItemSize != estimate, bounds.width > 0 {
            flowLayout.estimatedItemSize = estimate
        }
        super.layoutSubviews()
        craftApplyCornerRadius()
    }

    func setContentContainerStyle(_ raw: [String: Any]?) {
        func number(_ value: Any?) -> CGFloat? { (value as? NSNumber).map { CGFloat(truncating: $0) } }
        let padding = number(raw?["padding"]) ?? 0
        let horizontal = number(raw?["paddingHorizontal"]) ?? padding
        let vertical = number(raw?["paddingVertical"]) ?? padding
        contentInset = UIEdgeInsets(
            top: number(raw?["paddingTop"]) ?? vertical,
            left: number(raw?["paddingLeft"]) ?? horizontal,
            bottom: number(raw?["paddingBottom"]) ?? vertical,
            right: number(raw?["paddingRight"]) ?? horizontal
        )
        scrollIndicatorInsets = contentInset
        collectionViewLayout.invalidateLayout()
    }

    func setKeyboardShouldPersistTaps(_ value: Any?) {
        let requested = value as? String
        keyboardShouldPersistTaps = ["always", "handled", "never"].contains(requested) ? requested! : "never"
        keyboardTapGesture.isEnabled = keyboardShouldPersistTaps != "always"
    }

    private var refreshingProp = false

    /// `onRefresh` and `refreshing`, controlled as in React Native: a pull
    /// the screen does not answer with `refreshing` true ends at once.
    func setRefreshHandler(_ handler: (() -> Void)?, refreshing: Bool) {
        refreshHandler = handler
        refreshingProp = refreshing
        let control = handler == nil ? nil : nativeRefreshControl
        if refreshControl !== control { refreshControl = control }
        if handler == nil || !refreshing {
            if nativeRefreshControl.isRefreshing { nativeRefreshControl.endRefreshing() }
        } else if !nativeRefreshControl.isRefreshing {
            nativeRefreshControl.beginRefreshing()
        }
    }

    @objc private func refreshTriggered() {
        refreshHandler?()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshingProp, self.nativeRefreshControl.isRefreshing else { return }
            self.nativeRefreshControl.endRefreshing()
        }
    }

    @objc private func keyboardTap() {
        guard keyboardShouldPersistTaps != "always" else { return }
        if keyboardShouldPersistTaps == "handled" {
            let point = keyboardTapGesture.location(in: self)
            var hit = hitTest(point, with: nil)
            while let view = hit, view !== self {
                if view is UIControl || !(view.gestureRecognizers ?? []).isEmpty { return }
                hit = view.superview
            }
        }
        window?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

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
        if isApplyingSnapshot {
            pendingApply = { [weak self] in
                self?.apply(
                    nodes: nodes,
                    horizontal: horizontal,
                    columns: columns,
                    inverted: inverted,
                    endReachedThreshold: endReachedThreshold,
                    renderItem: renderItem,
                    recycleItem: recycleItem,
                    endReached: endReached
                )
            }
            return
        }
        isApplyingSnapshot = true

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
                self.finishApplyingSnapshot()
            }
            if !changedLive.isEmpty {
                var update = self.diffableDataSource.snapshot()
                update.reconfigureItems(changedLive)
                self.diffableDataSource.apply(update, animatingDifferences: false, completion: restoreViewport)
            } else {
                restoreViewport()
            }
        }

        let dataItems = next.filter { !$0.isChrome }
        let contentSignature = dataItems.map {
            let encoded = $0.signature.base64EncodedString()
            return "\($0.identity.utf8.count):\($0.identity)\(encoded.utf8.count):\(encoded)"
        }.joined()
        dataContentSignature = contentSignature
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
        dataContentSignature = ""
        onScrollEvent = nil
        onLayoutChanged = nil
        onScrollBeginDrag = nil
        onScrollEndDrag = nil
        onMomentumScrollBegin = nil
        onMomentumScrollEnd = nil
        pendingThemeRefresh = false
    }

    func refreshThemeDefaults() {
        if isApplyingSnapshot {
            pendingThemeRefresh = true
            return
        }
        var snapshot = diffableDataSource.snapshot()
        let identities = snapshot.itemIdentifiers
        guard !identities.isEmpty else { return }
        pendingThemeRefresh = false
        snapshot.reconfigureItems(identities)
        isApplyingSnapshot = true
        diffableDataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.finishApplyingSnapshot()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScrollEvent?(scrollView)
        onLayoutChanged?()
        evaluateEndReached()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onScrollBeginDrag?(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onScrollEndDrag?(scrollView)
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        onMomentumScrollBegin?(scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onMomentumScrollEnd?(scrollView)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard items.indices.contains(indexPath.item) else { return CGSize(width: bounds.width, height: 44) }
        let item = items[indexPath.item]
        if flowLayout.scrollDirection == .horizontal {
            return CGSize(width: 44, height: itemExtent(isChrome: item.isChrome))
        }
        return CGSize(width: itemExtent(isChrome: item.isChrome), height: 44)
    }

    private func evaluateEndReached() {
        guard !isApplyingSnapshot, pendingApply == nil,
              let endReached = endReached,
              let lastVisible = indexPathsForVisibleItems.map(\.item).max() else { return }
        let dataIndices = items.indices.filter { !items[$0].isChrome }
        guard !dataIndices.isEmpty,
              let lastDataOrdinal = dataIndices.lastIndex(where: { $0 <= lastVisible }) else { return }
        let remaining = dataIndices.count - lastDataOrdinal - 1
        let thresholdItems = max(1, Int(ceil(Double(dataIndices.count) * endReachedThreshold)))
        guard remaining <= thresholdItems else { return }
        let signature = dataContentSignature
        guard endReachedSignature != signature else { return }
        endReachedSignature = signature
        endReached()
    }

    private func finishApplyingSnapshot() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isApplyingSnapshot = false
            if let pendingApply = self.pendingApply {
                self.pendingApply = nil
                pendingApply()
                return
            }
            if self.pendingThemeRefresh {
                self.pendingThemeRefresh = false
                self.refreshThemeDefaults()
                return
            }
            self.evaluateEndReached()
        }
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
