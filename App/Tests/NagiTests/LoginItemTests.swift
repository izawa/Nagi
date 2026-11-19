import ServiceManagement
import Testing
@testable import Nagi

/// Only `.enabled` shows as on (DECISIONS D11); the machine's login items are not touched.
@MainActor struct LoginItemTests {
    @Test func states() {
        #expect(LoginItem.state(for: .enabled) == .on)
        #expect(LoginItem.state(for: .requiresApproval) == .needsApproval)
        #expect(LoginItem.state(for: .notRegistered) == .off)
        #expect(LoginItem.state(for: .notFound) == .off)
    }
}
