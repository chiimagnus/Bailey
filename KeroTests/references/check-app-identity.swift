import Foundation

@main
enum AppIdentityCheck {
    static func main() throws {
        let stable = AppIdentity(bundleIdentifier: "chiimagnus.kero")
        let development = AppIdentity(bundleIdentifier: "chiimagnus.kero.dev")
        let home = FileManager.default.homeDirectoryForCurrentUser
        precondition(stable.displayName == "Kero" && development.displayName == "Kero Dev")
        precondition(stable.configDirectory == home.appendingPathComponent(".config/kero", isDirectory: true))
        precondition(development.configDirectory == home.appendingPathComponent(".config/kero-dev", isDirectory: true))
        precondition(stable.historyDirectory.lastPathComponent == "kero")
        precondition(development.historyDirectory.lastPathComponent == "kero-dev")
        precondition(stable.isolatedDefaultsSuite == "chiimagnus.kero.isolated-ui-test")
        precondition(development.isolatedDefaultsSuite == "chiimagnus.kero.dev.isolated-ui-test")
        precondition(stable.configDirectory != development.configDirectory)
        precondition(stable.historyDirectory != development.historyDirectory)
        for path in CommandLine.arguments.dropFirst() {
            let app = URL(fileURLWithPath: path, isDirectory: true)
            let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let identifier = info["CFBundleIdentifier"] as! String
            precondition([stable.bundleIdentifier, development.bundleIdentifier].contains(identifier))
            let expected = AppIdentity(bundleIdentifier: identifier).displayName
            precondition(info["CFBundleName"] as? String == expected)
            precondition(info["CFBundleDisplayName"] as? String == expected)
            precondition(info["CFBundleExecutable"] as? String == "kero")
            precondition(info["LSMinimumSystemVersion"] as? String == "15.6")
            let services = info["NSServices"] as! [[String: Any]]
            let serviceName = services[0]["NSMenuItem"] as! [String: String]
            precondition(serviceName["default"] == "Add Folder to " + expected)
            for language in ["en", "zh-Hans"] {
                let strings = app.appendingPathComponent("Contents/Resources/\(language).lproj/InfoPlist.strings")
                let localizedData = try Data(contentsOf: strings)
                let localized = try PropertyListSerialization.propertyList(from: localizedData, format: nil) as! [String: String]
                for key in ["CFBundleName", "CFBundleDisplayName"] {
                    precondition(localized[key] == nil || localized[key] == expected)
                }
            }
            print("PASS: built \(expected) identity, executable, deployment target, service and bilingual bundle names")
        }
        print("PASS: stable storage compatibility and separate development config/history/defaults identities")
    }
}
