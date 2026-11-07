import Foundation

// launch [--tricky] <program> [arguments...]
// Starts <program> exactly as given (a bare name is NOT searched on PATH by Foundation.Process) and, with --tricky,
// appends the awkward arguments the plan's review focus names. Output is inherited; the exit status is printed.
let tricky = [
    "two words", "quote\"inside", "a&b", "100%", "%PATH%", "trail\\", "trail space\\ ", "caf\u{e9} \u{65E5}\u{672C}",
    "^caret", "pipe|x", "(paren)", "!bang!", "",
]

var arguments = Array(CommandLine.arguments.dropFirst())
let withTricky = arguments.first == "--tricky"
if withTricky { arguments.removeFirst() }
guard let program = arguments.first else {
    print("usage: launch [--tricky] <program> [arguments...]")
    exit(2)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: program)
process.arguments = Array(arguments.dropFirst()) + (withTricky ? tricky : [])
print("launch: \(program) with \(process.arguments!.count) argument(s)")
FileHandle.standardOutput.synchronizeFile()
do {
    try process.run()
    process.waitUntilExit()
    print("launch: exit status \(process.terminationStatus) (reason \(process.terminationReason.rawValue))")
} catch {
    print("launch: could not start: \(error)")
    exit(1)
}
