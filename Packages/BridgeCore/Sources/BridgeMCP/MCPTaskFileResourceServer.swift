import MCP

extension Server {
  func enableTaskFileResources(dispatcher: MCPServiceToolDispatcher) {
    capabilities.resources = .init(subscribe: false, listChanged: false)

    withMethodHandler(ListResources.self) { parameters in
      guard parameters.cursor == nil || parameters.cursor?.isEmpty == true else {
        throw MCPError.invalidParams("The resource list does not use cursors.")
      }
      return ListResources.Result(resources: [])
    }

    withMethodHandler(ReadResource.self) { parameters in
      try await dispatcher.readTaskFileResource(uri: parameters.uri)
    }
  }
}
