import Foundation
import NotesKit

// Sona's MCP server on stdio. Reads the notes folder from the app's settings, and the "AI access" switch
// on every call (off: each tool says so). Point any MCP client at this binary; see README.md for exact configs.
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("sona-mcp: Sona's MCP server (stdio). Notes: \(Settings.load().conversationsURL.path)")
    exit(0)
}
// Off until the app's first run is finished and AI access is on (no settings file: the app was never set up; one
// that can't be read: off too, never a default of on).
MCPServer(enabled: { Settings.aiAccessAllowed }).run()
