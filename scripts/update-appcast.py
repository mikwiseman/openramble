#!/usr/bin/env python3
"""Записать выпуск в ленту обновлений Sparkle.

Лента (appcast) — обычный RSS-файл со списком версий. Sparkle скачивает его,
смотрит на самую свежую запись и сверяет подпись образа с публичным ключом
из Info.plist. Всё остальное в файле — для человека.

Зачем отдельный скрипт, а не generate_appcast из Sparkle: тот собирает ленту
из папки с образами и пишет описания сам. Нам нужны свои тексты «что нового»
по-русски и ровно одна запись на версию.

Запускается из scripts/release.sh, параметры приходят переменными окружения.
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
        sys.exit(f"update-appcast: не задана переменная {name}")
    return value


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def notes_to_html(text: str) -> str:
    """Превратить заметки в простую разметку.

    Строки, начинающиеся с «- », становятся списком, остальные — абзацами.
    Больше ничего не поддерживается намеренно: описание релиза не место для
    вёрстки, а полноценный markdown потянул бы за собой зависимость.
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
        else:
            flush()
            blocks.append(f"<p>{html.escape(line)}</p>")
    flush()

    return "".join(blocks)


def build_number(item: ET.Element) -> int:
    """Номер сборки записи. Он же ключ: одна версия — одна запись."""
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
            sys.exit(f"update-appcast: в {path} нет <channel> — почините файл руками")
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = feed_url
    ET.SubElement(channel, "description").text = f"Обновления {title}"
    ET.SubElement(channel, "language").text = "ru"
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

    # Номер сборки обязан расти: Sparkle сравнивает именно его, и версия
    # с меньшим номером просто никому не приедет.
    newest = max((build_number(item) for item in items), default=-1)
    if build < newest:
        sys.exit(
            f"update-appcast: сборка {build} меньше уже опубликованной {newest}.\n"
            "Поднимите CURRENT_PROJECT_VERSION в apps/macos/project.yml."
        )
    if build == newest:
        print(f"  сборка {build} уже есть в ленте — заменяю запись")

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

    # Перевыпуск той же сборки не должен оставлять в ленте дубль.
    for old in items:
        if build_number(old) == build:
            channel.remove(old)

    # Свежее — первым, следом остальные записи в прежнем порядке.
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

    print(f"  записал версию {version} (сборка {build}) в {appcast}")


if __name__ == "__main__":
    main()
