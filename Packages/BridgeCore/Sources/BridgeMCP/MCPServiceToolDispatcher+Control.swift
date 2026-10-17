import Foundation

extension MCPServiceToolDispatcher {
  static func isTargetTask(
    clientID: MCPClientID, providerID: String?, sourceClientID: String?
  ) -> Bool {
    clientID == .chatGPT && providerID == "codex"
      && sourceClientID == MCPClientID.chatGPT.rawValue
  }

  static func isTargetSubmission(clientID: MCPClientID, providerID: String?) -> Bool {
    clientID == .chatGPT && (providerID == nil || providerID == "codex")
  }

  func taskControl(providerID: String?, sourceClientID: String?) async throws -> String? {
    guard Self.isTargetTask(
      clientID: clientID, providerID: providerID, sourceClientID: sourceClientID
    ) else { return nil }
    return try await currentControl?()
  }

  func submissionControl(providerID: String?) async throws -> String? {
    guard Self.isTargetSubmission(clientID: clientID, providerID: providerID) else { return nil }
    return try await currentControl?()
  }
}
