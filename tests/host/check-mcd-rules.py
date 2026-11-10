#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Includes work from BCD by thebcd69.
"""MCD's own recommended lines (recommended/mcd-rules.json, app/Madeira/MCDRules.swift).

  1. BCD's list is exactly as BCD signed it: recommendations.json verifies against
     recommendations.json.sig under the app's public key (GameRecommendationsSource.swift). An MCD
     edit there would make every MCD install refuse BCD's next online list (a rule at a lower version
     than the built-in one is a regression, GameRecommendationsList.swift), so MCD's lines live here.
  2. mcd-rules.json reads: format 1, a version, every id is a rule in BCD's list, once; every line
     is a comment or "key = value" whose key the settings catalog has (ConfigCatalog.generated.swift).
  3. The wiring: the one "MCD:" hook in GameRecommendations.recommendation(windowsPath:steamAppID:),
     GameRecommendation.config a var, the resource name, both files in the app target (the way
     recommendations.json and the MCD Cloud files are), check-game-recommendations.py compiling
     MCDRules.swift with the apply code.
  4. With swiftc (macOS CI: --require-swift): MCDRules.swift compiled with stand-ins reads the real
     file and adds the lines after a rule's own, with the header; a rule MCD names nothing for, and
     a bad file, change nothing.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'app' / 'Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


# 1. BCD's list, as BCD signed it.
spec = importlib.util.spec_from_file_location('publish_recommendations', ROOT / 'tools' / 'publish-recommendations.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
key = tool.app_public_key(APP / 'GameRecommendationsSource.swift')
bcd_bytes = (ROOT / 'recommended' / 'recommendations.json').read_bytes()
signature = tool.signature_from_file((ROOT / 'recommended' / 'recommendations.json.sig').read_bytes())
check(key is not None and signature is not None and tool.verify(key, bcd_bytes, signature),
      "recommendations.json is byte for byte what BCD signed (its .sig verifies under the app's key); MCD's lines go in mcd-rules.json")
bcd = json.loads(bcd_bytes)
bcd_ids = {rule['id'] for rule in bcd['rules']}

# 2. MCD's file.
rules_path = ROOT / 'recommended' / 'mcd-rules.json'
mcd = json.loads(rules_path.read_text())
catalog = (APP / 'ConfigCatalog.generated.swift').read_text()
catalog_keys = set(re.findall(r'ConfigOption\(key: "([^"]+)"', catalog))
check(mcd.get('format') == 1 and isinstance(mcd.get('version'), int) and isinstance(mcd.get('add'), list) and mcd['add'],
      'mcd-rules.json: format 1, a version number, a non-empty "add" list')
seen = set()
for i, entry in enumerate(mcd.get('add', [])):
    rid = entry.get('id')
    check(rid in bcd_ids, f'add[{i}] names a rule BCD has ({rid})')
    check(rid not in seen, f'add[{i}] ({rid}) appears once')
    seen.add(rid)
    lines = entry.get('lines')
    check(isinstance(lines, list) and lines and all(isinstance(x, str) for x in lines), f'add[{i}] ({rid}) has lines')
    for line in lines or []:
        stripped = line.strip()
        if stripped.startswith('#'):
            continue
        m = re.match(r'^([A-Za-z0-9_.\-]+)\s*=\s*\S', stripped)
        check(m is not None and '\n' not in line, f'{rid}: "{line}" is one key = value line')
        if m:
            check(m.group(1) in catalog_keys, f'{rid}: {m.group(1)} is a key the settings catalog has')
        bcd_rule = next(r for r in bcd['rules'] if r['id'] == rid) if rid in bcd_ids else None
        if bcd_rule is not None:
            own = [x if isinstance(x, str) else x['line'] for x in bcd_rule['config']]
            check(line not in own, f'{rid}: "{line}" is not already one of BCD\'s lines')
check(any(e.get('id') == 'valheim' and 'env.MADEIRA_PAD_MODE = dualsense' in e.get('lines', []) for e in mcd.get('add', [])),
      "Valheim's controller line (the owner's Kishi Ultra test, 2026-10-31) is MCD's")

# 3. The wiring.
apply_src = (APP / 'GameRecommendationsApply.swift').read_text()
recs_src = (APP / 'GameRecommendations.swift').read_text()
rules_src = (APP / 'MCDRules.swift').read_text()
fallback = apply_src[apply_src.index('    static func recommendation(windowsPath: String, steamAppID: Int?) -> GameRecommendation? {'):]
fallback = fallback[:fallback.index('\n    }\n')]
check('fileExists: driveFileExists) { return MCDRules.adding(to: rec) }   // MCD:' in fallback
      and apply_src.count('MCDRules.') == 1, 'the one hook: every matched rule passes through MCDRules.adding(to:)')
check('    var config: String   // MCD:' in recs_src and '    let config: String' not in recs_src,
      'GameRecommendation.config is a var (MCD:)')
check('Bundle.main.url(forResource: "mcd-rules", withExtension: "json")' in rules_src
      and 'static let header = "# MCD (Mobile Claw Deck):"' in rules_src, 'MCDRules reads the bundled mcd-rules.json')
project = (ROOT / 'app' / 'Madeira.xcodeproj' / 'project.pbxproj').read_text()
check(project.count('/* MCDRules.swift in Sources */') == 2 and project.count('/* MCDRules.swift */') == 3,
      'MCDRules.swift is in the app target (build file, Sources phase, reference, group)')
check(project.count('/* mcd-rules.json in Resources */') == 2 and project.count('/* mcd-rules.json */') == 3
      and 'path = "../recommended/mcd-rules.json"; sourceTree = SOURCE_ROOT;' in project,
      'mcd-rules.json is a resource of the app target, from recommended/')
gr_check = (ROOT / 'tests' / 'host' / 'check-game-recommendations.py').read_text()
check("'ConfigCatalog.generated.swift', 'MCDRules.swift')]" in gr_check, "BCD's rules fixture compiles MCDRules.swift with the apply code")

# 4. The Swift.
main = r'''
import Foundation
final class LogStore {
    static let shared = LogStore()
    enum Level { case info, error }
    var lines: [String] = []
    func log(_ message: String, level: Level = .info) { lines.append(message) }
}
struct GameRecommendation { let id: String; var config: String }
var failed = 0
func expect(_ ok: Bool, _ label: String) { print((ok ? "PASS: " : "FAIL: ") + label); if !ok { failed += 1 } }
let real = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let parsed = try! MCDRules.parse(real)
expect(parsed["valheim"] == ["env.MADEIRA_PAD_MODE = dualsense"], "the real file reads; Valheim gets its controller line")
let rec = GameRecommendation(id: "valheim", config: "# BCD\nenv.MADEIRA_EC_HOOK_TRACE = 0")
expect(MCDRules.adding(to: rec, from: parsed).config
       == "# BCD\nenv.MADEIRA_EC_HOOK_TRACE = 0\n# MCD (Mobile Claw Deck):\nenv.MADEIRA_PAD_MODE = dualsense\n",
       "adding(to:) puts the header and MCD's lines after the rule's own")
let ended = GameRecommendation(id: "valheim", config: "a = 1\n")
expect(MCDRules.adding(to: ended, from: parsed).config == "a = 1\n# MCD (Mobile Claw Deck):\nenv.MADEIRA_PAD_MODE = dualsense\n",
       "a config that already ends with a newline gets no blank line")
expect(MCDRules.adding(to: GameRecommendation(id: "no-such-rule", config: "a = 1"), from: parsed).config == "a = 1",
       "a rule MCD names nothing for is unchanged")
expect(MCDRules.adding(to: rec).config == rec.config, "no bundle resource here: nothing is added (BCD's behaviour)")
for bad in ["[]", "{\"format\": 2, \"add\": []}", "{\"format\": 1}", "{\"format\": 1, \"add\": [{\"id\": \"x\"}]}",
            "{\"format\": 1, \"add\": [{\"id\": \"x\", \"lines\": [\"a = 1\"]}, {\"id\": \"x\", \"lines\": [\"b = 2\"]}]}",
            "{\"format\": 1, \"add\": [{\"id\": \"x\", \"lines\": [\"a = 1\\nb = 2\"]}]}"] {
    expect((try? MCDRules.parse(Data(bad.utf8))) == nil, "refused: \(bad)")
}
if failed > 0 { exit(1) }
'''
compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if compiler:
    with tempfile.TemporaryDirectory(prefix='mcd-rules-') as directory:
        (Path(directory) / 'main.swift').write_text(main)
        binary = Path(directory) / 'rules'
        built = subprocess.run([compiler, str(APP / 'MCDRules.swift'), str(Path(directory) / 'main.swift'), '-o', str(binary)],
                               capture_output=True, text=True)
        check(built.returncode == 0, 'MCDRules.swift compiles with stand-ins')
        if built.returncode:
            print(built.stderr[-3000:])
        else:
            result = subprocess.run([str(binary), str(rules_path)], capture_output=True, text=True)
            print(result.stdout + result.stderr, end='')
            check(result.returncode == 0, 'MCDRules behaves')
elif args.require_swift:
    raise SystemExit('Swift compiler required for MCDRules')
else:
    print('SKIP: Swift compiler unavailable locally; MCD pre-flight runs this with --require-swift')

if failures:
    raise SystemExit(f'{failures} check(s) failed')
print('check-mcd-rules: all passed')
