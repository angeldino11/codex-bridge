import BridgeSecurity
import Foundation
import MCP

enum MCPTaskFileResourceURI {
  static let prefix = "codex-bridge://task-file/"
  static let maximumFileBytes = 512 * 1_024
  static let maximumLinks = 32

  static func make(taskID: String, projectID: String, relativePath: String) -> String? {
    guard !taskID.isEmpty, !projectID.isEmpty, let path = securePath(relativePath) else {
      return nil
    }
    let taskToken = Data(taskID.utf8).base64URL
    let projectToken = Data(projectID.utf8).base64URL
    let pathToken = Data(path.value.utf8).base64URL
    return prefix + taskToken + "/" + projectToken + "/" + pathToken
  }

  static func parse(_ uri: String) throws
    -> (taskID: String, projectID: String, relativePath: String)
  {
    guard uri.hasPrefix(prefix), !uri.contains("?"), !uri.contains("#") else {
      throw MCPError.invalidParams("Invalid Bridge task file resource URI.")
    }
    let remainder = String(uri.dropFirst(prefix.count))
    let parts = remainder.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let taskData = Data(base64URL: String(parts[0])),
      let projectData = Data(base64URL: String(parts[1])),
      let pathData = Data(base64URL: String(parts[2])),
      let taskID = String(data: taskData, encoding: .utf8),
      !taskID.isEmpty,
      let projectID = String(data: projectData, encoding: .utf8),
      !projectID.isEmpty,
      let rawPath = String(data: pathData, encoding: .utf8),
      let path = securePath(rawPath),
      make(taskID: taskID, projectID: projectID, relativePath: path.value) == uri
    else {
      throw MCPError.invalidParams("Invalid Bridge task file resource URI.")
    }
    return (taskID, projectID, path.value)
  }

  static func authorizes(
    uri: String,
    parsed: (taskID: String, projectID: String, relativePath: String),
    task: MCPServiceTaskSnapshot,
    clientID: MCPClientID
  ) -> Bool {
    guard task.taskID == parsed.taskID,
      task.projectID == parsed.projectID,
      task.sourceClientID == clientID.rawValue
    else {
      return false
    }
    return task.changedFiles.contains { path in
      make(taskID: task.taskID, projectID: task.projectID, relativePath: path) == uri
    }
  }

  private static func securePath(_ input: String) -> SecureRelativePath? {
    let normalized = input.replacingOccurrences(of: "\\", with: "/")
    guard !normalized.hasPrefix("/"),
      !normalized.hasPrefix("~"),
      !normalized.lowercased().hasPrefix("file:")
    else {
      return nil
    }
    let prefixBytes = Array(normalized.utf8.prefix(2))
    if prefixBytes.count == 2,
      prefixBytes[1] == 58,
      (65...90).contains(prefixBytes[0]) || (97...122).contains(prefixBytes[0])
    {
      return nil
    }
    return try? SecureRelativePath(normalized)
  }

  static func mimeType(for path: String, data: Data? = nil) -> String {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "pdf": return "application/pdf"
    case "zip": return "application/zip"
    case "json":
      return isUTF8Text(data) ? "application/json" : "application/octet-stream"
    case "txt", "md", "swift", "yaml", "yml", "toml", "csv", "html", "css", "js", "ts":
      return isUTF8Text(data) ? "text/plain; charset=utf-8" : "application/octet-stream"
    default:
      return isUTF8Text(data) ? "text/plain; charset=utf-8" : "application/octet-stream"
    }
  }

  static func isUTF8Text(_ data: Data?) -> Bool {
    guard let data, !data.contains(0) else { return false }
    return String(data: data, encoding: .utf8) != nil
  }
}

private extension Data {
  var base64URL: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URL value: String) {
    guard !value.isEmpty else { return nil }
    var encoded = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let decoded = Data(base64Encoded: encoded), decoded.base64URL == value else {
      return nil
    }
    self = decoded
  }
}

enum MCPTaskFileResourceSupport {
  static func links(
    for task: MCPServiceTaskSnapshot,
    read: @Sendable (String) async throws -> Data?
  ) async throws -> [Tool.Content] {
    var links: [Tool.Content] = []
    for path in task.changedFiles.prefix(MCPTaskFileResourceURI.maximumLinks) {
      guard let uri = MCPTaskFileResourceURI.make(
        taskID: task.taskID,
        projectID: task.projectID,
        relativePath: path
      ) else {
        continue
      }
      do {
        guard let data = try await read(path) else { continue }
        links.append(.resourceLink(
          uri: uri,
          name: URL(fileURLWithPath: path).lastPathComponent,
          title: path,
          description: "Task changed file in the approved project.",
          mimeType: MCPTaskFileResourceURI.mimeType(for: path, data: data)
        ))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        continue
      }
    }
    return links
  }

  static func content(data: Data, uri: String, relativePath: String) -> Resource.Content {
    let mimeType = MCPTaskFileResourceURI.mimeType(for: relativePath, data: data)
    if MCPTaskFileResourceURI.isUTF8Text(data) {
      return .text(String(decoding: data, as: UTF8.self), uri: uri, mimeType: mimeType)
    }
    return .binary(data, uri: uri, mimeType: mimeType)
  }
}

extension MCPServiceToolDispatcher {
  func taskFileResourceLinks(for task: MCPServiceTaskSnapshot) async throws -> [Tool.Content] {
    guard task.sourceClientID == clientID.rawValue else { return [] }
    return try await MCPTaskFileResourceSupport.links(for: task) { path in
      let resource = try await service.serviceReadProjectFileResource(
        projectID: task.projectID,
        relativePath: path,
        maximumBytes: MCPTaskFileResourceURI.maximumFileBytes,
        deadline: clock.now.advanced(by: deadlines.read)
      )
      return resource.data
    }
  }

  func readTaskFileResource(uri: String) async throws -> ReadResource.Result {
    let parsed = try MCPTaskFileResourceURI.parse(uri)
    let deadline = clock.now.advanced(by: deadlines.read)
    let task = try await service.serviceTask(
      taskID: parsed.taskID,
      recentEventLimit: 1,
      deadline: deadline
    )
    try validate(task, requestedTaskID: parsed.taskID, eventLimit: 1)
    guard MCPTaskFileResourceURI.authorizes(
      uri: uri,
      parsed: parsed,
      task: task,
      clientID: clientID
    ) else {
      throw MCPError.invalidParams("Invalid Bridge task file resource.")
    }

    let resource = try await service.serviceReadProjectFileResource(
      projectID: parsed.projectID,
      relativePath: parsed.relativePath,
      maximumBytes: MCPTaskFileResourceURI.maximumFileBytes,
      deadline: deadline
    )
    return ReadResource.Result(contents: [
      MCPTaskFileResourceSupport.content(
        data: resource.data,
        uri: uri,
        relativePath: parsed.relativePath
      )
    ])
  }
}
