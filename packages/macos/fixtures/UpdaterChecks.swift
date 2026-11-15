import Foundation

// The updater's rules, run outside an app: the test hands this a file of cases (manifests signed
// with a real Ed25519 key, versions, strings, feeds, URLs) and compares each answer with what the
// JavaScript updater gives for the same input.
@main struct UpdaterChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: updater-checks <cases.json>") }
        // Read as the updater reads a feed: every string exactly as written.
        let cases = try CraftUpdateJSON.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any] ?? [:]
        func message(_ error: Error) -> String { (error as? CraftUpdateFailure)?.message ?? error.localizedDescription }

        let manifests: [[String: Any]] = (cases["manifests"] as? [[String: Any]] ?? []).map { item in
            var answer: [String: Any] = ["name": item["name"] ?? ""]
            // The canonical bytes of whatever parses, signed or not.
            if let parsed = try? CraftUpdateManifest(item["manifest"]) { answer["payload"] = parsed.payload.base64EncodedString() }
            do {
                let accepted = try CraftUpdateRules.accept(item["manifest"], trustedKeys: item["keys"] as? [String: String] ?? [:],
                    currentVersion: item["currentVersion"] as? String ?? "", architecture: item["architecture"] as? String ?? CraftUpdateRules.architecture)
                answer["outcome"] = accepted == nil ? "current" : "available"
                if let accepted { answer["version"] = accepted.version }
            } catch { answer["outcome"] = "error"; answer["error"] = message(error) }
            return answer
        }
        let versions: [Any] = (cases["versions"] as? [[String]] ?? []).map { pair in
            (try? CraftUpdateRules.compare(pair[0], pair[1])) as Any? ?? "error"
        }
        let strings = (cases["strings"] as? [String] ?? []).map(CraftUpdateRules.jsonString)
        let feeds: [String] = (cases["feeds"] as? [[String: String]] ?? []).map { feed in
            do { return try CraftUpdateRules.feedURL(feed["feed"] ?? "", architecture: feed["architecture"] ?? "", channel: feed["channel"] ?? "", currentVersion: feed["currentVersion"] ?? "").absoluteString }
            catch { return "error: \(message(error))" }
        }
        let urls = (cases["urls"] as? [String] ?? []).map { (try? CraftUpdateRules.assertSecure($0)) != nil }
        // The swap on a volume that cannot exchange two folders in one step: aside, in, and back on failure.
        let swaps: [String] = (cases["swaps"] as? [[String: String]] ?? []).map { swap in
            do { try CraftMacUpdater.swap(URL(fileURLWithPath: swap["next"] ?? ""), into: URL(fileURLWithPath: swap["bundle"] ?? ""), exchange: swap["exchange"] == "yes"); return "swapped" }
            catch { return "error: \(message(error))" }
        }
        let output: [String: Any] = ["architecture": CraftUpdateRules.architecture, "swaps": swaps, "manifests": manifests, "versions": versions, "strings": strings, "feeds": feeds, "urls": urls]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
