import Foundation
import ReadBoardContract
import SwiftUI

struct LibraryRow: View {
  let item: ContentSummary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: categorySystemImage)
        .frame(width: 28, height: 28)
        .foregroundStyle(.tint)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(item.translatedTitle ?? item.title)
            .font(.headline)
            .foregroundStyle(item.isRead ? .secondary : .primary)
            .lineLimit(2)
          if item.isStarred {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
          }
        }

        HStack(spacing: 5) {
          Text(item.sourceName ?? item.source)
          if let publishedAt = item.publishedAt {
            Text("·")
            Text(
              Date(timeIntervalSince1970: TimeInterval(publishedAt)),
              format: .dateTime.month().day())
          }
          if let score = item.score {
            Text("· \(score) 分")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if let summary = item.summary ?? item.excerpt, !summary.isEmpty {
          Text(summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        if item.hasTranslation || item.hasTranscript || item.hasUnmetProcessing {
          HStack(spacing: 8) {
            if item.hasTranslation { statusLabel("译文", systemImage: "character.book.closed") }
            if item.hasTranscript { statusLabel("转录", systemImage: "waveform") }
            if item.hasUnmetProcessing {
              statusLabel("待处理", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            }
          }
        }
      }
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
  }

  private var categorySystemImage: String {
    switch item.contentType {
    case "podcast": "headphones"
    case "video": "play.rectangle"
    default: "doc.text"
    }
  }

  private func statusLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage).font(.caption2)
  }
}

struct LibraryRowPlaceholder: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("这是一条正在加载的文章标题").font(.headline)
      Text("内容来源 · 8月9日").font(.caption)
      Text("这里会显示文章摘要，帮助快速判断是否值得打开阅读。")
        .font(.subheadline)
    }
    .padding(.vertical, 6)
    .redacted(reason: .placeholder)
  }
}

extension ContentSummary {
  func replacingState(isRead: Bool, isStarred: Bool) -> ContentSummary {
    ContentSummary(
      id: id, contentType: contentType, source: source, sourceType: sourceType,
      sourceID: sourceID, sourceName: sourceName, title: title, author: author,
      url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
      score: score, summary: summary, fetchStatus: fetchStatus, isRead: isRead,
      isStarred: isStarred, imageURL: imageURL, hasTranslation: hasTranslation,
      hasTranscript: hasTranscript, isMedia: isMedia, translatedHead: translatedHead,
      translatedTitle: translatedTitle, hasFulltext: hasFulltext,
      hasExport: hasExport, hasUnmetProcessing: hasUnmetProcessing,
      accessState: accessState
    )
  }
}
