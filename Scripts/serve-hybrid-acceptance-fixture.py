#!/usr/bin/env python3
"""Serve a local Hybrid fixture with an optional one-shot origin audio stall."""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import re
import threading
import time
import urllib.parse
from http import HTTPStatus
from pathlib import Path


class AcceptanceHandler(http.server.SimpleHTTPRequestHandler):
    stall_segment_index: int | None = None
    stall_seconds: float = 0
    stalled_resources: set[str] = set()
    stall_lock = threading.Lock()
    allowed_single_resource: str | None = None
    byte_range: tuple[int, int] | None = None

    def do_HEAD(self) -> None:  # noqa: N802 - stdlib override
        if not self._is_allowed_resource():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        super().do_HEAD()

    def do_GET(self) -> None:  # noqa: N802 - stdlib override
        if not self._is_allowed_resource():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        resource = urllib.parse.urlsplit(self.path).path
        print(
            f"AETHER_FIXTURE_SERVER request {self._resource_label(resource)}",
            flush=True,
        )
        if self._should_stall(resource):
            ordinal = self.stall_segment_index
            print(
                "AETHER_FIXTURE_SERVER stallBegin "
                f"resourceKind=audioSegment ordinal={ordinal} "
                f"delaySeconds={self.stall_seconds:g}",
                flush=True,
            )
            time.sleep(self.stall_seconds)
            print(
                "AETHER_FIXTURE_SERVER stallEnd "
                f"resourceKind=audioSegment ordinal={ordinal}",
                flush=True,
            )
        try:
            super().do_GET()
        except (BrokenPipeError, ConnectionResetError):
            print(
                "AETHER_FIXTURE_SERVER clientCancelled "
                f"{self._resource_label(resource)}",
                flush=True,
            )

    def send_head(self):
        self.byte_range = None
        range_header = self.headers.get("Range")
        if range_header is None:
            return super().send_head()

        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            file = open(path, "rb")
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return None
        try:
            stat = os.fstat(file.fileno())
            parsed = self._parse_single_range(
                range_header,
                stat.st_size,
            )
            if parsed is None:
                file.close()
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{stat.st_size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            start, end = parsed
            self.byte_range = (start, end)
            self.send_response(HTTPStatus.PARTIAL_CONTENT)
            self.send_header("Content-type", self.guess_type(path))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header(
                "Content-Range",
                f"bytes {start}-{end}/{stat.st_size}",
            )
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header(
                "Last-Modified",
                self.date_time_string(stat.st_mtime),
            )
            self.end_headers()
            return file
        except Exception:
            file.close()
            raise

    def copyfile(self, source, outputfile) -> None:
        selected = self.byte_range
        if selected is None:
            super().copyfile(source, outputfile)
            return
        start, end = selected
        source.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            try:
                outputfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                return
            remaining -= len(chunk)

    @staticmethod
    def _parse_single_range(
        value: str,
        size: int,
    ) -> tuple[int, int] | None:
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
        if match is None or size <= 0:
            return None
        first, last = match.groups()
        if not first and not last:
            return None
        if first:
            start = int(first)
            if start >= size:
                return None
            end = min(int(last), size - 1) if last else size - 1
            if end < start:
                return None
            return start, end
        suffix_length = int(last)
        if suffix_length <= 0:
            return None
        return max(0, size - suffix_length), size - 1

    def _is_allowed_resource(self) -> bool:
        allowed = self.allowed_single_resource
        if allowed is None:
            return True
        resource = urllib.parse.unquote(
            urllib.parse.urlsplit(self.path).path
        ).lstrip("/")
        return resource == allowed

    @staticmethod
    def _resource_label(resource: str) -> str:
        parts = resource.strip("/").split("/")
        if len(parts) == 2 and parts[1].startswith("segment_"):
            if parts[0] == "video":
                kind = "videoSegment"
            elif parts[1].endswith(".vtt"):
                kind = "subtitleSegment"
            else:
                kind = "audioSegment"
            ordinal = (
                parts[1]
                .removeprefix("segment_")
                .removesuffix(".m4s")
                .removesuffix(".vtt")
            )
            return f"resourceKind={kind} ordinal={ordinal}"
        if resource.endswith("master.m3u8"):
            return "resourceKind=masterPlaylist"
        if resource.endswith("index.m3u8"):
            return "resourceKind=mediaPlaylist"
        if resource.endswith(".mp4"):
            return "resourceKind=initSegment"
        return "resourceKind=other"

    def _should_stall(self, resource: str) -> bool:
        index = self.stall_segment_index
        if index is None:
            return False
        expected_name = f"segment_{index:03d}.m4s"
        parts = resource.strip("/").split("/")
        if len(parts) != 2 or parts[0] == "video" or parts[1] != expected_name:
            return False
        with self.stall_lock:
            if resource in self.stalled_resources:
                return False
            self.stalled_resources.add(resource)
            return True

    def log_message(self, format: str, *args: object) -> None:
        # Keep stdout privacy-safe: the fixture path, host and request URI are omitted.
        status = args[1] if len(args) > 1 else "unknown"
        print(f"AETHER_FIXTURE_SERVER response status={status}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_path", type=Path)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--stall-audio-segment", type=int)
    parser.add_argument("--stall-seconds", type=float, default=10)
    args = parser.parse_args()

    fixture_path = args.fixture_path.resolve()
    if fixture_path.is_dir():
        root = fixture_path
        if not (root / "master.m3u8").is_file():
            raise SystemExit(
                f"ERROR: fixture has no master.m3u8: {root}"
            )
        AcceptanceHandler.allowed_single_resource = None
        fixture_kind = "hls"
    elif fixture_path.is_file():
        root = fixture_path.parent
        AcceptanceHandler.allowed_single_resource = fixture_path.name
        fixture_kind = "progressive"
    else:
        raise SystemExit(f"ERROR: fixture path does not exist: {fixture_path}")
    if args.stall_audio_segment is not None and args.stall_audio_segment < 1:
        raise SystemExit("ERROR: stall audio segment must be greater than zero")
    if args.stall_seconds <= 0:
        raise SystemExit("ERROR: stall duration must be positive")

    AcceptanceHandler.stall_segment_index = args.stall_audio_segment
    AcceptanceHandler.stall_seconds = args.stall_seconds
    AcceptanceHandler.stalled_resources = set()
    handler = functools.partial(AcceptanceHandler, directory=str(root))
    server = http.server.ThreadingHTTPServer((args.bind, args.port), handler)
    print(
        "AETHER_FIXTURE_SERVER ready "
        f"fixtureKind={fixture_kind} "
        f"port={args.port} stallAudioSegment={args.stall_audio_segment} "
        f"stallSeconds={args.stall_seconds:g}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
