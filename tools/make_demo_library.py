"""Generate a demo music library for screenshots: silent MP3s with fictional
artists, albums and generated cover art. Nothing here is real music.

Usage: python tools/make_demo_library.py OUT_DIR
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

FONT = "/System/Library/Fonts/Helvetica.ttc"

# album, artist, genre, year, (gradient colours), tracks [(title, seconds)]
ALBUMS = [
    ("Neon Harbour", "The Paper Satellites", "Synthpop", 2023, ("0xff3d7f", "0x5b2bd6", "0x0b1a4a"),
     [("Signal Fires", 214), ("Glass Coastline", 247), ("Radio Lighthouse", 199), ("Afterglow Parade", 263)]),
    ("Slow Tides", "Mira Solenne", "Ambient", 2021, ("0x9fe8ff", "0x3a7bd5", "0x0f2b46"),
     [("Low Water", 281), ("Salt & Silver", 236), ("The Long Quiet", 302)]),
    ("Kerosene Summer", "Velvet Orchard", "Indie Rock", 2019, ("0xffb347", "0xff5e3a", "0x5a1a1a"),
     [("Porchlight", 188), ("Cherry Static", 205), ("Highway Psalm", 241), ("Paper Crowns", 222)]),
    ("Monsoon Letters", "Arun & The Lanterns", "World", 2022, ("0x7ee8a2", "0x1d976c", "0x0b3d2e"),
     [("First Rain", 257), ("Kite Season", 219), ("Lantern Road", 268)]),
    ("Midnight Arcade", "Pixel Parade", "Electronic", 2024, ("0xf9f871", "0xff6ec7", "0x3d1f6e"),
     [("Insert Coin", 176), ("Bonus Level", 233)]),
]


def run(*args: str) -> None:
    subprocess.run(args, check=True, capture_output=True)


def cover(path: Path, title: str, artist: str, colours: tuple[str, str, str]) -> None:
    """Gradient from ffmpeg, title and artist drawn with Pillow."""
    from PIL import Image, ImageDraw, ImageFont

    c0, c1, c2 = colours
    run("ffmpeg", "-v", "error", "-y", "-f", "lavfi",
        "-i", f"gradients=s=600x600:c0={c0}:c1={c1}:c2={c2}:n=3:x0=0:y0=0:x1=600:y1=600:d=1",
        "-frames:v", "1", "-vf", "vignette=PI/5", str(path))
    image = Image.open(path).convert("RGB")
    draw = ImageDraw.Draw(image)
    big = ImageFont.truetype(FONT, 46, index=1)    # Helvetica Bold
    small = ImageFont.truetype(FONT, 28, index=0)  # Helvetica
    draw.text((48, 600 - 150), title.upper(), font=big, fill=(255, 255, 255))
    draw.text((48, 600 - 88), artist, font=small, fill=(255, 255, 255, 190))
    image.save(path, quality=92)


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for album, artist, genre, year, colours, tracks in ALBUMS:
        art = out / f"{album}.jpg"
        cover(art, album, artist, colours)
        for number, (title, seconds) in enumerate(tracks, 1):
            target = out / f"{artist} - {title}.mp3"
            run("ffmpeg", "-v", "error", "-y",
                "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo:d={seconds}",
                "-i", str(art), "-map", "0:a", "-map", "1:v",
                "-c:a", "libmp3lame", "-b:a", "64k", "-c:v", "mjpeg", "-disposition:v", "attached_pic",
                "-id3v2_version", "3",
                "-metadata", f"title={title}", "-metadata", f"artist={artist}",
                "-metadata", f"album={album}", "-metadata", f"album_artist={artist}",
                "-metadata", f"genre={genre}", "-metadata", f"date={year}",
                "-metadata", f"track={number}/{len(tracks)}", str(target))
        print(f"{album}: {len(tracks)} tracks")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
