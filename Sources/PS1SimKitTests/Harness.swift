import Foundation

/// A minimal test harness.
///
/// This exists instead of XCTest because the command line tools do not ship
/// XCTest, and requiring a full Xcode install to run the tests would mean they
/// are not run while writing code. It is a plain executable, so `swift run
/// PS1SimKitTests` works on any toolchain, and a non-zero exit fails CI.
enum Check {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) private static var group = ""

    static func suite(_ name: String, _ body: () -> Void) {
        group = name
        print("\n\(name)")
        body()
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String,
                                    file: StaticString = #file, line: UInt = #line) {
        if actual == expected {
            passed += 1
            print("  ok   \(what)")
        } else {
            let message = "\(group): \(what)\n       expected: \(expected)\n       actual:   \(actual)"
            failures.append(message)
            print("  FAIL \(what)\n       expected: \(expected)\n       actual:   \(actual)")
        }
    }

    static func check(_ condition: Bool, _ what: String) {
        equal(condition, true, what)
    }

    static func isNil<T>(_ value: T?, _ what: String) {
        equal(value == nil, true, what)
    }

    /// Exits non-zero when anything failed, which is what CI reads.
    static func report() -> Never {
        print(String(repeating: "-", count: 60))
        if failures.isEmpty {
            print("\(passed) passed")
            exit(0)
        }
        print("\(passed) passed, \(failures.count) FAILED\n")
        for failure in failures { print("  * \(failure)") }
        exit(1)
    }
}
