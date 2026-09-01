import Foundation
import ReadBoardContract
import ReadBoardRemote

public struct ReadBoardGoCacheStatus: Equatable, Sendable {
    public let updatedAt: Date?
    public let pendingReadingMutations: Int

    public init(updatedAt: Date?, pendingReadingMutations: Int) {
        self.updatedAt = updatedAt
        self.pendingReadingMutations = pendingReadingMutations
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
    }

    private let fileURL: URL
    private var envelope: Envelope
    private let encoder = JSONEncoder()
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
            pendingReadingMutations: envelope.pendingMutations.count)
    }

    /// 一个缓存文件只服务一个已固定证书的服务端。切换地址或证书时丢弃旧的
    /// 列表、正文和待回填动作，避免把 A 服务器的数据展示或写回到 B 服务器。
    public func activate(serverKey: String) {
        if envelope.serverKey == nil {
            envelope.serverKey = serverKey
            persist()
        } else if envelope.serverKey != serverKey {
            envelope = Envelope(serverKey: serverKey)
            persist()
        }
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
        envelope.pages[queryKey(query)]?.value
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
                  let data = Data(base64Encoded: key),
                  let query = try? decoder.decode(ContentQuery.self, from: data)
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

    fileprivate func pendingMutations() -> [(index: Int, contentID: Int64, read: Bool?, starred: Bool?)] {
        envelope.pendingMutations.enumerated().map { index, mutation in
            switch mutation {
            case .read(let id, let value): (index, id, value, nil)
            case .starred(let id, let value): (index, id, nil, value)
            }
        }
    }

    fileprivate func removePendingMutation(at index: Int) {
        guard envelope.pendingMutations.indices.contains(index) else { return }
        envelope.pendingMutations.remove(at: index)
        persist()
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
            let manager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(macOS)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #endif
            try encoder.encode(envelope).write(to: fileURL, options: .atomic)
            #if os(macOS)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            #endif
        } catch {
            // 缓存失败不能中断在线阅读；连接健康仍由远程请求本身决定。
        }
    }
}

public struct CachedRemoteLibraryGateway: LibraryGateway {
    private let remote: RemoteLibraryGateway
    private let cache: ReadBoardGoOfflineCache

    public init(client: ReadBoardHTTPClient, cache: ReadBoardGoOfflineCache) {
        remote = RemoteLibraryGateway(client: client)
        self.cache = cache
    }

    public func page(_ query: ContentQuery) async throws -> ContentPage {
        do {
            await flushPendingMutations()
            let value = try await remote.page(query)
            await cache.storePage(value, query: query)
            return value
        } catch {
            if isOfflineTransportError(error), let cached = await cache.page(query: query) {
                return cached
            }
            throw error
        }
    }

    public func snapshot() async throws -> LibrarySnapshot {
        do {
            await flushPendingMutations()
            let value = try await remote.snapshot()
            await cache.storeLibrarySnapshot(value)
            return value
        } catch {
            if isOfflineTransportError(error), let cached = await cache.librarySnapshot() {
                return cached
            }
            throw error
        }
    }

    public func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState {
        do {
            let value = try await remote.setRead(contentID: contentID, isRead: isRead)
            await cache.apply(value)
            return value
        } catch {
            guard isOfflineTransportError(error),
                  let current = await cache.state(contentID: contentID) else { throw error }
            await cache.enqueueRead(contentID: contentID, value: isRead)
            let value = ContentState(contentID: contentID, isRead: isRead,
                isStarred: current.isStarred, updatedAt: Int64(Date().timeIntervalSince1970))
            await cache.apply(value)
            return value
        }
    }

    public func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState {
        do {
            let value = try await remote.setStarred(contentID: contentID, isStarred: isStarred)
            await cache.apply(value)
            return value
        } catch {
            guard isOfflineTransportError(error),
                  let current = await cache.state(contentID: contentID) else { throw error }
            await cache.enqueueStarred(contentID: contentID, value: isStarred)
            let value = ContentState(contentID: contentID, isRead: current.isRead,
                isStarred: isStarred, updatedAt: Int64(Date().timeIntervalSince1970))
            await cache.apply(value)
            return value
        }
    }

    public func markRead(filter: ContentFilter) async throws -> MutationSummary {
        do {
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
        var offset = 0
        for mutation in await cache.pendingMutations() {
            do {
                let state: ContentState
                if let value = mutation.read {
                    state = try await remote.setRead(contentID: mutation.contentID, isRead: value)
                } else if let value = mutation.starred {
                    state = try await remote.setStarred(contentID: mutation.contentID, isStarred: value)
                } else {
                    continue
                }
                await cache.apply(state)
                await cache.removePendingMutation(at: mutation.index - offset)
                offset += 1
            } catch {
                return
            }
        }
    }
}

public struct CachedRemoteContentDetailGateway: ContentDetailGateway {
    private let remote: RemoteContentDetailGateway
    private let cache: ReadBoardGoOfflineCache

    public init(client: ReadBoardHTTPClient, cache: ReadBoardGoOfflineCache) {
        remote = RemoteContentDetailGateway(client: client)
        self.cache = cache
    }

    public func detail(contentID: Int64) async throws -> ContentDetail {
        do {
            let value = try await remote.detail(contentID: contentID)
            await cache.storeDetail(value)
            return value
        } catch {
            if isOfflineTransportError(error), let cached = await cache.detail(contentID: contentID) {
                return cached
            }
            throw error
        }
    }
}

public struct CachedRemoteSourceCatalogGateway: SourceCatalogGateway {
    private let remote: RemoteSourceCatalogGateway
    private let cache: ReadBoardGoOfflineCache

    public init(client: ReadBoardHTTPClient, cache: ReadBoardGoOfflineCache) {
        remote = RemoteSourceCatalogGateway(client: client)
        self.cache = cache
    }

    public func snapshot() async throws -> SourceCatalogSnapshot {
        do {
            let value = try await remote.snapshot()
            await cache.storeSourceCatalog(value)
            return value
        } catch {
            if isOfflineTransportError(error), let cached = await cache.sourceCatalog() {
                return cached
            }
            throw error
        }
    }
}

private func isOfflineTransportError(_ error: Error) -> Bool {
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
