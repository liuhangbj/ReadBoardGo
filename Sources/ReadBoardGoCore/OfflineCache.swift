import Foundation
import CryptoKit
import ReadBoardContract
import ReadBoardRemote

public struct ReadBoardGoCacheStatus: Equatable, Sendable {
    public let updatedAt: Date?
    public let pendingReadingMutations: Int
    public let recoveryNotice: String?

    public init(updatedAt: Date?, pendingReadingMutations: Int, recoveryNotice: String? = nil) {
        self.updatedAt = updatedAt
        self.pendingReadingMutations = pendingReadingMutations
        self.recoveryNotice = recoveryNotice
    }
}

/// Go 的最后有效数据缓存。它不是服务端数据库副本，只保存最近列表、导航、正文、
/// 源目录和可安全重放的已读/星标目标状态。
public actor ReadBoardGoOfflineCache {
    private struct Record<Value: Codable & Sendable>: Codable, Sendable {
        var value: Value
        var updatedAt: TimeInterval
    }

    private enum ReadingMutation: Codable, Equatable, Sendable {
        case read(id: Int64, value: Bool)
        case starred(id: Int64, value: Bool)

        var contentID: Int64 {
            switch self {
            case .read(let id, _), .starred(let id, _): id
            }
        }
    }

    private struct Envelope: Codable, Sendable {
        var serverKey: String?
        var profile: Record<RemoteServerProfile>?
        var librarySnapshot: Record<LibrarySnapshot>?
        var sourceCatalog: Record<SourceCatalogSnapshot>?
        var pages: [String: Record<ContentPage>] = [:]
        var details: [String: Record<ContentDetail>] = [:]
        var pendingMutations: [ReadingMutation] = []
        var updatedAt: TimeInterval?
        var recoveryNotice: String?
    }

    private let fileURL: URL
    private var envelope: Envelope
    private var mutationFlush: Task<Void, Never>?
    private var mutationBusy = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var transportOffline = false

    func setTransportOffline(_ value: Bool) { transportOffline = value }
    fileprivate func isTransportOffline() -> Bool { transportOffline }
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // 缓存键必须由查询语义而不是 JSON 对象字段的偶发输出顺序决定。
        // sortedKeys 让同一个 ContentQuery 在保存、读取和重启后始终得到同一键。
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("ReadBoard Go", isDirectory: true)
            .appendingPathComponent("offline-cache.json")
        self.fileURL = resolvedURL
        if let data = try? Data(contentsOf: resolvedURL),
           let loaded = try? JSONDecoder().decode(Envelope.self, from: data) {
            envelope = loaded
        } else {
            envelope = Envelope()
        }
    }

    public func status() -> ReadBoardGoCacheStatus {
        ReadBoardGoCacheStatus(
            updatedAt: envelope.updatedAt.map(Date.init(timeIntervalSince1970:)),
            pendingReadingMutations: envelope.pendingMutations.count,
            recoveryNotice: envelope.recoveryNotice)
    }

    /// Check identity and access data in one actor turn, so a response from a
    /// retired gateway cannot populate (or read) another credential's cache.
    func scoped<Value: Sendable>(to serverKey: String?,
        _ operation: @Sendable (isolated ReadBoardGoOfflineCache) throws -> Value
    ) throws -> Value {
        guard serverKey == nil || serverKey == envelope.serverKey else {
            throw CancellationError()
        }
        return try operation(self)
    }

    /// Retain the old credential's cache separately before switching identities.
    /// Legacy host-only caches cannot be safely assigned to a credential.
    public func activate(serverKey: String) throws {
        guard envelope.serverKey != serverKey else { return }
        let hasData = envelope.updatedAt != nil || !envelope.pendingMutations.isEmpty
        var notice: String?
        if hasData {
            let count = envelope.pendingMutations.count
            let archiveKey = envelope.serverKey ?? "legacy-unbound"
            try write(envelope, to: archiveURL(for: archiveKey))
            notice = count > 0
                ? "旧登录身份的缓存已保留备份，含 \(count) 项未同步操作；为避免写错账号，未自动回填。"
                : "旧登录身份的缓存已保留备份；当前内容将重新缓存。"
        }
        let target = archiveURL(for: serverKey)
        var replacement = Envelope(serverKey: serverKey)
        if FileManager.default.fileExists(atPath: target.path) {
            let restored = try decoder.decode(Envelope.self, from: Data(contentsOf: target))
            guard restored.serverKey == serverKey else { throw CancellationError() }
            replacement = restored
        }
        replacement.recoveryNotice = notice ?? replacement.recoveryNotice
        // Do not discard the old in-memory cache if durable preparation fails.
        try write(replacement, to: fileURL)
        envelope = replacement
        transportOffline = false
    }

    private func archiveURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return fileURL.deletingLastPathComponent().appendingPathComponent("cache-\(hash).json")
    }

    public func storeProfile(_ value: RemoteServerProfile) {
        envelope.profile = record(value)
        persist()
    }

    public func profile() -> RemoteServerProfile? { envelope.profile?.value }

    public func storeLibrarySnapshot(_ value: LibrarySnapshot) {
        envelope.librarySnapshot = record(value)
        persist()
    }

    public func librarySnapshot() -> LibrarySnapshot? { envelope.librarySnapshot?.value }

    public func storeSourceCatalog(_ value: SourceCatalogSnapshot) {
        envelope.sourceCatalog = record(value)
        persist()
    }

    public func sourceCatalog() -> SourceCatalogSnapshot? { envelope.sourceCatalog?.value }

    public func storePage(_ value: ContentPage, query: ContentQuery) {
        envelope.pages[queryKey(query)] = record(value)
        trimPages()
        persist()
    }

    public func page(query: ContentQuery) -> ContentPage? {
        if let exact = envelope.pages[queryKey(query)]?.value {
            return exact
        }
        // 旧版本使用未排序的 JSON 作为键。升级后仍按解码出的查询语义匹配，
        // 这样用户断连时不会因为键格式变化丢失最后有效列表。
        return envelope.pages.compactMap { key, record in
            decodedQuery(from: key) == query ? record : nil
        }.max(by: { $0.updatedAt < $1.updatedAt })?.value
    }

    public func storeDetail(_ value: ContentDetail) {
        envelope.details[String(value.id)] = record(value)
        trimDetails()
        persist()
    }

    public func detail(contentID: Int64) -> ContentDetail? {
        envelope.details[String(contentID)]?.value
    }

    fileprivate func state(contentID: Int64) -> (isRead: Bool, isStarred: Bool)? {
        for record in envelope.pages.values {
            if let item = record.value.items.first(where: { $0.id == contentID }) {
                return (item.isRead, item.isStarred)
            }
        }
        return nil
    }

    func apply(_ state: ContentState) {
        let previousItem = cachedItem(contentID: state.contentID)
        let isInboxContent = cachedAsInbox(contentID: state.contentID)
        for key in envelope.pages.keys {
            guard var page = envelope.pages[key],
                  let index = page.value.items.firstIndex(where: { $0.id == state.contentID }) else {
                continue
            }
            var items = page.value.items
            items[index] = items[index].replacingState(
                isRead: state.isRead,
                isStarred: state.isStarred)
            page.value = ContentPage(items: items, nextCursor: page.value.nextCursor)
            page.updatedAt = Date().timeIntervalSince1970
            envelope.pages[key] = page
        }
        if let previousItem, previousItem.isRead != state.isRead {
            applyReadDelta(
                state.isRead ? -1 : 1,
                item: previousItem,
                isInboxContent: isInboxContent)
        }
        touch()
        persist()
    }

    private func cachedItem(contentID: Int64) -> ContentSummary? {
        for record in envelope.pages.values {
            if let item = record.value.items.first(where: { $0.id == contentID }) {
                return item
            }
        }
        return nil
    }

    private func cachedAsInbox(contentID: Int64) -> Bool {
        for (key, record) in envelope.pages {
            guard record.value.items.contains(where: { $0.id == contentID }),
                  let query = decodedQuery(from: key)
            else { continue }
            if query.filter.inboxOnly == true { return true }
        }
        // 收件箱单项不属于订阅源；即使用户还未打开过收件箱分类页，也能从
        // 列表 DTO 的 sourceID 判定并同步其导航计数。
        return cachedItem(contentID: contentID)?.sourceID == nil
    }

    private func applyReadDelta(
        _ delta: Int,
        item: ContentSummary,
        isInboxContent: Bool
    ) {
        guard var snapshot = envelope.librarySnapshot else { return }
        let counts = snapshot.value.counts
        let shifted: (Int) -> Int = { max(0, $0 + delta) }
        let shiftedOptional: (Int?) -> Int? = { $0.map(shifted) }
        let isSocial = ContentSourceFamily.socialSourceTypes.contains(item.source.lowercased())
            || item.sourceType.map {
                ContentSourceFamily.socialSourceTypes.contains($0.lowercased())
            } == true

        let newCounts = LibraryCountsSnapshot(
            total: counts.total,
            unread: shifted(counts.unread),
            pending: counts.pending,
            pendingUnread: item.hasUnmetProcessing
                ? shifted(counts.pendingUnread) : counts.pendingUnread,
            exported: counts.exported,
            exportedUnread: item.hasExport
                ? shifted(counts.exportedUnread) : counts.exportedUnread,
            articles: counts.articles,
            articleUnread: item.contentType == ContentCategory.article.rawValue && !isSocial
                ? shifted(counts.articleUnread) : counts.articleUnread,
            podcasts: counts.podcasts,
            podcastUnread: item.contentType == ContentCategory.podcast.rawValue
                ? shifted(counts.podcastUnread) : counts.podcastUnread,
            videos: counts.videos,
            videoUnread: item.contentType == ContentCategory.video.rawValue && !isSocial
                ? shifted(counts.videoUnread) : counts.videoUnread,
            socialArticles: counts.socialArticles,
            socialArticleUnread: item.contentType == ContentCategory.article.rawValue && isSocial
                ? shiftedOptional(counts.socialArticleUnread) : counts.socialArticleUnread,
            socialVideos: counts.socialVideos,
            socialVideoUnread: item.contentType == ContentCategory.video.rawValue && isSocial
                ? shiftedOptional(counts.socialVideoUnread) : counts.socialVideoUnread,
            inbox: counts.inbox,
            inboxUnread: isInboxContent
                ? shiftedOptional(counts.inboxUnread) : counts.inboxUnread,
            inboxArticles: counts.inboxArticles,
            inboxArticleUnread: isInboxContent
                && item.contentType == ContentCategory.article.rawValue
                ? shiftedOptional(counts.inboxArticleUnread) : counts.inboxArticleUnread,
            inboxPodcasts: counts.inboxPodcasts,
            inboxPodcastUnread: isInboxContent
                && item.contentType == ContentCategory.podcast.rawValue
                ? shiftedOptional(counts.inboxPodcastUnread) : counts.inboxPodcastUnread,
            inboxVideos: counts.inboxVideos,
            inboxVideoUnread: isInboxContent
                && item.contentType == ContentCategory.video.rawValue
                ? shiftedOptional(counts.inboxVideoUnread) : counts.inboxVideoUnread,
            inboxSocialArticles: counts.inboxSocialArticles,
            inboxSocialArticleUnread: isInboxContent
                && item.contentType == ContentCategory.article.rawValue && isSocial
                ? shiftedOptional(counts.inboxSocialArticleUnread)
                : counts.inboxSocialArticleUnread,
            inboxSocialVideos: counts.inboxSocialVideos,
            inboxSocialVideoUnread: isInboxContent
                && item.contentType == ContentCategory.video.rawValue && isSocial
                ? shiftedOptional(counts.inboxSocialVideoUnread)
                : counts.inboxSocialVideoUnread)

        let updatedNodes = item.sourceID.map {
            adjustingUnread(in: snapshot.value.nodes, sourceID: $0, delta: delta)
        } ?? snapshot.value.nodes
        snapshot.value = LibrarySnapshot(nodes: updatedNodes, counts: newCounts)
        snapshot.updatedAt = Date().timeIntervalSince1970
        envelope.librarySnapshot = snapshot
    }

    private func adjustingUnread(
        in nodes: [LibraryNode],
        sourceID: Int64,
        delta: Int
    ) -> [LibraryNode] {
        nodes.map { adjustedNode($0, sourceID: sourceID, delta: delta).node }
    }

    private func adjustedNode(
        _ node: LibraryNode,
        sourceID: Int64,
        delta: Int
    ) -> (node: LibraryNode, containsSource: Bool) {
        let childResults = node.children.map {
            adjustedNode($0, sourceID: sourceID, delta: delta)
        }
        let containsSource = node.sourceID == sourceID
            || childResults.contains(where: \.containsSource)
        return (
            LibraryNode(
                id: node.id,
                kind: node.kind,
                name: node.name,
                count: node.count,
                unread: containsSource ? max(0, node.unread + delta) : node.unread,
                sourceID: node.sourceID,
                folderID: node.folderID,
                children: childResults.map(\.node)),
            containsSource)
    }

    fileprivate func enqueueRead(contentID: Int64, value: Bool) {
        envelope.pendingMutations.removeAll {
            if case .read(let id, _) = $0 { return id == contentID }
            return false
        }
        envelope.pendingMutations.append(.read(id: contentID, value: value))
        touch()
        persist()
    }

    fileprivate func enqueueStarred(contentID: Int64, value: Bool) {
        envelope.pendingMutations.removeAll {
            if case .starred(let id, _) = $0 { return id == contentID }
            return false
        }
        envelope.pendingMutations.append(.starred(id: contentID, value: value))
        touch()
        persist()
    }

    func flushPendingMutations(using remote: RemoteLibraryGateway, serverKey: String?) async {
        guard serverKey == nil || serverKey == envelope.serverKey else { return }
        guard !transportOffline else { return }
        // Page and navigation refresh can overlap. Join the same flush instead
        // of replaying a snapshot twice and deleting entries by shifting index.
        if let mutationFlush { await mutationFlush.value; return }
        let task = Task {
            await acquireMutationGate()
            defer { releaseMutationGate() }
            guard serverKey == nil || serverKey == envelope.serverKey else { return }
            await drainPendingMutations(using: remote)
        }
        mutationFlush = task
        await task.value
        mutationFlush = nil
    }

    private func acquireMutationGate() async {
        if !mutationBusy { mutationBusy = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutationGate() {
        if mutationWaiters.isEmpty { mutationBusy = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    fileprivate func changeReadingState(using remote: RemoteLibraryGateway, serverKey: String?,
        contentID: Int64, read: Bool? = nil, starred: Bool? = nil
    ) async throws -> ContentState {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        try scoped(to: serverKey) { _ in }
        let identity = envelope.serverKey
        if transportOffline {
            return try stageReadingState(contentID: contentID, read: read, starred: starred)
        }
        // The same gate orders live changes after older deferred changes. An
        // older offline target must never overwrite a newer online selection.
        await drainPendingMutations(using: remote)
        guard identity == envelope.serverKey, !Task.isCancelled else { throw CancellationError() }
        do {
            let value: ContentState
            if let read { value = try await remote.setRead(contentID: contentID, isRead: read) }
            else if let starred { value = try await remote.setStarred(contentID: contentID, isStarred: starred) }
            else { throw CancellationError() }
            guard identity == envelope.serverKey else { throw CancellationError() }
            envelope.pendingMutations.removeAll {
                switch $0 {
                case .read(let id, _): return id == contentID && read != nil
                case .starred(let id, _): return id == contentID && starred != nil
                }
            }
            let resolved = overlayPending(on: value)
            apply(resolved)
            return resolved
        } catch {
            guard identity == envelope.serverKey else { throw CancellationError() }
            guard isOfflineTransportError(error) else { throw error }
            return try stageReadingState(contentID: contentID, read: read, starred: starred)
        }
    }

    private func stageReadingState(contentID: Int64, read: Bool?, starred: Bool?) throws -> ContentState {
        guard let current = state(contentID: contentID) else {
            throw LibraryGatewayError.operationFailed("此内容尚未缓存，连接恢复后请重试。")
        }
        let previous = envelope
        if let read { enqueueRead(contentID: contentID, value: read) }
        if let starred { enqueueStarred(contentID: contentID, value: starred) }
        let value = ContentState(contentID: contentID, isRead: read ?? current.isRead,
            isStarred: starred ?? current.isStarred, updatedAt: Int64(Date().timeIntervalSince1970))
        apply(value)
        do { try write(envelope, to: fileURL) }
        catch {
            envelope = previous
            throw LibraryGatewayError.operationFailed("无法保存离线操作，请检查本机存储空间后重试。")
        }
        return value
    }

    private func overlayPending(on state: ContentState) -> ContentState {
        var read = state.isRead
        var starred = state.isStarred
        for pending in envelope.pendingMutations where pending.contentID == state.contentID {
            switch pending {
            case .read(_, let value): read = value
            case .starred(_, let value): starred = value
            }
        }
        return ContentState(contentID: state.contentID, isRead: read,
            isStarred: starred, updatedAt: state.updatedAt)
    }

    private func drainPendingMutations(using remote: RemoteLibraryGateway) async {
        let serverKey = envelope.serverKey
        while let mutation = envelope.pendingMutations.first, !Task.isCancelled {
            do {
                let state: ContentState
                switch mutation {
                case .read(let id, let value):
                    state = try await remote.setRead(contentID: id, isRead: value)
                case .starred(let id, let value):
                    state = try await remote.setStarred(contentID: id, isStarred: value)
                }
                guard envelope.serverKey == serverKey else { return }
                // Remove only the acknowledged target, never another operation
                // that moved into the old array index while the request awaited.
                envelope.pendingMutations.removeAll { $0 == mutation }
                apply(overlayPending(on: state))
                persist()
            } catch { return }
        }
    }

    private func record<Value: Codable & Sendable>(_ value: Value) -> Record<Value> {
        let now = Date().timeIntervalSince1970
        envelope.updatedAt = now
        return Record(value: value, updatedAt: now)
    }

    private func touch() { envelope.updatedAt = Date().timeIntervalSince1970 }

    private func queryKey(_ query: ContentQuery) -> String {
        ((try? encoder.encode(query)) ?? Data()).base64EncodedString()
    }

    private func decodedQuery(from key: String) -> ContentQuery? {
        guard let data = Data(base64Encoded: key) else { return nil }
        return try? decoder.decode(ContentQuery.self, from: data)
    }

    private func trimPages() {
        let overflow = envelope.pages.count - 12
        guard overflow > 0 else { return }
        for key in envelope.pages.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
            .prefix(overflow).map(\.key) {
            envelope.pages[key] = nil
        }
    }

    private func trimDetails() {
        let overflow = envelope.details.count - 500
        guard overflow > 0 else { return }
        for key in envelope.details.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
            .prefix(overflow).map(\.key) {
            envelope.details[key] = nil
        }
    }

    private func persist() {
        do {
            try write(envelope, to: fileURL)
        } catch {
            // 缓存失败不能中断在线阅读；连接健康仍由远程请求本身决定。
        }
    }

    private func write(_ value: Envelope, to target: URL) throws {
        let manager = FileManager.default
        let directory = target.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        try encoder.encode(value).write(to: target, options: .atomic)
        #if os(macOS)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #endif
    }
}

public struct CachedRemoteLibraryGateway: LibraryGateway {
    private let remote: RemoteLibraryGateway
    private let cache: ReadBoardGoOfflineCache
    private let serverKey: String?

    public init(client: ReadBoardHTTPClient, cache: ReadBoardGoOfflineCache, serverKey: String? = nil) {
        remote = RemoteLibraryGateway(client: client)
        self.cache = cache
        self.serverKey = serverKey
    }

    public func page(_ query: ContentQuery) async throws -> ContentPage {
        if try await cache.scoped(to: serverKey, { $0.isTransportOffline() }) {
            guard let value = try await cache.scoped(to: serverKey, { $0.page(query: query) }) else {
                throw LibraryGatewayError.operationFailed("此查询尚未缓存，连接恢复后可加载。")
            }
            return value
        }
        do {
            await flushPendingMutations()
            let value = try await remote.page(query)
            try await cache.scoped(to: serverKey) { $0.storePage(value, query: query) }
            return value
        } catch {
            if isOfflineTransportError(error), let cached = try await cache.scoped(to: serverKey, { $0.page(query: query) }) {
                return cached
            }
            throw error
        }
    }

    public func snapshot() async throws -> LibrarySnapshot {
        if try await cache.scoped(to: serverKey, { $0.isTransportOffline() }) {
            guard let value = try await cache.scoped(to: serverKey, { $0.librarySnapshot() }) else {
                throw LibraryGatewayError.operationFailed("资料库导航尚未缓存，连接恢复后可加载。")
            }
            return value
        }
        do {
            await flushPendingMutations()
            let value = try await remote.snapshot()
            try await cache.scoped(to: serverKey) { $0.storeLibrarySnapshot(value) }
            return value
        } catch {
            if isOfflineTransportError(error), let cached = try await cache.scoped(to: serverKey, { $0.librarySnapshot() }) {
                return cached
            }
            throw error
        }
    }

    public func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState {
        try await cache.changeReadingState(using: remote, serverKey: serverKey,
            contentID: contentID, read: isRead)
    }

    public func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState {
        try await cache.changeReadingState(using: remote, serverKey: serverKey,
            contentID: contentID, starred: isStarred)
    }

    public func markRead(filter: ContentFilter) async throws -> MutationSummary {
        do {
            if try await cache.scoped(to: serverKey, { $0.isTransportOffline() }) {
                throw URLError(.notConnectedToInternet)
            }
            return try await remote.markRead(filter: filter)
        } catch {
            guard isOfflineTransportError(error) else { throw error }
            // 批量筛选代表服务端权威范围；离线缓存只有有限分页，不能把“当前已缓存条目”
            // 冒充完整结果，也不能把可变筛选延迟到重连后执行而误伤新入库内容。
            throw LibraryGatewayError.operationFailed(
                "当前处于离线状态，无法执行“全部标为已读”；连接恢复后请重试。")
        }
    }

    private func flushPendingMutations() async {
        await cache.flushPendingMutations(using: remote, serverKey: serverKey)
    }
}

public struct CachedRemoteContentDetailGateway: ContentDetailGateway {
    private let remote: RemoteContentDetailGateway
    private let cache: ReadBoardGoOfflineCache
    private let serverKey: String?

    public init(client: ReadBoardHTTPClient, cache: ReadBoardGoOfflineCache, serverKey: String? = nil) {
        remote = RemoteContentDetailGateway(client: client)
        self.cache = cache
        self.serverKey = serverKey
    }

    public func detail(contentID: Int64) async throws -> ContentDetail {
        if try await cache.scoped(to: serverKey, { $0.isTransportOffline() }) {
            guard let value = try await cache.scoped(to: serverKey, { $0.detail(contentID: contentID) }) else {
                throw LibraryGatewayError.operationFailed("此篇正文尚未缓存，连接恢复后可加载。")
            }
            return value
        }
        do {
            let value = try await remote.detail(contentID: contentID)
            try await cache.scoped(to: serverKey) { $0.storeDetail(value) }
            return value
        } catch {
            if isOfflineTransportError(error), let cached = try await cache.scoped(to: serverKey, { $0.detail(contentID: contentID) }) {
                return cached
            }
            throw error
        }
    }
}

public struct CachedRemoteSourceCatalogGateway: SourceCatalogGateway {
    private let remote: RemoteSourceCatalogGateway
    private let cache: ReadBoardGoOfflineCache
    private let serverKey: String?

    public init(client: ReadBoardHTTPClient, cache: ReadBoardGoOfflineCache, serverKey: String? = nil) {
        remote = RemoteSourceCatalogGateway(client: client)
        self.cache = cache
        self.serverKey = serverKey
    }

    public func snapshot() async throws -> SourceCatalogSnapshot {
        if try await cache.scoped(to: serverKey, { $0.isTransportOffline() }) {
            guard let value = try await cache.scoped(to: serverKey, { $0.sourceCatalog() }) else {
                throw LibraryGatewayError.operationFailed("订阅目录尚未缓存，连接恢复后可加载。")
            }
            return value
        }
        do {
            let value = try await remote.snapshot()
            try await cache.scoped(to: serverKey) { $0.storeSourceCatalog(value) }
            return value
        } catch {
            if isOfflineTransportError(error), let cached = try await cache.scoped(to: serverKey, { $0.sourceCatalog() }) {
                return cached
            }
            throw error
        }
    }
}

private func isOfflineTransportError(_ error: Error) -> Bool {
    if let error = error as? ReadBoardGoConnectionError {
        switch error {
        case .serverNotFound, .serverUnavailable, .connectionTimedOut,
             .networkUnavailable, .secureConnectionFailed, .connectionFailed: return true
        default: return false
        }
    }
    guard let urlError = error as? URLError else { return false }
    return [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .dataNotAllowed,
    ].contains(urlError.code)
}
