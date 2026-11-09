"""Convert audio the iPod can't play into ALAC (lossless sources) or AAC (lossy)."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

AUDIO_SUFFIXES = {
    ".mp3", ".m4a", ".m4b", ".aac", ".alac", ".flac", ".wav", ".aif", ".aiff",
    ".ogg", ".oga", ".opus", ".wma", ".ape", ".wv", ".tta", ".mka", ".webm", ".dsf",
}
LOSSLESS_CODECS = {
    "flac", "alac", "ape", "wavpack", "tta", "mlp", "truehd", "dsd_lsbf", "dsd_msbf",
}
AAC_BITRATE = "256k"


class ConversionError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class AudioInfo:
    codec: str
    sample_rate: int
    channels: int
    stream_tags: bool = False  # Ogg/Opus keep tags on the stream, not the container

    @property
    def lossless(self) -> bool:
        return self.codec in LOSSLESS_CODECS or self.codec.startswith("pcm_")


def _tool(name: str) -> str:
    found = shutil.which(name) or next(
        (p for p in (f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}") if Path(p).exists()),
        None,
    )
    if not found:
        raise ConversionError(f"{name} not found; install it with: brew install ffmpeg")
    return found


def probe(path: Path) -> AudioInfo:
    result = subprocess.run(
        [_tool("ffprobe"), "-v", "error", "-select_streams", "a:0",
         "-show_entries", "stream=codec_name,sample_rate,channels:stream_tags:format_tags",
         "-of", "json", str(path)],
        capture_output=True, text=True,
    )
    data = json.loads(result.stdout or "{}")
    streams = data.get("streams") or []
    if result.returncode or not streams:
        raise ConversionError(f"Not a readable audio file: {path.name}")
    s = streams[0]
    has_title = lambda tags: any(k.lower() == "title" for k in (tags or {}))  # noqa: E731
    return AudioInfo(
        s.get("codec_name", ""), int(s.get("sample_rate") or 0), int(s.get("channels") or 0),
        stream_tags=has_title(s.get("tags")) and not has_title(data.get("format", {}).get("tags")),
    )


def convert(source: Path, out_dir: Path) -> Path:
    """Write an iPod-compatible .m4a for source into out_dir and return its path."""
    info = probe(source)
    # Each conversion gets its own folder: several run at once, and the file keeps
    # its original name (it becomes the title when the song has no title tag).
    folder = Path(tempfile.mkdtemp(prefix="convert-", dir=out_dir))
    target = folder / f"{source.stem}.m4a"

    if info.lossless:
        audio = ["-c:a", "alac", "-sample_fmt", "s16p"]
    else:
        audio = ["-c:a", "aac", "-b:a", AAC_BITRATE]
    if info.sample_rate > 48000:
        audio += ["-ar", "48000" if info.sample_rate % 48000 == 0 else "44100"]
    if info.channels > 2:
        audio += ["-ac", "2"]
    base = [_tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(source),
            "-map", "0:a:0", "-map_chapters", "0", "-map_metadata", "0:s:a:0" if info.stream_tags else "0", *audio]
    cover = ["-map", "0:v:0?", "-c:v", "copy", "-disposition:v", "attached_pic"]

    # Keep embedded cover art when the container allows it; retry without on failure.
    for extra in (cover, []):
        result = subprocess.run([*base, *extra, str(target)], capture_output=True, text=True)
        if result.returncode == 0:
            return target
        target.unlink(missing_ok=True)
    raise ConversionError(f"ffmpeg failed for {source.name}: {result.stderr.strip()[-300:]}")


def expand(paths: list[Path]) -> list[Path]:
    """Dropped files plus audio files found inside dropped folders, in a stable order."""
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files += sorted(p for p in path.rglob("*")
                            if p.is_file() and p.suffix.lower() in AUDIO_SUFFIXES
                            and not p.name.startswith("._"))
        elif path.is_file():
            files.append(path)
    return files
