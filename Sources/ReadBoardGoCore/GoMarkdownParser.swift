import ReadBoardUI

/// 迁移期兼容名称。Go 不再维护自己的 Markdown 语法实现。
public typealias GoMarkdownBlock = ReadBoardMarkdownBlock

public enum GoMarkdownParser {
    public static func parse(_ markdown: String) -> [GoMarkdownBlock] {
        ReadBoardMarkdownParser.parse(markdown)
    }
}
