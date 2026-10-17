@testable import BridgeMCP
import Foundation
import XCTest

extension ControlInjectionTests {
  func testTaskFileResourceURIIsOpaqueAndTaskBound() throws {
    let task = taskFileResourceSnapshot(changedFiles: ["src/result.txt"])
    let uri = try XCTUnwrap(MCPTaskFileResourceURI.make(
      taskID: task.taskID,
      projectID: task.projectID,
      relativePath: "src/result.txt"
    ))

    XCTAssertFalse(uri.contains(task.taskID))
    XCTAssertFalse(uri.contains(task.projectID))
    XCTAssertFalse(uri.contains("src/result.txt"))

    let parsed = try MCPTaskFileResourceURI.parse(uri)
    XCTAssertEqual(parsed.taskID, task.taskID)
    XCTAssertEqual(parsed.projectID, task.projectID)
    XCTAssertEqual(parsed.relativePath, "src/result.txt")
    XCTAssertTrue(MCPTaskFileResourceURI.authorizes(
      uri: uri,
      parsed: parsed,
      task: task,
      clientID: .chatGPT
    ))
  }

  func testTaskFileResourceAuthorizationRejectsWrongTaskProjectClientAndPath() throws {
    let task = taskFileResourceSnapshot(changedFiles: ["src/result.txt"])
    let uri = try XCTUnwrap(MCPTaskFileResourceURI.make(
      taskID: task.taskID,
      projectID: task.projectID,
      relativePath: "src/result.txt"
    ))
    let parsed = try MCPTaskFileResourceURI.parse(uri)

    var wrongTask = taskFileResourceSnapshot(changedFiles: ["src/result.txt"], taskID: "another-task")
    XCTAssertFalse(MCPTaskFileResourceURI.authorizes(
      uri: uri, parsed: parsed, task: wrongTask, clientID: .chatGPT
    ))

    wrongTask = taskFileResourceSnapshot(
      changedFiles: ["src/result.txt"],
      projectID: "another-project"
    )
    XCTAssertFalse(MCPTaskFileResourceURI.authorizes(
      uri: uri, parsed: parsed, task: wrongTask, clientID: .chatGPT
    ))

    let wrongClient = taskFileResourceSnapshot(
      changedFiles: ["src/result.txt"],
      sourceClientID: "qwen.studio"
    )
    XCTAssertFalse(MCPTaskFileResourceURI.authorizes(
      uri: uri, parsed: parsed, task: wrongClient, clientID: .chatGPT
    ))

    let wrongPath = taskFileResourceSnapshot(changedFiles: ["src/other.txt"])
    XCTAssertFalse(MCPTaskFileResourceURI.authorizes(
      uri: uri, parsed: parsed, task: wrongPath, clientID: .chatGPT
    ))
  }

  func testTaskFileResourceURIRejectsUnsafePaths() {
    XCTAssertNil(MCPTaskFileResourceURI.make(
      taskID: "task-a",
      projectID: "project-a",
      relativePath: "../outside.txt"
    ))
    XCTAssertNil(MCPTaskFileResourceURI.make(
      taskID: "task-a",
      projectID: "project-a",
      relativePath: "C:\\outside.txt"
    ))
    XCTAssertNil(MCPTaskFileResourceURI.make(
      taskID: "task-a",
      projectID: "project-a",
      relativePath: "/outside.txt"
    ))
  }

  func testResourceLinkKeepsLegacyResultAndStructuredContent() async throws {
    let task = taskFileResourceSnapshot(changedFiles: ["src/result.txt"])
    let links = try await MCPTaskFileResourceSupport.links(for: task) { _ in
      Data("result".utf8)
    }
    XCTAssertEqual(links.count, 1)

    let output = ServiceGetTaskOutput(task: task)
    let encoder = MCPToolResultEncoder()
    let base = try encoder.encode(output, controlText: nil)
    let linked = try encoder.encode(output, controlText: nil, resourceLinks: links)

    XCTAssertEqual(base.structuredContent, linked.structuredContent)
    XCTAssertEqual(Array(linked.content.prefix(base.content.count)), base.content)
    XCTAssertEqual(linked.content.count, base.content.count + 1)
  }

  func testEmptyChangedFilesKeepLegacyResult() async throws {
    let task = taskFileResourceSnapshot(changedFiles: [])
    let links = try await MCPTaskFileResourceSupport.links(for: task) { _ in
      XCTFail("read closure should not be called")
      return nil
    }
    XCTAssertTrue(links.isEmpty)

    let output = ServiceGetTaskOutput(task: task)
    let encoder = MCPToolResultEncoder()
    let base = try encoder.encode(output, controlText: nil)
    let linked = try encoder.encode(output, controlText: nil, resourceLinks: links)
    XCTAssertEqual(base, linked)
  }

  func testResourceContentPreservesTextAndBinaryBytes() throws {
    let uri = try XCTUnwrap(MCPTaskFileResourceURI.make(
      taskID: "task-a",
      projectID: "project-a",
      relativePath: "result.txt"
    ))

    let textContent = MCPTaskFileResourceSupport.content(
      data: Data("hello".utf8),
      uri: uri,
      relativePath: "result.txt"
    )
    let textJSON = String(decoding: try JSONEncoder().encode(textContent), as: UTF8.self)
    XCTAssertTrue(textJSON.contains("hello"))
    XCTAssertTrue(textJSON.contains("text/plain"))

    let bytes = Data([0x00, 0xFF, 0x10])
    let binaryContent = MCPTaskFileResourceSupport.content(
      data: bytes,
      uri: uri,
      relativePath: "result.bin"
    )
    let binaryJSON = String(decoding: try JSONEncoder().encode(binaryContent), as: UTF8.self)
    XCTAssertTrue(binaryJSON.contains(bytes.base64EncodedString()))
    XCTAssertTrue(binaryJSON.contains("application/octet-stream"))
  }

  private func taskFileResourceSnapshot(
    changedFiles: [String],
    taskID: String = "task-file-resource-test",
    projectID: String = "project-file-resource-test",
    sourceClientID: String = "openai.chatgpt"
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: taskID,
      projectID: projectID,
      source: "mcp.client",
      sourceClientID: sourceClientID,
      status: "completed",
      providerID: "codex",
      changedFiles: changedFiles,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-10-17T00:00:00Z"
    )
  }
}
