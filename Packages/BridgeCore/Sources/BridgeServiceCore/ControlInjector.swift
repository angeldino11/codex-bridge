import BridgeAgentCore
import BridgeDomain
import Foundation

/// Reads the current file only while preparing a model-visible package.
public struct ControlInjector: Sendable {
  public let fileURL: URL

  public init(dataRootURL: URL) {
    fileURL = dataRootURL.appending(path: "control.json")
  }

  public func currentControl() async throws -> String {
    return try readRawFile()
  }

  public func currentStatus() async -> String {
    do {
      _ = try readRawFile()
      return "ON"
    } catch {
      return "ERROR"
    }
  }

  private func readRawFile() throws -> String {
    guard let data = try? Data(contentsOf: fileURL),
      let raw = String(data: data, encoding: .utf8),
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ControlConfigUnavailable()
    }
    return raw
  }

  public static func wrap(_ message: String, control: String) -> String {
    "<CTRL>\n\(control)\n</CTRL>\n\n<MSG>\n\(message)\n</MSG>"
  }

  /// The persisted Skill-expanded prompt is decoded from its captured Skill files.
  public static func taskMessage(
    _ prompt: String, skills: [AgentSelectedSkill], control: String
  ) throws -> String {
    guard !skills.isEmpty else { return wrap(prompt, control: control) }
    var generatedPrefix = ""
    for skill in skills {
      guard let content = skill.files.first(where: { $0.relativePath == "SKILL.md" })?.content
      else { throw ControlConfigUnavailable() }
      generatedPrefix = "Skill instructions for \(skill.name):\n\n\(content.prefix(8 * 1_024))\n\nUser task:\n\(generatedPrefix)"
    }
    guard prompt.hasPrefix(generatedPrefix) else { throw ControlConfigUnavailable() }
    let original = String(prompt.dropFirst(generatedPrefix.count))
    return "\(generatedPrefix)\(wrap(original, control: control))"
  }
}
