import UIKit

private final class CraftNativeFlatListLayout: UICollectionViewFlowLayout {
    private var preparedExtent: CGFloat?

    override func prepare() {
        // Content-size queries can prepare layout before layoutSubviews runs.
        (collectionView as? CraftNativeFlatList)?.updateItemEstimate()
        super.prepare()
        preparedExtent = collectionView.map { extent(of: $0.bounds) }
    }

    private func extent(of bounds: CGRect) -> CGFloat {
        scrollDirection == .vertical ? bounds.width : bounds.height
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let preparedExtent else { return true }
        return abs(preparedExtent - extent(of: newBounds)) > .ulpOfOne
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if shouldInvalidateLayout(forBoundsChange: newBounds), let flow = context as? UICollectionViewFlowLayoutInvalidationContext {
            flow.invalidateFlowLayoutDelegateMetrics = true
            flow.invalidateFlowLayoutAttributes = true
            // Self-sized item dimensions are cached separately from flow
            // metrics. Clear them before a narrower viewport validates old
            // widths, while keeping the cells and their rendered state.
            if let collectionView {
                let paths = (0..<collectionView.numberOfSections).flatMap { section in
                    (0..<collectionView.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
                }
                flow.invalidateItems(at: paths)
            }
        }
        return context
    }
}

/// A keyed, recycling native list used by stx's native FlatList primitive.
/// The screen controller owns rendered row state; this view owns collection
/// diffs, viewport state, and UICollectionView cell reuse.
final class CraftNativeFlatList: UICollectionView, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        craftPointerHitTest(point, with: event) { super.hitTest(point, with: event) }
    }

    typealias RenderItem = (_ node: [String: Any], _ identity: String, _ previous: UIView?) -> UIView

    private final class Cell: UICollectionViewCell {
        static let reuseIdentifier = "CraftNativeFlatListCell"

        private(set) var representedIdentity: String?
        private(set) var hostedView: UIView?
        /// Top, bottom, leading and trailing: the row's own margins inset it.
        private var hostedConstraints: [NSLayoutConstraint] = []
        var onRecycle: ((String) -> Void)?
        override func prepareForReuse() {
            super.prepareForReuse()
            recycle()
        }

        /// The row this cell showed is gone; its views stay in the cell, and
        /// the next row it shows reuses them when it has the same shape.
        func recycle() {
            if let identity = representedIdentity, showsHostedView { onRecycle?(identity) }
            representedIdentity = nil
            onRecycle = nil
        }

        /// Whether the row view this cell is meant to show is in it. UIKit
        /// can prepare a second cell for a row (a prefetch, an update), and
        /// the row's one view then moves there: the first cell keeps its
        /// height and draws nothing.
        var showsHostedView: Bool { hostedView.map { $0.superview === contentView } ?? true }

        func host(_ view: UIView, identity: String) {
            if let shown = representedIdentity, shown != identity { recycle() }
            representedIdentity = identity
            // The same view, already here. A view that left for another cell
            // and is asked for again is put back below.
            guard hostedView !== view || view.superview !== contentView else { return applyHostedMargins() }
            // Only a view still in this cell is taken out of it: one that has
            // since moved to another cell is that cell's now, and pulling it
            // from there blanked a row on screen.
            if let shown = hostedView, shown !== view, shown.superview === contentView { shown.removeFromSuperview() }
            NSLayoutConstraint.deactivate(hostedConstraints)
            hostedView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            hostedConstraints = [
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ]
            applyHostedMargins()
            NSLayoutConstraint.activate(hostedConstraints)
        }

        /// A row's margins (`mx-4` on a grouped row) inset it in its cell, as
        /// a column inset it: pinned edge to edge, HQ's Discover results ran
        /// to the screen's sides. Read again on every pass, since a style
        /// update changes the row in place.
        private func applyHostedMargins() {
            guard let view = hostedView, view.superview === contentView, hostedConstraints.count == 4 else { return }
            let margins = view.craftLayoutMargins
            let constants = [margins.top, margins.bottom, margins.left, margins.right]
            for (constraint, constant) in zip(hostedConstraints, constants) where constraint.constant != constant {
                constraint.constant = constant
            }
        }

        func releaseHostedView() {
            recycle()
            if let shown = hostedView, shown.superview === contentView { shown.removeFromSuperview() }
            NSLayoutConstraint.deactivate(hostedConstraints)
            hostedConstraints = []
            hostedView = nil
        }

        /// Puts this cell's row view back when another cell took it.
        func reclaimHostedView() {
            guard let identity = representedIdentity, let view = hostedView, view.superview !== contentView else { return }
            host(view, identity: identity)
        }

        override func preferredLayoutAttributesFitting(
            _ layoutAttributes: UICollectionViewLayoutAttributes
        ) -> UICollectionViewLayoutAttributes {
            guard let hostedView = hostedView else { return layoutAttributes }
            applyHostedMargins()
            let margins = hostedView.craftLayoutMargins
            let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            // A cell has no collectionView property; the list is its nearest
            // collection view ancestor.
            var ancestor = superview
            while let view = ancestor, !(view is UICollectionView) { ancestor = view.superview }
            // A reusable cell can be measured during UIKit's invalidation,
            // before layoutSubviews updates visible cells. Derive the extent
            // from the live list bounds on every self-sizing pass.
            let list = ancestor as? CraftNativeFlatList
            let isChrome = representedIdentity.flatMap { list?.itemsByIdentity[$0]?.isChrome } ?? false
            let fittingExtent = list?.itemExtent(isChrome: isChrome)
            if let collectionView = ancestor as? UICollectionView,
               let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
               flowLayout.scrollDirection == .horizontal {
                let height = fittingExtent ?? layoutAttributes.size.height
                let inner = max(0, height - margins.top - margins.bottom)
                let measured = CraftNativeFlexLayout.measure(
                    hostedView,
                    width: nil,
                    height: inner,
                    maxWidth: CraftNativeFlexLayout.unbounded,
                    maxHeight: inner
                )
                attributes.size = CGSize(width: max(1, ceil(measured.width + margins.left + margins.right)), height: max(1, height))
            } else {
                let width = fittingExtent ?? layoutAttributes.size.width
                let inner = max(0, width - margins.left - margins.right)
                let measured = CraftNativeFlexLayout.measure(
                    hostedView,
                    width: inner,
                    height: nil,
                    maxWidth: inner,
                    maxHeight: CraftNativeFlexLayout.unbounded
                )
                attributes.size = CGSize(width: max(1, width), height: max(1, ceil(measured.height + margins.top + margins.bottom)))
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
    private var removeItem: ((String) -> Void)?
    private var endReached: (() -> Void)?
    /// The `fontFamily` the list's rows inherit from its ancestors. Rows are
    /// reconfigured when only their node changes, so the screen redraws them
    /// itself when this changes (`CraftNativeScreenController.reconcileFlatList`).
    var inheritedFontFamily: String?
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
    private var dataOrdinals: [Int] = []
    private var dataItemCount = 0
    private var columns = 1
    private var isApplyingSnapshot = false
    private var snapshotNeedsReset = false
    private var pendingApply: (() -> Void)?
    private var pendingThemeRefresh = false
    private let nativeRefreshControl = UIRefreshControl()
    private var refreshHandler: (() -> Void)?
    private let keyboardTapGesture = UITapGestureRecognizer()
    private var keyboardShouldPersistTaps = "never"
    private var scrollTargetKey: String?
    private var pendingScrollTarget: (id: String, animated: Bool, attempts: Int)?
    /// A target that ends at the list's end, held to the true bottom while
    /// the rows near it measure themselves. Rows self-size from a 44pt
    /// estimate, so an offset worked out before they are measured stops short
    /// of tall rows (multi-paragraph replies, cards). Cleared by a drag.
    private var endSettlePasses: Int?
    private var endSettleGeneration = 0
    private var isAnimatingToEnd = false
    private var isMeasuringEnd = false

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
        // The renderer keeps one live view per keyed row. UIKit's speculative
        // cell prefetch can otherwise move that view out of its visible cell.
        // UICollectionView still recycles and self-sizes the visible window.
        isPrefetchingEnabled = false
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
        // Flex measurement proposes several widths before committing a frame.
        // Mutating the collection here lets self-sizing cache a provisional
        // width and can reenter parent measurement through contentSize.didSet.
        // Read the committed measurement, or estimate until layout measures
        // rows at their actual width and onFittingHeightChanged asks for room.
        let content: CGFloat
        if abs(bounds.width - width) <= 0.5, contentSize.height > 0 {
            content = contentSize.height
        } else if flowLayout.scrollDirection == .horizontal {
            content = items.isEmpty ? 0 : 44
        } else {
            var rows = 0
            var pending = 0
            for item in items {
                if item.isChrome {
                    rows += (pending + columns - 1) / columns + 1
                    pending = 0
                } else {
                    pending += 1
                }
            }
            rows += (pending + columns - 1) / columns
            content = CGFloat(rows) * 44 + CGFloat(max(0, rows - 1)) * flowLayout.minimumLineSpacing
        }
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

    fileprivate func updateItemEstimate() {
        let estimate = flowLayout.scrollDirection == .horizontal
            ? CGSize(width: 44, height: itemExtent(isChrome: true))
            : CGSize(width: itemExtent(isChrome: false), height: 44)
        if flowLayout.estimatedItemSize != estimate, bounds.width > 0 {
            flowLayout.estimatedItemSize = estimate
        }
    }

    override func layoutSubviews() {
        updateItemEstimate()
        super.layoutSubviews()
        reclaimVisibleRows()
        craftApplyCornerRadius()
        scrollToPendingTarget()
    }

    /// A row on screen whose view went to a cell UIKit prepared for the same
    /// row and then did not show gets it back, rather than staying blank.
    private func reclaimVisibleRows() {
        for case let cell as Cell in visibleCells where !cell.showsHostedView { cell.reclaimHostedView() }
    }

    /// Every row on screen draws its own view (simulator-hosted XCTest).
    var visibleRowsShowTheirViews: Bool {
        visibleCells.allSatisfy { ($0 as? Cell)?.showsHostedView ?? true }
    }

    /// Scroll to a virtualized row identified by its native testID, id, or key.
    /// The row need not be mounted yet; the data snapshot is enough to find its
    /// index, and UIKit will mount it as part of the scroll.
    func setScrollTarget(_ value: Any?) {
        var id: String?
        var animated = true
        if let text = value as? String {
            id = text
        } else if let target = value as? [String: Any] {
            id = target["id"] as? String
            animated = target["animated"] as? Bool ?? true
        }
        guard let id, !id.isEmpty else {
            scrollTargetKey = nil
            pendingScrollTarget = nil
            return
        }
        let key: String
        if let target = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: target, options: [.sortedKeys]) {
            key = String(decoding: data, as: UTF8.self)
        } else {
            key = id
        }
        guard key != scrollTargetKey else { return }
        scrollTargetKey = key
        pendingScrollTarget = (id, animated, 0)
        cancelEndSettle()
        scrollToPendingTarget()
    }

    func setContentContainerStyle(_ raw: [String: Any]?) {
        func nonNegative(_ value: Any?) -> CGFloat? {
            guard let number = craftNativeNumber(value) else { return nil }
            let points = CGFloat(truncating: number)
            guard points.isFinite, points >= 0 else { return nil }
            return points
        }
        let padding = nonNegative(raw?["padding"]) ?? 0
        let horizontal = nonNegative(raw?["paddingHorizontal"]) ?? padding
        let vertical = nonNegative(raw?["paddingVertical"]) ?? padding
        let inset = UIEdgeInsets(
            top: nonNegative(raw?["paddingTop"]) ?? vertical,
            left: nonNegative(raw?["paddingLeft"]) ?? horizontal,
            bottom: nonNegative(raw?["paddingBottom"]) ?? vertical,
            right: nonNegative(raw?["paddingRight"]) ?? horizontal
        )
        guard contentInset != inset else { return }
        contentInset = inset
        scrollIndicatorInsets = inset
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

    func setRefreshAppearance(_ props: [String: Any]) {
        nativeRefreshControl.tintColor = (props["tintColor"] as? String).flatMap { UIColor(hex: $0) }
    }

    @objc private func refreshTriggered() {
        refreshHandler?()
        // Once the script has answered the pull, on its own thread or not.
        CraftNativeScriptThread.afterScript { [weak self] in
            guard let self, !self.refreshingProp, self.nativeRefreshControl.isRefreshing else { return }
            self.nativeRefreshControl.endRefreshing()
        }
    }

    @objc private func keyboardTap() {
        guard keyboardShouldPersistTaps != "always" else { return }
        let point = keyboardTapGesture.location(in: self)
        craftHandleKeyboardTap(in: self, hit: hitTest(point, with: nil), persistTaps: keyboardShouldPersistTaps) {
            self.craftScreenController?.forgetFocusedInput()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        craftScrollGesture(gestureRecognizer, runsWith: otherGestureRecognizer)
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
        removeItem: @escaping (String) -> Void,
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
                    removeItem: removeItem,
                    endReached: endReached
                )
            }
            return
        }
        isApplyingSnapshot = true

        self.renderItem = renderItem
        self.recycleItem = recycleItem
        self.removeItem = removeItem
        self.endReached = endReached
        self.endReachedThreshold = max(0, endReachedThreshold)
        let nextColumns = max(1, columns)
        let layoutChanged = self.columns != nextColumns || flowLayout.scrollDirection != (horizontal ? .horizontal : .vertical)
        self.columns = nextColumns

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
        // Reapplying an identical keyed tree during a timer or badge update
        // must not reconfigure cells, invalidate self-sizing, or reset a drag.
        if !snapshotNeedsReset, !layoutChanged, next.count == items.count,
           zip(next, items).allSatisfy({ $0.identity == $1.identity && $0.signature == $1.signature }) {
            finishApplyingSnapshot()
            return
        }
        snapshotNeedsReset = false
        dataItemCount = 0
        dataOrdinals = next.map { item in
            if !item.isChrome { dataItemCount += 1 }
            return dataItemCount - 1
        }
        items = next
        itemsByIdentity = Dictionary(uniqueKeysWithValues: next.map { ($0.identity, $0) })

        flowLayout.scrollDirection = horizontal ? .horizontal : .vertical
        alwaysBounceHorizontal = horizontal
        alwaysBounceVertical = !horizontal
        showsHorizontalScrollIndicator = horizontal
        showsVerticalScrollIndicator = !horizontal
        if layoutChanged { flowLayout.invalidateLayout() }

        let nextIds = Set(itemsByIdentity.keys)
        for identity in oldItems.keys where !nextIds.contains(identity) { removeItem(identity) }
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
        snapshotNeedsReset = true
        visibleCells.compactMap { $0 as? Cell }.forEach { $0.releaseHostedView() }
        itemsByIdentity.keys.forEach { recycleItem?($0) }
        items = []
        dataOrdinals = []
        dataItemCount = 0
        itemsByIdentity = [:]
        renderItem = nil
        recycleItem = nil
        removeItem = nil
        endReached = nil
        dataContentSignature = ""
        onScrollEvent = nil
        onLayoutChanged = nil
        onScrollBeginDrag = nil
        onScrollEndDrag = nil
        onMomentumScrollBegin = nil
        onMomentumScrollEnd = nil
        pendingThemeRefresh = false
        scrollTargetKey = nil
        pendingScrollTarget = nil
        cancelEndSettle()
    }

    /// Releases callbacks and UIKit ownership that belong to a permanently
    /// removed list node. Recycled rows intentionally use `discardAll()` only:
    /// the same list can be rebound during the next reconciliation.
    func resetForTeardown() {
        setRefreshHandler(nil, refreshing: false)
        discardAll()
        onFittingHeightChanged = nil
        delegate = nil
        nativeRefreshControl.removeTarget(self, action: nil, for: .allEvents)
        removeGestureRecognizer(keyboardTapGesture)
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
        // The end is measured by jumping there and back in one pass, before
        // anything draws: the screen hears only where the scroll goes.
        guard !isMeasuringEnd else { return }
        onScrollEvent?(scrollView)
        onLayoutChanged?()
        evaluateEndReached()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The finger has the list now: stop holding it to its end.
        cancelEndSettle()
        onScrollBeginDrag?(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard isAnimatingToEnd else { return }
        isAnimatingToEnd = false
        // Rows passed on the way measured themselves and moved the end.
        settleAtEnd()
        scheduleEndSettle()
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

    private func evaluateEndReached() {
        guard !isApplyingSnapshot, pendingApply == nil,
              let endReached = endReached,
              let lastVisible = indexPathsForVisibleItems.map(\.item).max() else { return }
        guard dataItemCount > 0, dataOrdinals.indices.contains(lastVisible) else { return }
        let lastDataOrdinal = dataOrdinals[lastVisible]
        guard lastDataOrdinal >= 0 else { return }
        let remaining = dataItemCount - lastDataOrdinal - 1
        let thresholdItems = max(1, Int(ceil(Double(dataItemCount) * endReachedThreshold)))
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
            self.scrollToPendingTarget()
            self.evaluateEndReached()
        }
    }

    private func targetIndex(for id: String) -> Int? {
        items.firstIndex { item in
            let props = item.node["props"] as? [String: Any] ?? [:]
            return [props["testID"], props["id"], item.node["id"], item.identity]
                .compactMap { $0 as? String }
                .contains(id)
        }
    }

    private func scrollToPendingTarget() {
        guard let target = pendingScrollTarget else { return }
        // A snapshot that is landing, or queued behind the one landing, can
        // add rows before the target or move it: an index read now is stale
        // (it scrolled to the old end). finishApplyingSnapshot() aims again
        // once the rows are in, and so does a list not laid out yet.
        guard !isApplyingSnapshot, pendingApply == nil, bounds.width > 0, bounds.height > 0 else { return }
        guard let index = targetIndex(for: target.id), index < numberOfItems(inSection: 0) else {
            // No row has this id once the list is idle: try a few more
            // passes, then let it go.
            if target.attempts >= 4 {
                pendingScrollTarget = nil
                return
            }
            pendingScrollTarget = (target.id, target.animated, target.attempts + 1)
            DispatchQueue.main.async { [weak self] in self?.scrollToPendingTarget() }
            return
        }
        pendingScrollTarget = nil
        let indexPath = IndexPath(item: index, section: 0)
        let identity = diffableDataSource.itemIdentifier(for: indexPath) ?? items[index].identity
        if index == numberOfItems(inSection: 0) - 1 {
            scrollToEnd(animated: target.animated)
            return
        }
        let position: UICollectionView.ScrollPosition = flowLayout.scrollDirection == .horizontal ? .left : .top
        scrollToItem(at: indexPath, at: position, animated: target.animated)
        guard !target.animated else { return }
        // A row near the end cannot come to the top: the list stops at its
        // end, which is only true once the rows there are measured.
        layoutIfNeeded()
        if rowReachesPastEnd(identity) { scrollToEnd(animated: false) }
    }

    /// The offset that shows the end of the content, along the scroll axis.
    private var endOffset: CGPoint {
        if flowLayout.scrollDirection == .horizontal {
            return CGPoint(
                x: max(-adjustedContentInset.left, contentSize.width + adjustedContentInset.right - bounds.width),
                y: contentOffset.y
            )
        }
        return CGPoint(
            x: contentOffset.x,
            y: max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        )
    }

    /// Whether the row's leading edge lies past where the list can scroll to.
    private func rowReachesPastEnd(_ identity: String) -> Bool {
        guard let indexPath = diffableDataSource.indexPath(for: identity),
              let frame = layoutAttributesForItem(at: indexPath)?.frame else { return false }
        if flowLayout.scrollDirection == .horizontal {
            return frame.minX - adjustedContentInset.left >= endOffset.x - 0.5
        }
        return frame.minY - adjustedContentInset.top >= endOffset.y - 0.5
    }

    private func scrollToEnd(animated: Bool) {
        endSettlePasses = 2
        endSettleGeneration += 1
        if animated {
            // Measure the rows at the end where they will be, then animate
            // there from where the list was, so the animation lands on the
            // true end rather than on an estimate.
            let start = contentOffset
            isMeasuringEnd = true
            settleAtEnd()
            let end = contentOffset
            setContentOffset(start, animated: false)
            isMeasuringEnd = false
            if abs(end.x - start.x) > 0.5 || abs(end.y - start.y) > 0.5 {
                isAnimatingToEnd = true
                setContentOffset(end, animated: true)
            }
        } else {
            settleAtEnd()
        }
        scheduleEndSettle()
    }

    /// Moves to the end until it stops moving: each move shows rows that
    /// measure themselves and change the content size.
    private func settleAtEnd() {
        guard endSettlePasses != nil, !isDragging, !isTracking else { return cancelEndSettle() }
        for _ in 0..<6 {
            layoutIfNeeded()
            let end = endOffset
            guard abs(end.x - contentOffset.x) > 0.5 || abs(end.y - contentOffset.y) > 0.5 else { break }
            setContentOffset(end, animated: false)
        }
    }

    /// Checks the end again on the next runloop passes, while late rows and
    /// the content size settle.
    private func scheduleEndSettle() {
        let generation = endSettleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.endSettleGeneration == generation, let passes = self.endSettlePasses,
                  // An animation on its way there settles, and checks
                  // again, when it ends.
                  !self.isAnimatingToEnd else { return }
            if passes <= 0 { return self.cancelEndSettle() }
            self.endSettlePasses = passes - 1
            if !self.isApplyingSnapshot, self.pendingApply == nil { self.settleAtEnd() }
            self.scheduleEndSettle()
        }
    }

    private func cancelEndSettle() {
        endSettlePasses = nil
        endSettleGeneration += 1
        isAnimatingToEnd = false
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
        return [node["key"], props["key"], props["testID"], node["id"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }
}
