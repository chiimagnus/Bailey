import CoreFoundation
import Foundation

/// The disk encoding belongs to the file, not to the native editor's UTF-16 storage.
nonisolated struct TextFileEncoding: Hashable, Sendable {
    let name: String
    private let rawValue: UInt
    private let signature: [UInt8]

    private init(_ name: String, _ encoding: String.Encoding, signature: [UInt8] = []) {
        self.name = name
        rawValue = encoding.rawValue
        self.signature = signature
    }

    static let utf8 = TextFileEncoding("UTF-8", .utf8)
    static let gbk = TextFileEncoding.windows(codePage: 936)!
    static let gb18030 = TextFileEncoding.iana("GB18030")!
    static let shiftJIS = TextFileEncoding("Shift-JIS", .shiftJIS)
    static let windows1252 = TextFileEncoding("Windows-1252", .windowsCP1252)
    static let latin1 = TextFileEncoding.iana("ISO-8859-1")!
    static let utf8BOM = TextFileEncoding("UTF-8 BOM", .utf8, signature: [0xEF, 0xBB, 0xBF])
    static let utf16LEBOM = TextFileEncoding("UTF-16 LE (BOM)", .utf16LittleEndian, signature: [0xFF, 0xFE])
    static let utf16BEBOM = TextFileEncoding("UTF-16 BE (BOM)", .utf16BigEndian, signature: [0xFE, 0xFF])

    static let choices: [TextFileEncoding] = [
        .utf8, .utf8BOM, .utf16LEBOM, .utf16BEBOM,
        .gbk, .gb18030, .shiftJIS, .windows1252, .latin1,
    ]

    private static func iana(_ name: String) -> TextFileEncoding? {
        let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard value != kCFStringEncodingInvalidId else { return nil }
        let foundation = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        return TextFileEncoding(name, foundation)
    }

    private static func windows(codePage: UInt32) -> TextFileEncoding? {
        if codePage == 65001 { return .utf8 }
        let value = CFStringConvertWindowsCodepageToEncoding(codePage)
        guard value != kCFStringEncodingInvalidId else { return nil }
        let foundation = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        let name = codePage == 936 ? "GBK (CP936)" : "Windows-\(codePage)"
        return TextFileEncoding(name, foundation)
    }

    private var foundation: String.Encoding { .init(rawValue: rawValue) }
    var hasSignature: Bool { !signature.isEmpty }

    func encoded(_ text: String) -> Data? {
        guard let contents = text.data(using: foundation, allowLossyConversion: false),
              let recovered = String(data: contents, encoding: foundation),
              recovered.utf16.elementsEqual(text.utf16) else { return nil }
        return Data(signature) + contents
    }

    func decoded(_ bytes: Data) -> String? {
        guard bytes.starts(with: signature) else { return nil }
        let contents = signature.isEmpty ? bytes : Data(bytes.dropFirst(signature.count))
        guard let text = String(data: contents, encoding: foundation) else { return nil }
        if foundation == .utf16LittleEndian || foundation == .utf16BigEndian {
            guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        }
        // A strict UTF-8 decoder cannot map valid bytes to replacement characters.
        if foundation == .utf8 { return text }
        guard let roundtrip = text.data(using: foundation, allowLossyConversion: false),
              roundtrip == contents else { return nil }
        return text
    }

    private static func codingCookie(in bytes: Data) -> String? {
        // Python's declaration must occur in one of the first two physical lines.
        let head = bytes.prefix(512).split(separator: 10, omittingEmptySubsequences: false).prefix(2)
        let expression = try? NSRegularExpression(
            pattern: #"^\s*#.*?coding\s*[:=]\s*([-\w.]+)"#, options: .caseInsensitive
        )
        for line in head {
            let ascii = String(decoding: line, as: UTF8.self)
            let range = NSRange(ascii.startIndex..<ascii.endIndex, in: ascii)
            if let match = expression?.firstMatch(in: ascii, range: range),
               let name = Range(match.range(at: 1), in: ascii) {
                return String(ascii[name]).lowercased()
            }
        }
        return nil
    }

    static func contradictsDeclaration(_ text: String, chosen: TextFileEncoding) -> Bool {
        guard let name = codingCookie(in: Data(text.utf8)) else { return false }
        switch name.replacingOccurrences(of: "_", with: "-") {
        case "mbcs":
            return chosen != .gbk && !chosen.name.hasPrefix("Windows-")
        case "utf-8", "utf8":
            return chosen != .utf8 && chosen != .utf8BOM
        case "gbk", "gb2312", "cp936", "windows-936": return chosen != .gbk
        case "gb18030": return chosen != .gb18030
        case "shift-jis", "shiftjis", "cp932": return chosen != .shiftJIS
        case "cp1252", "windows-1252": return chosen != .windows1252
        case "latin-1", "iso-8859-1": return chosen != .latin1
        default: return true
        }
    }

    private static func declared(_ name: String, backend: WorkspaceBackend) async -> TextFileEncoding? {
        switch name.replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "cp936", "windows-936": return .gbk
        case "gb18030": return .gb18030
        case "shift-jis", "shiftjis", "cp932": return .shiftJIS
        case "cp1252", "windows-1252": return .windows1252
        case "latin-1", "iso-8859-1": return .latin1
        case "mbcs":
            // MBCS is the *remote Windows machine's* ANSI code page, not the Mac's locale.
            let result = try? await backend.run(
                argv: ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                       "[System.Text.Encoding]::Default.CodePage"],
                cwd: nil, env: nil, stdin: nil, timeout: 12
            )
            guard let result, result.status == 0,
                  let number = UInt32(String(decoding: result.stdout, as: UTF8.self)
                      .trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return windows(codePage: number)
        default: return nil
        }
    }

    enum DecodeFailure: Error, Sendable {
        case binary
        case unknownEncoding
        case unsupportedEncoding(String)
        case invalidContents(String)

        var message: String {
            switch self {
            case .binary: String(localized: "Binary file", table: "Workspace")
            case .unknownEncoding:
                String(localized: "Unknown text encoding. Choose an encoding to reopen.", table: "Workspace")
            case .unsupportedEncoding(let label):
                String(localized: "Cannot determine declared encoding: \(label). Choose an encoding.", table: "Workspace")
            case .invalidContents(let label):
                String(localized: "File bytes are not valid \(label) text.", table: "Workspace")
            }
        }
    }

    struct Document: Sendable {
        let text: String
        let encoding: TextFileEncoding
    }

    static func decode(
        _ bytes: Data, backend: WorkspaceBackend, override: TextFileEncoding? = nil
    ) async -> Result<Document, DecodeFailure> {
        let bom = bytes.starts(with: utf8BOM.signature) ? utf8BOM
            : bytes.starts(with: utf16LEBOM.signature) ? utf16LEBOM
            : bytes.starts(with: utf16BEBOM.signature) ? utf16BEBOM : nil
        let cookie = codingCookie(in: bytes)
        let chosen: TextFileEncoding
        if let override {
            chosen = override
        } else if let bom {
            chosen = bom
        } else if let cookie {
            guard let found = await declared(cookie, backend: backend) else {
                return .failure(.unsupportedEncoding(cookie))
            }
            chosen = found
        } else {
            chosen = .utf8
        }
        if chosen != utf16LEBOM && chosen != utf16BEBOM && bytes.contains(0) {
            return .failure(.binary)
        }
        if let text = chosen.decoded(bytes) {
            return .success(Document(text: text, encoding: chosen))
        }
        if bytes.contains(0) { return .failure(.binary) }
        if override == nil && cookie == nil && bom == nil {
            return .failure(.unknownEncoding)
        }
        return .failure(.invalidContents(chosen.name))
    }
}
