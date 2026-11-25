import XCTest
import LocalAuthentication
import notify
@testable import NativeRender

/// CraftKeychain: a Keychain read once, then from memory until something in
/// this process changes it. A read took up to 900ms on a simulator, on the
/// main thread, and every screen reads the sign-in token when it opens.
final class KeychainUnitTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CraftKeychain.forget(account: nil)
    }

    func testReadsTheKeychainOnceAndThenFromMemory() {
        var reads = 0
        let read = { () -> String? in reads += 1; return "token-1" }
        XCTAssertEqual(CraftKeychain.value(account: "auth.token", service: nil, read: read), "token-1")
        XCTAssertEqual(CraftKeychain.value(account: "auth.token", service: nil, read: read), "token-1")
        XCTAssertEqual(reads, 1)
    }

    func testRemembersThatAnItemIsAbsent() {
        var reads = 0
        let read = { () -> String? in reads += 1; return nil }
        XCTAssertNil(CraftKeychain.value(account: "missing", service: "dev.craft.native.secure", read: read))
        XCTAssertNil(CraftKeychain.value(account: "missing", service: "dev.craft.native.secure", read: read))
        XCTAssertEqual(reads, 1)
    }

    func testForgettingAnAccountReadsItAgainUnderEveryServiceAndLeavesOthers() {
        var reads: [String] = []
        func read(_ name: String, _ value: String) -> () -> String? { { reads.append(name); return value } }
        _ = CraftKeychain.value(account: "auth.token", service: nil, read: read("any", "a"))
        _ = CraftKeychain.value(account: "auth.token", service: "dev.craft.native.secure", read: read("native", "a"))
        _ = CraftKeychain.value(account: "wildloop-account", service: nil, read: read("other", "b"))
        CraftKeychain.forget(account: "auth.token")
        _ = CraftKeychain.value(account: "auth.token", service: nil, read: read("any", "a2"))
        _ = CraftKeychain.value(account: "auth.token", service: "dev.craft.native.secure", read: read("native", "a2"))
        _ = CraftKeychain.value(account: "wildloop-account", service: nil, read: read("other", "b"))
        XCTAssertEqual(reads, ["any", "native", "other", "any", "native"])
    }

    func testAReadThatRacedAWriteIsNotKept() {
        var reads = 0
        // The write lands while the read is still asking the Keychain.
        let stale = CraftKeychain.value(account: "auth.token", service: nil) {
            reads += 1
            CraftKeychain.forget(account: "auth.token")
            return "old"
        }
        XCTAssertEqual(stale, "old")
        XCTAssertEqual(CraftKeychain.value(account: "auth.token", service: nil) { reads += 1; return "new" }, "new")
        XCTAssertEqual(reads, 2)
    }

    func testAWriteThroughTheHybridKeychainIsSeenByTheNextRead() {
        let key = "craft-keychain-test-\(UUID().uuidString)"
        defer { CraftHybridKeychain.set(key, value: nil) }
        CraftHybridKeychain.set(key, value: "first")
        XCTAssertEqual(CraftNativeActions.webSecureValue(forKey: key), "first")
        CraftHybridKeychain.set(key, value: "second")
        XCTAssertEqual(CraftNativeActions.webSecureValue(forKey: key), "second")
        CraftHybridKeychain.set(key, value: nil)
        XCTAssertNil(CraftNativeActions.webSecureValue(forKey: key))
    }
}


/// CraftBiometricVault (#564): a credential the Keychain releases only to a
/// face or finger. The simulator's Face ID is driven the way its Features
/// menu drives it, by Darwin notifications this process can post itself.
final class BiometricVaultUnitTests: XCTestCase {
    private let key = "biometric-vault-test"

    private func simulatorFaceID(enrolled: Bool) {
        var token: Int32 = 0
        notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token)
        notify_set_state(token, enrolled ? 1 : 0)
        notify_post("com.apple.BiometricKit.enrollmentChanged")
        notify_cancel(token)
        // BiometricKit reads the new state asynchronously.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) == enrolled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed, "the simulator's Face ID enrollment did not become \(enrolled)")
    }

    /// What the simulator had before: other tests rely on its default, where
    /// nothing is enrolled.
    private var enrolledBefore = false

    override func setUp() {
        super.setUp()
        enrolledBefore = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        _ = CraftBiometricVault.delete(key: key)
    }

    override func tearDown() {
        _ = CraftBiometricVault.delete(key: key)
        simulatorFaceID(enrolled: enrolledBefore)
        super.tearDown()
    }

    func testACredentialIsReleasedOnlyThroughTheFaceAndCanBeDeleted() throws {
        simulatorFaceID(enrolled: true)
        XCTAssertEqual(CraftBiometricVault.has(key: key), .success(false))
        XCTAssertEqual(CraftBiometricVault.store(key: key, value: "session-token-1"), .success(true))
        // Known to be there without asking anyone.
        XCTAssertEqual(CraftBiometricVault.has(key: key), .success(true))
        // Written behind the currently enrolled faces, on this device only and
        // only while it has a passcode. The simulator records this access
        // control but has no Secure Enclave to enforce it: any read gets the
        // value there, so that the Keychain refuses one without a face is
        // something only a device shows (#564).
        var attributes: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: CraftBiometricVault.service, kSecAttrAccount as String: key, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributes), errSecSuccess)
        let stored = try XCTUnwrap((attributes as? [String: Any])?[kSecAttrAccessControl as String])
        let expected = try XCTUnwrap(SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil))
        XCTAssertTrue(CFEqual(stored as CFTypeRef, expected), "stored \(stored), expected \(expected)")
        XCTAssertEqual((attributes as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        // Nor is it among the session's items.
        let session: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.craft.native.secure", kSecAttrAccount as String: key]
        XCTAssertEqual(SecItemCopyMatching(session as CFDictionary, nil), errSecItemNotFound)

        // The read through a prompt. On a device it shows Face ID and returns
        // once the face matches; the simulator answers it either way. Measured
        // on an iOS 26.5 simulator (2026-11-25): a non-matching face, no face at
        // all, and a read after Face ID was enrolled again each returned the
        // value at once with no prompt, and `evaluatePolicy` answered true to
        // a non-matching face. Refusal, cancel and invalidation are only
        // testable on a device; the Android emulator does enforce them
        // (NativeBiometricPromptTest, #565).
        let context = LAContext()
        context.localizedReason = "Sign in to the test"
        var released: Result<String?, CraftBiometricVault.Failure>?
        let read = expectation(description: "the read returns once the face matches")
        CraftBiometricVault.queue.async {
            released = CraftBiometricVault.read(key: self.key, context: context)
            read.fulfill()
        }
        // The prompt has to be up before the simulator's face is shown to it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { notify_post("com.apple.BiometricKit_Sim.pearl.match") }
        wait(for: [read], timeout: 20)
        XCTAssertEqual(released, .success("session-token-1"))

        // Replaced, then deleted without any prompt.
        XCTAssertEqual(CraftBiometricVault.store(key: key, value: "session-token-2"), .success(true))
        XCTAssertEqual(CraftBiometricVault.delete(key: key), .success(true))
        XCTAssertEqual(CraftBiometricVault.has(key: key), .success(false))
        let silent = LAContext()
        silent.interactionNotAllowed = true
        XCTAssertEqual(CraftBiometricVault.read(key: key, context: silent), .success(nil))
    }

    func testWithNoFaceEnrolledNothingIsWrittenThatNoOneCouldOpen() {
        simulatorFaceID(enrolled: false)
        XCTAssertEqual(CraftBiometricVault.store(key: key, value: "session-token"), .failure(.unavailable))
        XCTAssertEqual(CraftBiometricVault.has(key: key), .success(false))
    }
}
