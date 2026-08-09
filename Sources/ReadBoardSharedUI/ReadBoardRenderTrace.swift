import Foundation
import os

enum ReadBoardRenderTrace {
    private static let logger = Logger(
        subsystem: "com.hangbits.readboard.shared-ui",
        category: "render")

    static func warning(_ message: String, category: String) {
        logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    static func performance(
        _ label: String,
        start: Date,
        category: String,
        extra: String
    ) {
        let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
        logger.debug(
            "[\(category, privacy: .public)] \(label, privacy: .public) \(milliseconds)ms \(extra, privacy: .public)")
    }
}
