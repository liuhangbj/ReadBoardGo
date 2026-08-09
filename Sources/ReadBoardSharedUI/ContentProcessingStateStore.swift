import Foundation
import SwiftUI

/// 单篇手动内容处理的共享界面状态。
///
/// 状态按 content id 保存，阅读页因切换文章被重建后仍能恢复处理中或处理结果，
/// Core 和 Go 的数据看板也读取同一个 Store。
@MainActor
public final class ContentProcessingStateStore: ObservableObject {
    public struct Entry: Identifiable, Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case queued
            case running
            case succeeded
            case failed
        }

        public let contentId: Int64
        public let title: String
        public let operation: String
        public let phase: Phase
        public let message: String
        public let updatedAt: Date
        public let appearsInDashboard: Bool

        public var id: Int64 { contentId }
        public var isProcessing: Bool { phase == .queued || phase == .running }
    }

    public static let shared = ContentProcessingStateStore()

    @Published private var entries: [Int64: Entry] = [:]

    private init() {}

    public func state(for contentId: Int64) -> Entry? {
        entries[contentId]
    }

    /// 数据看板使用的手动任务列表。活跃任务优先，其余按最近更新时间倒序。
    public var dashboardEntries: [Entry] {
        entries.values.filter(\.appearsInDashboard).sorted {
            if $0.isProcessing != $1.isProcessing { return $0.isProcessing }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func enqueue(contentId: Int64, title: String, operation: String) {
        set(
            contentId: contentId, title: title, operation: operation,
            phase: .queued, message: "排队中…", appearsInDashboard: true)
    }

    public func begin(
        contentId: Int64,
        title: String? = nil,
        operation: String? = nil,
        message: String
    ) {
        set(
            contentId: contentId, title: title, operation: operation,
            phase: .running, message: message, appearsInDashboard: true)
    }

    public func finish(contentId: Int64, message: String, succeeded: Bool? = nil) {
        let success = succeeded ?? (!message.contains("失败") && !message.contains("❌"))
        set(
            contentId: contentId, title: nil, operation: nil,
            phase: success ? .succeeded : .failed, message: message,
            appearsInDashboard: nil)
    }

    public func notice(contentId: Int64, message: String) {
        let current = entries[contentId]
        set(
            contentId: contentId, title: current?.title, operation: current?.operation,
            phase: current?.phase ?? .failed, message: message,
            appearsInDashboard: current?.appearsInDashboard ?? false)
    }

    public func clear(contentId: Int64) {
        entries.removeValue(forKey: contentId)
    }

    private func set(
        contentId: Int64,
        title: String?,
        operation: String?,
        phase: Entry.Phase,
        message: String,
        appearsInDashboard: Bool?
    ) {
        let current = entries[contentId]
        entries[contentId] = Entry(
            contentId: contentId,
            title: title ?? current?.title ?? "内容 #\(contentId)",
            operation: operation ?? current?.operation ?? "手动处理",
            phase: phase,
            message: message,
            updatedAt: Date(),
            appearsInDashboard: appearsInDashboard ?? current?.appearsInDashboard ?? false)
        pruneIfNeeded()
    }

    /// 手动任务很少，但长期运行仍限制已完成状态数量；活跃任务永不清理。
    private func pruneIfNeeded() {
        guard entries.count > 128 else { return }
        let removable = entries
            .filter { !$0.value.isProcessing }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
        for (contentId, _) in removable.prefix(entries.count - 96) {
            entries.removeValue(forKey: contentId)
        }
    }
}
