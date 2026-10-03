"""Index tracked migration surfaces without importing Flutter or touching user data.

This is a source navigation index, not a Dart/Swift parser or a parity proof.
Generated reports live in build/native-migration and contain no runtime secrets.
"""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-migration"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def matches(source, pattern):
    return [dict(line=source.count("\n", 0, match.start()) + 1,
                 declaration=" ".join(match.group(0).split()))
            for match in re.finditer(pattern, source, re.MULTILINE)]


def main():
    tracked = git("ls-files").splitlines()
    areas = {
        "http": "lib/http/", "grpc": "lib/grpc/", "tcp": "lib/tcp/",
        "models": "lib/models/", "models_new": "lib/models_new/",
        "services": "lib/services/", "utils": "lib/utils/",
        "features": "lib/pages/", "routing": "lib/router/",
        "ios": "ios/Runner/", "engine": "Packages/AetherEngine/",
    }
    inventory = {}
    for area, prefix in areas.items():
        entries = []
        for name in tracked:
            if not name.startswith(prefix) or not name.endswith((".dart", ".swift", ".m", ".h")):
                continue
            source = (ROOT / name).read_text(encoding="utf-8-sig")
            generated = name.endswith((".g.dart", ".pb.dart", ".pbjson.dart", ".pbenum.dart"))
            entry = dict(path=name, lines=len(source.splitlines()), generated=generated)
            if not generated:
                entry["imports"] = matches(source, r"^(?:import .*|#import .*)$")
                entry["types"] = matches(source, r"^(?:@\w+\s+)?(?:(?:private|final|abstract|sealed|base|public|internal)\s+)*(?:class|struct|enum|protocol|mixin|extension)\s+[^\n{]+")
                entry["operations"] = matches(source, r"^\s+(?:(?:static|private|public|override|final)\s+)*(?:Future(?:<[^\n]+>)?|Stream(?:<[^\n]+>)?|void|func)\s+\w+[^\n]*")
            entries.append(entry)
        inventory[area] = entries

    bridge = (ROOT / "lib/services/ios_native_ui_bridge.dart").read_text(encoding="utf-8")
    handler = bridge[bridge.index("  Future<dynamic> _handleNativeCall("):
                     bridge.index("  Map<String, dynamic>? _cachedFetch(")]
    commands = re.findall(r"case '([^']+)':", handler)
    route_source = (ROOT / "lib/router/app_pages.dart").read_text(encoding="utf-8")
    routes = matches(route_source, r"\bname:\s*['\"][^'\"]+['\"]")
    endpoints = {}
    for name in ("lib/http/api.dart", "lib/grpc/url.dart"):
        endpoints[name] = matches((ROOT / name).read_text(encoding="utf-8"),
                                 r"^\s+static const\s+(?:String\s+)?\w+\s*=[^;]+;")
    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    dependencies = pubspec.split("\ndependencies:\n", 1)[1].split("\ndev_dependencies:", 1)[0]
    dependencies = re.findall(r"^  ([a-zA-Z_][\w]*):", dependencies, re.MULTILINE)

    summary = dict(commit=git("rev-parse", "HEAD"),
                   areas={area: dict(files=len(entries), lines=sum(e["lines"] for e in entries),
                                     generatedFiles=sum(e["generated"] for e in entries))
                          for area, entries in inventory.items()},
                   bridgeCommands=commands, flutterRoutes=routes,
                   dependencies=dependencies,
                   note="Source index only; read controllers and call sites before declaring parity.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, report in (("inventory.json", inventory), ("summary.json", summary), ("endpoints.json", endpoints)):
        (OUTPUT / name).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(commit=summary["commit"], areas=summary["areas"],
                          bridgeCommands=len(commands), flutterRoutes=len(routes),
                          dependencies=len(dependencies), output=str(OUTPUT)), indent=2))


if __name__ == "__main__":
    main()
