import BestOCRMCPCore

// Thin entry — everything testable lives in BestOCRMCPCore.
let server = BestOCRMCPServer()
try await server.run()
