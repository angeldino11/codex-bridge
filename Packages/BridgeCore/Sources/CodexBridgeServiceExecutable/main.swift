import BridgeServiceHost
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import ucrt
#endif

#if os(Windows)
  import Dispatch
  import WinSDK

  /// Locks the service's DLL search to System32 and its own application
  /// directory. The default search order also walks the current directory
  /// and legacy PATH locations, so a DLL planted next to data files would
  /// load into the long-running service; this removes every fallback.
  private enum WindowsDllSearchPolicy {
    static func applyDefaultLockdown() -> Bool {
      SetDefaultDllDirectories(
        UINT(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR))
    }
  }
#endif

@main
enum CodexBridgeServiceMain {
  #if os(Windows)
    /// Use the same synchronous process entry pattern as the Windows shell.
    /// This avoids the Swift synthesized async-main startup path while keeping
    /// the service's async work on the normal dispatch-backed task executor.
    static func main() {
      // Fail closed: without the lockdown the service would run with the
      // legacy search order (current directory and PATH walk), which is the
      // exact exposure the lockdown removes, so refuse to start.
      guard WindowsDllSearchPolicy.applyDefaultLockdown() else {
        FileHandle.standardError.write(
          Data("Codex Bridge service could not lock its DLL search order.\n".utf8))
        _exit(EXIT_FAILURE)
      }
      Task {
        do {
          try await ServiceProcessRunner.run()
          _exit(EXIT_SUCCESS)
        } catch {
          let errorValue = String(reflecting: error)
          let detail =
            (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
          FileHandle.standardError.write(
            Data("Codex Bridge service failed to start (\(errorValue)): \(detail)\n".utf8)
          )
          _exit(EXIT_FAILURE)
        }
      }
      dispatchMain()
    }
  #else
    static func main() async {
      do {
        try await ServiceProcessRunner.run()
      } catch {
        let errorValue = String(reflecting: error)
        let detail =
          (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(
          Data("Codex Bridge service failed to start (\(errorValue)): \(detail)\n".utf8)
        )
        exit(EXIT_FAILURE)
      }
    }
  #endif
}
