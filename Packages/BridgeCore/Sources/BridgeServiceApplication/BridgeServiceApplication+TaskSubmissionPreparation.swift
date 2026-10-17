import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func prepareTaskSubmission(
    _ submission: MCPServiceTaskSubmission,
    sourceClientID: String,
    source: ServiceTaskSource,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let projectID = try await submissionProjectID(explicit: submission.projectID)
    let project = try await readableProject(projectID)
    let workbenchPermissionMode = try await workbenchDefaultPermissionMode(
      source: source
    )
    if let providerRaw = submission.providerID, providerRaw != serviceCodexProviderID {
      return try await prepareAgentSubmission(
        submission,
        providerRaw: providerRaw,
        project: project,
        sourceClientID: sourceClientID,
        source: source,
        workbenchPermissionMode: workbenchPermissionMode,
        deadline: deadline
      )
    }
    guard submission.attachmentPaths?.isEmpty != false,
      submission.attachmentSourceTaskID == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let models: [MCPModelSummary]?
    do {
      models = try await catalog.listModels(deadline: deadline).models
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Self.checkDeadline(deadline)
      models = nil
    }
    let selections = try await modelSelections(submission: submission, models: models)
    let permission = try Self.permissionMode(
      workbenchPermissionMode == nil ? submission.permissionMode : nil,
      defaultMode: workbenchPermissionMode ?? .full
    )
    let accessMode = try await settings.accessMode()
    let fastMode =
      try await settings.isFastModeEnabled()
      && models?.first(where: { $0.modelID == selections.execution.model })?
        .supportsFastMode == true
    let selectedSkills = try await selectedSkillSnapshots(
      for: submission,
      project: project,
      deadline: deadline,
      snapshotCodexSkills: source == .mcpClient
        && sourceClientID == MCPClientID.chatGPT.rawValue
    )
    let taskPrompt = try await taskPrompt(
      for: submission,
      projectID: project.id.rawValue,
      deadline: deadline,
      selectedSkills: source == .mcpClient
        && sourceClientID == MCPClientID.chatGPT.rawValue ? selectedSkills : nil
    )
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: source,
        sourceClientID: source == .mcpClient ? sourceClientID : "",
        clientRequestID: submission.clientRequestID,
        prompt: taskPrompt,
        requestedThreadID: submission.threadID,
        executionModel: selections.execution.model,
        executionEffort: selections.execution.effort,
        supervisorModel: selections.supervisor?.model,
        supervisorEffort: selections.supervisor?.effort,
        permissionMode: permission,
        accessMode: accessMode,
        fastMode: fastMode,
        queueIfBusy: submission.queueIfBusy == true,
        selectedSkills: selectedSkills
      )
    )
  }

  private func workbenchDefaultPermissionMode(
    source: ServiceTaskSource
  ) async throws -> ServicePermissionMode? {
    guard source.isRemoteMCPOrigin else { return nil }
    return try await settings.workbenchPermissionMode()
  }

  private func submissionProjectID(explicit: String?) async throws -> String {
    if let explicit { return explicit }
    guard let projectID = try await defaultSubmissionProjectID(in: projects.projects()) else {
      throw BridgeMCPQueryError.projectNotFound
    }
    return projectID
  }

  func taskPrompt(
    for submission: MCPServiceTaskSubmission,
    projectID: String,
    deadline: ContinuousClock.Instant,
    selectedSkills: [AgentSelectedSkill]? = nil
  ) async throws -> String {
    var prompt = Self.prompt(
      submission.prompt,
      acceptanceCriteria: submission.acceptanceCriteria
    )
    if submission.providerID != "pi", submission.providerID != "qoder" {
      let names = (submission.skillNames ?? []) + [submission.skillName].compactMap { $0 }
      var seen = Set<String>()
      for skillName in names where seen.insert(skillName).inserted {
        try Self.checkDeadline(deadline)
        let skillNameForPrompt: String
        let skillContent: String
        if let selectedSkills {
          guard let skill = selectedSkills.first(where: { $0.name == skillName }),
            let content = skill.files.first(where: { $0.relativePath == "SKILL.md" })?.content
          else { throw BridgeMCPQueryError.skillNotFound }
          skillNameForPrompt = skill.name
          skillContent = content
        } else {
          let skill = try await serviceReadSkill(
            skillName: skillName, projectID: projectID, subpath: "SKILL.md",
            deadline: deadline)
          skillNameForPrompt = skill.name
          skillContent = skill.content
        }
        let instructions = String(skillContent.prefix(8 * 1_024))
        prompt = "Skill instructions for \(skillNameForPrompt):\n\n\(instructions)\n\nUser task:\n\(prompt)"
      }
    }
    guard prompt.utf8.count <= 32 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    return prompt
  }
}
