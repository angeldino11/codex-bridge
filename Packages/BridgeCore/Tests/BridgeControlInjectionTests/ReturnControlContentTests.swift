@testable import BridgeMCP
import Foundation
import XCTest

final class ReturnControlContentTests: XCTestCase {
  func testControlUsesDedicatedFirstTextBlockAndKeepsStructuredContent() throws {
    let output = MCPToolErrorOutput(error: .init(
      code: "TASK_FAILED", category: .infrastructureFailure,
      message: "original failure", retryable: false, nextAction: "inspect_error"
    ))
    let encoder = MCPToolResultEncoder()
    let original = try encoder.encode(output, isError: true)
    let injected = try encoder.encode(output, isError: true, controlText: "latest")

    let comparisonEncoder = JSONEncoder()
    comparisonEncoder.outputFormatting = [.sortedKeys]
    XCTAssertEqual(
      try comparisonEncoder.encode(injected.structuredContent),
      try comparisonEncoder.encode(original.structuredContent)
    )

    let originalJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
    )
    let injectedJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(injected)) as? [String: Any]
    )
    let originalContent = try XCTUnwrap(originalJSON["content"] as? [[String: Any]])
    let injectedContent = try XCTUnwrap(injectedJSON["content"] as? [[String: Any]])

    XCTAssertEqual(originalContent.count, 1)
    XCTAssertEqual(injectedContent.count, 2)
    XCTAssertEqual(injectedContent[0]["type"] as? String, "text")
    XCTAssertEqual(injectedContent[0]["text"] as? String, "<CTRL>\nlatest\n</CTRL>")
    XCTAssertEqual(injectedContent[1]["type"] as? String, "text")
    XCTAssertEqual(injectedContent[1]["text"] as? String, originalContent[0]["text"] as? String)
    XCTAssertTrue((injectedContent[1]["text"] as? String)?.contains("original failure") == true)
  }

  func testNoControlKeepsSingleOriginalTextBlock() throws {
    let output = MCPToolErrorOutput(error: .init(
      code: "TASK_FAILED", category: .infrastructureFailure,
      message: "original failure", retryable: false, nextAction: "inspect_error"
    ))
    let encoder = MCPToolResultEncoder()
    let result = try encoder.encode(output, isError: true)
    let resultJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
    )
    let content = try XCTUnwrap(resultJSON["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 1)
    XCTAssertEqual(content[0]["type"] as? String, "text")
    XCTAssertTrue((content[0]["text"] as? String)?.contains("original failure") == true)
    XCTAssertFalse((content[0]["text"] as? String)?.contains("<CTRL>") == true)
  }
}
