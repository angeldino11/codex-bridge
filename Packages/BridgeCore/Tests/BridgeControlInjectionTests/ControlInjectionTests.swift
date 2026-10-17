import BridgeAgentCore
import BridgeDomain
@testable import BridgeMCP
import BridgeServiceCore
import Foundation
import XCTest

final class ControlInjectionTests: XCTestCase {
  func testCurrentFileRereadAndSwitch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("control-injection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = ServiceSettings(store: try SimpleServiceStore.inMemory())
    let injector = ControlInjector(dataRootURL: root, settings: settings)
    let enabled = try await settings.isControlInjectionEnabled()
    XCTAssertTrue(enabled)
    await assertUnavailable(injector)
    let statusERROR = await injector.currentStatus()
    XCTAssertEqual(statusERROR, "ERROR")

    let file = root.appendingPathComponent("control.json")
    let first = " { broken JSON <CTRL> \r\n } "
    try Data(first.utf8).write(to: file)
    let firstRead = try await injector.currentControl()
    XCTAssertEqual(firstRead, first)
    let statusON = await injector.currentStatus()
    XCTAssertEqual(statusON, "ON")
    let second = "new control\n"
    try Data(second.utf8).write(to: file)
    let secondRead = try await injector.currentControl()
    XCTAssertEqual(secondRead, second)

    try await settings.setControlInjectionEnabled(false)
    try FileManager.default.removeItem(at: file)
    let disabledRead = try await injector.currentControl()
    XCTAssertNil(disabledRead)
    let statusOFF = await injector.currentStatus()
    XCTAssertEqual(statusOFF, "OFF")
    try await settings.setControlInjectionEnabled(true)
    await assertUnavailable(injector)
  }

  func testMissingUnreadableAndWhitespaceFilesFailClosed() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("control-injection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let injector = ControlInjector(
      dataRootURL: root,
      settings: ServiceSettings(store: try SimpleServiceStore.inMemory())
    )
    await assertUnavailable(injector)
    let file = root.appendingPathComponent("control.json")
    try Data(" \t\n\r ".utf8).write(to: file)
    await assertUnavailable(injector)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await assertUnavailable(injector)
  }

  func testSkillPrefixStaysBeforeControlAndOriginalMessage() throws {
    let skill = try AgentSelectedSkill(
      name: "example", source: .project,
      contentVersion: String(repeating: "a", count: 64),
      files: [try AgentSelectedSkillFile(relativePath: "SKILL.md", content: "skill text")]
    )
    let original = "  original\nmessage  "
    let persisted = "Skill instructions for example:\n\nskill text\n\nUser task:\n" + original
    let sent = try ControlInjector.taskMessage(persisted, skills: [skill], control: "raw")
    XCTAssertEqual(sent, "Skill instructions for example:\n\nskill text\n\nUser task:\n" +
      "<CTRL>\nraw\n</CTRL>\n\n<MSG>\n" + original + "\n</MSG>")
    XCTAssertEqual(persisted, "Skill instructions for example:\n\nskill text\n\nUser task:\n" + original)
    XCTAssertEqual(ControlInjector.wrap(original, control: "raw"),
      "<CTRL>\nraw\n</CTRL>\n\n<MSG>\n" + original + "\n</MSG>")
  }

  func testScopeIncludesOnlyChatGPTCodexTasks() {
    XCTAssertTrue(MCPServiceToolDispatcher.isTargetTask(
      clientID: .chatGPT, providerID: "codex", sourceClientID: "openai.chatgpt"))
    XCTAssertFalse(MCPServiceToolDispatcher.isTargetTask(
      clientID: .qwenStudio, providerID: "codex", sourceClientID: "openai.chatgpt"))
    XCTAssertFalse(MCPServiceToolDispatcher.isTargetTask(
      clientID: .chatGPT, providerID: "pi", sourceClientID: "openai.chatgpt"))
    XCTAssertFalse(MCPServiceToolDispatcher.isTargetTask(
      clientID: .chatGPT, providerID: "codex", sourceClientID: "macos.app"))
    XCTAssertTrue(MCPServiceToolDispatcher.isTargetSubmission(
      clientID: .chatGPT, providerID: nil))
    XCTAssertFalse(MCPServiceToolDispatcher.isTargetSubmission(
      clientID: .qwenStudio, providerID: "codex"))
    XCTAssertFalse(MCPServiceToolDispatcher.isTargetSubmission(
      clientID: .chatGPT, providerID: "qoder"))
  }

  func testTextInjectionLeavesStructuredContentUnchanged() throws {
    let output = MCPToolErrorOutput(error: .init(
      code: "TASK_FAILED", category: .infrastructureFailure,
      message: "original failure", retryable: false, nextAction: "inspect_error"
    ))
    let encoder = MCPToolResultEncoder()
    let original = try encoder.encode(output, isError: true)
    let injected = try encoder.encode(output, isError: true, controlText: "latest")
    let comparisonEncoder = JSONEncoder()
    comparisonEncoder.outputFormatting = [.sortedKeys]
    let encodedOriginal = try comparisonEncoder.encode(original.structuredContent)
    let encodedInjected = try comparisonEncoder.encode(injected.structuredContent)
    XCTAssertEqual(encodedInjected, encodedOriginal)
    let visible = String(data: try JSONEncoder().encode(injected), encoding: .utf8) ?? ""
    XCTAssertTrue(visible.contains("<CTRL>"))
    XCTAssertTrue(visible.contains("latest"))
    XCTAssertTrue(visible.contains("original failure"))
    let unmodified = String(data: try JSONEncoder().encode(original), encoding: .utf8) ?? ""
    XCTAssertFalse(unmodified.contains("<CTRL>"))
  }

  func testMultipleSkillsStayAheadOfCurrentControlAndMessage() throws {
    let first = try AgentSelectedSkill(
      name: "first", source: .project,
      contentVersion: String(repeating: "a", count: 64),
      files: [try AgentSelectedSkillFile(relativePath: "SKILL.md", content: "first text")]
    )
    let second = try AgentSelectedSkill(
      name: "second", source: .project,
      contentVersion: String(repeating: "b", count: 64),
      files: [try AgentSelectedSkillFile(relativePath: "SKILL.md", content: "second text")]
    )
    let prefix =
      "Skill instructions for second:\n\nsecond text\n\nUser task:\n"
      + "Skill instructions for first:\n\nfirst text\n\nUser task:\n"
    let original = "  keep this exact payload  "
    let persisted = prefix + original
    let sent = try ControlInjector.taskMessage(
      persisted, skills: [first, second], control: "latest raw control"
    )
    XCTAssertEqual(sent, prefix + ControlInjector.wrap(original, control: "latest raw control"))
    XCTAssertEqual(persisted, prefix + original)
  }

  func testMutationReceiptInternalScopeDoesNotChangePublicJSON() throws {
    let receipt = MCPServiceTaskMutationReceipt(
      taskID: "task-1", status: "running", accepted: true,
      taskProviderID: "codex", taskSourceClientID: "openai.chatgpt"
    )
    let data = try JSONEncoder().encode(receipt)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(json.keys), Set(["task_id", "status", "accepted"]))
    XCTAssertEqual(json["task_id"] as? String, "task-1")
    XCTAssertEqual(json["status"] as? String, "running")
    XCTAssertEqual(json["accepted"] as? Bool, true)
    let decoded = try JSONDecoder().decode(MCPServiceTaskMutationReceipt.self, from: data)
    XCTAssertNil(decoded.taskProviderID)
    XCTAssertNil(decoded.taskSourceClientID)
  }
  private func assertUnavailable(_ injector: ControlInjector) async {
    do {
      _ = try await injector.currentControl()
      XCTFail("Expected CONTROL_CONFIG_UNAVAILABLE")
    } catch is ControlConfigUnavailable {
      // Expected fail-closed result.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}
