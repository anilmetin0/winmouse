import Foundation

// Checks the pure math against the reference vectors in docs/research. build.sh runs it before
// packaging the app, so a wrong curve never ships. `assert` is compiled out under -O, hence `check`.

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    if !ok {
        failures += 1
        print("FAIL \(file):\(line): \(what())")
    }
}

pointerTests()
scrollTests()
buttonTests()
updateTests()

if failures > 0 {
    print("selftest: \(failures) failure(s)")
    exit(1)
}
print("selftest ok")
