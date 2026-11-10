// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Includes work from BCD by thebcd69.
//
//  MCDRules.swift
//
//  MCD's own recommended lines, kept apart from BCD's list so that list stays exactly as BCD
//  signed it (and BCD's online updates keep arriving). recommended/mcd-rules.json, a bundle
//  resource, names BCD rules by id and the lines MCD adds after them:
//
//    {"format": 1, "version": 1, "add": [{"id": "valheim", "lines": ["env.MADEIRA_PAD_MODE = dualsense"], "note": "..."}]}
//
//  GameRecommendations.recommendation(windowsPath:steamAppID:) (GameRecommendationsApply.swift,
//  the "MCD:" line) passes each matched rule through `adding(to:)`. The game's file then holds
//  BCD's lines and, after them, "# MCD (Mobile Claw Deck):" and MCD's. What was written is
//  recorded with a hash of that text, so a line added or changed here reaches every game whose
//  file nobody edited, exactly as a newer BCD rule does; a file the player changed keeps theirs.
//
//  No file, or one that does not read: nothing is added (BCD's behaviour), and the log says why.
//  tests/host/check-mcd-rules.py checks the file (keys in the settings catalog, ids in BCD's list).
//  Log tag: [mcd-rules].

import Foundation

enum MCDRules {
    static let header = "# MCD (Mobile Claw Deck):"

    /// rule id -> the lines MCD adds after that rule's own.
    static let additions: [String: [String]] = load()

    /// `rec` with MCD's lines for its id after its own config; `rec` itself when MCD adds none.
    /// `table`: the bundled file's (a host check passes its own).
    static func adding(to rec: GameRecommendation, from table: [String: [String]]? = nil) -> GameRecommendation {
        guard let lines = (table ?? additions)[rec.id], !lines.isEmpty else { return rec }
        var text = rec.config
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += header + "\n" + lines.joined(separator: "\n") + "\n"
        var copy = rec
        copy.config = text
        return copy
    }

    private static func load() -> [String: [String]] {
        guard let url = Bundle.main.url(forResource: "mcd-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let parsed = try parse(data)
            LogStore.shared.log("[mcd-rules] \(parsed.count) rule\(parsed.count == 1 ? "" : "s") with MCD lines: "
                                + parsed.keys.sorted().joined(separator: ", "))
            return parsed
        } catch {
            LogStore.shared.log("[mcd-rules] mcd-rules.json not used: \(error)", level: .error)
            return [:]
        }
    }

    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ data: Data) throws -> [String: [String]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError(description: "not a JSON object")
        }
        guard let format = root["format"] as? Int, format == 1 else { throw FormatError(description: "format is not 1") }
        guard let entries = root["add"] as? [[String: Any]] else { throw FormatError(description: "no \"add\" list") }
        var out: [String: [String]] = [:]
        for (i, entry) in entries.enumerated() {
            guard let id = entry["id"] as? String, !id.isEmpty else { throw FormatError(description: "add[\(i)]: no id") }
            guard let lines = entry["lines"] as? [String], !lines.isEmpty else {
                throw FormatError(description: "add[\(i)] (\(id)): no lines")
            }
            guard out[id] == nil else { throw FormatError(description: "add[\(i)]: \(id) twice") }
            for line in lines where line.contains("\n") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                throw FormatError(description: "add[\(i)] (\(id)): an empty or multi-line line")
            }
            out[id] = lines
        }
        return out
    }
}
