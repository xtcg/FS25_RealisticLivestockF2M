"""Rasterize the editable handbook: FS25's UI font omits many Chinese farm terms.

Requires Pillow. Run with a local Chinese font (the font itself is NOT packaged):
  python tools/build_player_manual.py --font /path/to/ChineseFont.ttc

The XML remains the source of truth; shipped DDS atlases preserve its characters.
"""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SIZE = 2048


def wrap(text, font):
    lines = []
    for source_line in text.split("\n"):
        line = ""
        for character in source_line:
            if line and font.getlength(line + character) > SIZE - 16:
                # Prefer a space for English; CJK can break between characters.
                split = line.rfind(" ")
                if split > len(line) // 2:
                    lines.append(line[:split])
                    line = line[split + 1:] + character
                else:
                    lines.append(line)
                    line = character
            else:
                line += character
        lines.append(line)
    return lines


def build(font_path):
    path = ROOT / "xml/playerManual_cs.xml"
    tree = ET.parse(path)
    output = ROOT / "gui/rlmenu/manual"
    output.mkdir(exist_ok=True)
    fonts = {False: ImageFont.truetype(font_path, 36), True: ImageFont.truetype(font_path, 44)}
    atlas = Image.new("RGBA", (SIZE, SIZE))
    atlas_index, y, count = 1, 0, 0

    def save():
        atlas.save(output / f"text_{atlas_index:03}.dds", pixel_format="DXT5")

    for chapter in tree.getroot():
        for paragraph in chapter:
            heading = paragraph.get("heading") == "true"
            font = fonts[heading]
            lines = wrap(paragraph.get("text", ""), font)
            pitch = 60 if heading else 52
            height = ((len(lines) * pitch + 16 + 3) // 4) * 4
            if height > SIZE:
                raise ValueError("Paragraph too tall; split it in playerManual_cs.xml")
            if y + height > SIZE:
                save()
                atlas_index += 1
                y = 0
                atlas = Image.new("RGBA", (SIZE, SIZE))
            draw = ImageDraw.Draw(atlas)
            for number, line in enumerate(lines):
                draw.text((8, y + 8 + number * pitch), line, font=font, fill=(230, 236, 230, 255), anchor="lt")
            paragraph.set("image", f"gui/rlmenu/manual/text_{atlas_index:03}.dds")
            paragraph.set("imageY", str(y))
            paragraph.set("imageHeight", str(height))
            y += height
            count += 1
    save()
    ET.indent(tree)
    tree.write(path, encoding="utf-8", xml_declaration=True)
    print(f"{count} paragraphs in {atlas_index} DDS atlases")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", required=True)
    build(parser.parse_args().font)
