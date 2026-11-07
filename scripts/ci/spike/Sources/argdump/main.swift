import Foundation
#if os(Windows)
import WinSDK
#endif

func escaped(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
    let array = String(decoding: data, as: UTF8.self)
    let scalars = text.unicodeScalars.filter { !$0.isASCII }.map { String(format: "U+%04X", $0.value) }
    return String(array.dropFirst().dropLast()) + (scalars.isEmpty ? "" : "  [" + scalars.joined(separator: " ") + "]")
}

let arguments = Array(CommandLine.arguments.dropFirst())
print("argdump: \(arguments.count) argument(s)")
for (index, argument) in arguments.enumerated() { print("  [\(index)] \(escaped(argument))") }
#if os(Windows)
if let raw = GetCommandLineW() { print("  raw: \(escaped(String(decodingCString: raw, as: UTF16.self)))") }
#endif
