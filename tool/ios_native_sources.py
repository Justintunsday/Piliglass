"""Expand native source fragments for the existing single-file preview harnesses.

Production builds compile each registered Swift file independently. The preview
fixtures still slice sections of Root, so source markers retain their original
ordering as components move into Native. Only top-level access is made private
for the fixture compilation unit; implementation bodies come from production.
This reader is not a substitute for the complete Runner build in ios.yml.
"""

from pathlib import Path
import re


RUNNER = Path(__file__).resolve().parents[1] / "ios/Runner"
MARKER = re.compile(r"^// @native-source (Native/[\w/+]+\.swift)$", re.MULTILINE)


def read_native_root():
    source = (RUNNER / "PiliNativeRootViewController.swift").read_text(encoding="utf-8")

    def fragment(match):
        path = RUNNER / match.group(1)
        content = path.read_text(encoding="utf-8")
        content = re.sub(r"^import [^\n]+\n", "", content, flags=re.MULTILINE).strip()
        content = re.sub(
            r"^(let|enum|struct|extension|func|protocol|final class) ", r"private \1 ", content,
            flags=re.MULTILINE,
        )
        return content + "\n"

    return MARKER.sub(fragment, source)
