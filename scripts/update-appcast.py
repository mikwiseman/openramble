#!/usr/bin/env python3
"""Post release to Sparkle update feed.

Feed (appcast) - a regular RSS file with a list of versions. Sparkle downloads it,
looks at the most recent entry and checks the image signature against the public key
from Info.plist. Everything else in the file is for people reading the feed.

Why a separate script, and not generate_appcast from Sparkle: it collects the feed
from the folder with images and writes its own release descriptions. We need
English "what's new" text and exactly one entry per version.

It is launched from scripts/release.sh, the parameters come from environment variables.
"""

from __future__ import annotations

import html
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"update-appcast: {name} variable not set")
    return value


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def notes_to_html(text: str) -> str:
    """Turn notes into simple markup.

    Markdown headings become HTML headings, lines starting with “-” become lists,
    and the rest become paragraphs.
    Nothing else is intentionally supported: the release notes are not the place for
    layout, and full-fledged markdown would entail a dependency.
    """
    blocks: list[str] = []
    bullets: list[str] = []

    def flush() -> None:
        if bullets:
            items = "".join(f"<li>{html.escape(item)}</li>" for item in bullets)
            blocks.append(f"<ul>{items}</ul>")
            bullets.clear()

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            flush()
        elif line.startswith(("- ", "* ")):
            bullets.append(line[2:].strip())
        elif line.startswith("# "):
            flush()
            blocks.append(f"<h2>{html.escape(line[2:].strip())}</h2>")
        else:
            flush()
            blocks.append(f"<p>{html.escape(line)}</p>")
    flush()

    return "".join(blocks)


def build_number(item: ET.Element) -> int:
    """Record build number. It’s also the key: one version - one record."""
    node = item.find(sparkle("version"))
    if node is None or node.text is None:
        return -1
    try:
        return int(node.text.strip())
    except ValueError:
        return -1


def load_channel(path: Path, title: str, feed_url: str) -> tuple[ET.ElementTree, ET.Element]:
    if path.exists():
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            sys.exit(f"update-appcast: there is no <channel> in {path} - fix the file manually")
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = feed_url
    ET.SubElement(channel, "description").text = f"Updates {title}"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss), channel


def main() -> None:
    appcast = Path(required("APPCAST"))
    notes_path = Path(required("NOTES_PATH"))
    version = required("VERSION")
    build = int(required("BUILD"))
    minimum_os = required("MIN_OS")
    feed_url = required("FEED_URL")
    dmg_url = required("DMG_URL")
    length = required("LENGTH")
    signature = required("SIGNATURE")
    app_name = required("APP_NAME")
    keep = int(os.environ.get("KEEP_ITEMS", "10"))

    tree, channel = load_channel(appcast, app_name, feed_url)
    items = channel.findall("item")

    # The build number must increase: Sparkle compares it, and the version
    # with a lower number simply won’t arrive for anyone.
    newest = max((build_number(item) for item in items), default=-1)
    if build < newest:
        sys.exit(
            f"update-appcast: build {build} is smaller than already published {newest}.\n"
            "Raise CURRENT_PROJECT_VERSION in apps/macos/project.yml."
        )
    if build == newest:
        print(f" assembly {build} is already in the feed - I’m replacing the entry")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = format_datetime(
        datetime.now(timezone.utc).astimezone()
    )
    ET.SubElement(item, sparkle("version")).text = str(build)
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = minimum_os
    ET.SubElement(item, "description").text = notes_to_html(
        notes_path.read_text(encoding="utf-8")
    )
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": dmg_url,
            "length": length,
            "type": "application/octet-stream",
            sparkle("edSignature"): signature,
        },
    )

    # Re-release of the same assembly should not leave a duplicate in the feed.
    for old in items:
        if build_number(old) == build:
            channel.remove(old)

    # Fresh - first, then the rest of the entries in the same order.
    children = list(channel)
    remaining = channel.findall("item")
    channel.insert(children.index(remaining[0]) if remaining else len(children), item)

    for extra in channel.findall("item")[keep:]:
        channel.remove(extra)

    ET.indent(tree, space="  ")
    appcast.parent.mkdir(parents=True, exist_ok=True)
    tree.write(appcast, encoding="utf-8", xml_declaration=True)
    with appcast.open("a", encoding="utf-8") as handle:
        handle.write("\n")

    print(f" wrote version {version} (build {build}) to {appcast}")


if __name__ == "__main__":
    main()
