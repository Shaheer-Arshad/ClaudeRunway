import Foundation

/// Minimal assertion harness.
///
/// Command Line Tools ships neither XCTest nor swift-testing (both come with
/// Xcode), so tests are compiled straight into the same module as the sources
/// and run as a plain executable.
enum T {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var currentTest = ""

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        do {
            try body()
        } catch {
            failures.append("\(name): threw unexpectedly — \(error)")
        }
    }

    static func expect(_ condition: Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        checks += 1
        if !condition {
            failures.append("\(currentTest): \(message)  [line \(line)]")
        }
    }

    static func equal<V: Equatable>(_ actual: V?, _ expected: V?, _ message: String,
                                    file: StaticString = #file, line: UInt = #line) {
        checks += 1
        if actual != expected {
            failures.append("\(currentTest): \(message) — expected \(String(describing: expected)), got \(String(describing: actual))  [line \(line)]")
        }
    }

    static func throwsError(_ message: String, _ body: () throws -> Void,
                            file: StaticString = #file, line: UInt = #line) {
        checks += 1
        do {
            try body()
            failures.append("\(currentTest): \(message) — expected a throw, none occurred  [line \(line)]")
        } catch {
            // expected
        }
    }

    /// Exits non-zero on failure so shell callers and CI can gate on it.
    static func summarize() -> Never {
        if failures.isEmpty {
            print("PASS — \(checks) checks")
            exit(0)
        }
        print("FAIL — \(failures.count) of \(checks) checks failed:")
        for f in failures { print("  ✗ \(f)") }
        exit(1)
    }
}
