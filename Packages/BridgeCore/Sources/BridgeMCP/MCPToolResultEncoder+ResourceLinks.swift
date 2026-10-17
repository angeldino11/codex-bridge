import Foundation
import MCP

extension MCPToolResultEncoder {
  package func encode<Output: Encodable & Sendable>(
    _ output: Output,
    isError: Bool = false,
    controlText: String?,
    resourceLinks: [Tool.Content]
  ) throws -> CallTool.Result {
    let base = try encode(output, isError: isError, controlText: controlText)
    guard !resourceLinks.isEmpty else { return base }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var accepted: [Tool.Content] = []

    for link in resourceLinks {
      let candidate = CallTool.Result(
        content: base.content + accepted + [link],
        structuredContent: base.structuredContent,
        isError: base.isError,
        _meta: base._meta
      )
      if let data = try? encoder.encode(candidate), data.count <= maximumBytes {
        accepted.append(link)
      }
    }

    return CallTool.Result(
      content: base.content + accepted,
      structuredContent: base.structuredContent,
      isError: base.isError,
      _meta: base._meta
    )
  }
}
