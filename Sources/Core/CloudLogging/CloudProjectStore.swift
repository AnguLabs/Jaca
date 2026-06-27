import Foundation

/// How many distinct example values of a label key to feed the Claude SQL assistant, per label.
/// The samples teach the model each label's format; the default is just **one** (enough to show
/// the shape) so a high-cardinality key like `user_id` doesn't flood the prompt. Set `all` for a
/// low-cardinality key (e.g. `tag`) where seeing every value is genuinely useful.
struct LabelExampleRule: Codable, Sendable, Hashable {
    var all: Bool
    var count: Int

    static let `default` = LabelExampleRule(all: false, count: 1)

    init(all: Bool = false, count: Int = 1) {
        self.all = all
        self.count = max(1, count)
    }

    enum CodingKeys: String, CodingKey { case all, count }

    /// Migration-safe decode (defaults for any missing key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        all = try c.decodeIfPresent(Bool.self, forKey: .all) ?? false
        count = max(1, try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
    }
}

/// A configured GCP project + its global (per-project) Cloud Logging state. Persisted to
/// `~/.jaca/cloud-logging/projects.json`. The `selectedLogName`, cached `logNames`, and
/// auto-detected label keys are deliberately *global per project* (req 7): every open
/// session for the project reads them, so switching the log name in one tab is reflected
/// everywhere.
struct CloudProject: Codable, Sendable, Hashable, Identifiable {
    var projectID: String
    var displayName: String = ""
    /// Currently selected full log name (`projects/<id>/logs/<encoded>`), shared by all sessions.
    var selectedLogName: String?
    /// Cached list of available full log names (from `gcloud logging logs list`).
    var logNames: [String] = []
    /// Auto-detected label keys, cached per log name (req 9.3).
    var labelKeysByLogName: [String: [String]] = [:]
    /// Favorited label keys, per log name — pinned to the top of the label-key list.
    var favoriteLabelKeysByLogName: [String: [String]] = [:]
    /// How many example values per label key to send to the Claude SQL assistant, per log name.
    /// A key with no entry uses `LabelExampleRule.default` (one example).
    var labelExampleRulesByLogName: [String: [String: LabelExampleRule]] = [:]

    var id: String { projectID }
    /// What the sidebar/tab shows: the display name if set, else the raw id.
    var title: String { displayName.isEmpty ? projectID : displayName }

    /// Label keys detected for the currently selected log name (or the project-wide bucket,
    /// keyed by "", when no log name is selected — so the labels system works either way).
    var currentLabelKeys: [String] {
        labelKeysByLogName[selectedLogName ?? ""] ?? []
    }

    /// Favorited label keys for the currently selected log name.
    var currentFavoriteLabelKeys: [String] {
        favoriteLabelKeysByLogName[selectedLogName ?? ""] ?? []
    }

    /// Label example rules for the currently selected log name.
    var currentLabelExampleRules: [String: LabelExampleRule] {
        labelExampleRulesByLogName[selectedLogName ?? ""] ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case projectID, displayName, selectedLogName, logNames, labelKeysByLogName,
             favoriteLabelKeysByLogName, labelExampleRulesByLogName
    }
}

extension CloudProject {
    /// Migration-safe decode: every field except `projectID` falls back to its default when the
    /// key is missing, so adding a field in a new release never drops an existing projects.json.
    /// (Swift's synthesized decoder ignores property defaults for missing keys — the bug this
    /// guards against.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(String.self, forKey: .projectID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        selectedLogName = try c.decodeIfPresent(String.self, forKey: .selectedLogName)
        logNames = try c.decodeIfPresent([String].self, forKey: .logNames) ?? []
        labelKeysByLogName = try c.decodeIfPresent([String: [String]].self, forKey: .labelKeysByLogName) ?? [:]
        favoriteLabelKeysByLogName = try c.decodeIfPresent([String: [String]].self, forKey: .favoriteLabelKeysByLogName) ?? [:]
        labelExampleRulesByLogName = try c.decodeIfPresent([String: [String: LabelExampleRule]].self, forKey: .labelExampleRulesByLogName) ?? [:]
    }
}

/// On-disk store for cloud project configs. Lives under `~/.jaca/` (per the product spec —
/// easy to inspect/edit by hand), with atomic writes. Mirrors `ProjectsCache` /
/// `CompanionDeviceStore`.
struct CloudProjectStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".jaca", isDirectory: true)
                .appendingPathComponent("cloud-logging", isDirectory: true)
                .appendingPathComponent("projects.json")
        }
    }

    func load() -> [CloudProject] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return CloudPersistence.decodeArray(CloudProject.self, from: data)
    }

    func save(_ projects: [CloudProject]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
