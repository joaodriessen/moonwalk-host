import Foundation

public enum InstallationLocation {
    public static func isInstalled(_ bundle: URL, home: URL) -> Bool {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")].contains {
            path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }
    }
}
