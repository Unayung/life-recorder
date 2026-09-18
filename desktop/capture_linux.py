#!/usr/bin/env python3
"""Record meetings on a Linux desktop (microphone + speakers) and upload them like the phone does.

Recording starts when a meeting app (browser, Slack, Zoom) opens the microphone and stops
30 seconds after it lets go, so videos and music outside calls are never captured.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import time
import uuid

MEETING_APPS = ("msedge", "chromium", "chrome", "brave", "firefox", "slack", "zoom")
GRACE_SECONDS = 30  # A muted mic or a rejoin shouldn't split one meeting into two recordings.


def meeting_app_using_mic(apps) -> bool:
    out = subprocess.run(["pactl", "-f", "json", "list", "source-outputs"],
                         capture_output=True, text=True).stdout
    for stream in json.loads(out or "[]"):
        props = stream.get("properties", {})
        name = f'{props.get("application.process.binary", "")} {props.get("application.name", "")}'.lower()
        if any(app in name for app in apps):
            return True
    return False


def start_recording(spool: Path) -> subprocess.Popen:
    # Segment names carry the UTC start time; the uploader turns them into X-Started-At.
    return subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-nostdin",
         "-f", "pulse", "-i", "default", "-f", "pulse", "-i", "@DEFAULT_MONITOR@",
         "-filter_complex", "amix=inputs=2:duration=longest:normalize=0", "-ac", "1", "-ar", "16000",
         "-c:a", "aac", "-b:a", "64k", "-f", "segment", "-segment_time", "60", "-segment_format", "ipod",
         "-reset_timestamps", "1", "-strftime", "1", str(spool / "%Y-%m-%dT%H-%M-%S.m4a")],
        env={**os.environ, "TZ": "UTC"})


def upload(path: Path, data_dir: Path, device: str, url: str) -> bool:
    """Send one segment; True once the receiver has it durably (or it can never be accepted)."""
    started = datetime.strptime(path.stem, "%Y-%m-%dT%H-%M-%S").replace(tzinfo=timezone.utc)
    duration = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True).stdout.strip() or 0)
    body = path.read_bytes()
    chunk_id = uuid.uuid5(uuid.UUID(device), path.name)  # Same file, same id: retries stay idempotent.
    context = ssl.create_default_context(cafile=str(data_dir / "receiver.crt"))
    context.check_hostname = False  # The self-signed cert has no SAN; trusting only it is the pin.
    host, port = url.rsplit(":", 1)
    client = http.client.HTTPSConnection(host, int(port), timeout=60, context=context)
    try:
        client.request("POST", f"/v1/chunks/{chunk_id}", body, {
            "Authorization": "Bearer " + (data_dir / "receiver.token").read_text().strip(),
            "X-Device-ID": device,
            "X-Started-At": started.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "X-Duration-Seconds": f"{duration:.3f}",
            "X-Audio-SHA256": hashlib.sha256(body).hexdigest(),
            "Content-Type": "audio/mp4",
        })
        response = client.getresponse()
        receipt = json.loads(response.read() or b"{}")
    except (OSError, ValueError) as error:
        print(f"upload {path.name} failed: {error}", flush=True)
        return False
    finally:
        client.close()
    if response.status in (200, 201) and receipt.get("durable"):
        return True
    if response.status == 400:  # Malformed (e.g. a zero-length tail); keep it aside, don't retry forever.
        path.rename(path.with_suffix(".rejected"))
        print(f"upload {path.name} rejected: {receipt}", flush=True)
    else:
        print(f"upload {path.name}: HTTP {response.status} {receipt}", flush=True)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path.home() / ".local/share/life-recorder")
    parser.add_argument("--receiver", default="127.0.0.1:8765")
    parser.add_argument("--apps", default=",".join(MEETING_APPS), help="comma-separated mic-client names")
    args = parser.parse_args()
    apps = tuple(a.strip().lower() for a in args.apps.split(",") if a.strip())
    spool = args.data_dir / "desktop-spool"
    spool.mkdir(mode=0o700, exist_ok=True)
    device_file = args.data_dir / "desktop-device-id"
    if not device_file.exists():
        device_file.write_text(str(uuid.uuid4()))
    device = device_file.read_text().strip()

    recorder, last_seen = None, 0.0
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    while not stop:
        if meeting_app_using_mic(apps):
            last_seen = time.monotonic()
            if recorder is None:
                print("meeting started, recording", flush=True)
                recorder = start_recording(spool)
        elif recorder and time.monotonic() - last_seen > GRACE_SECONDS:
            recorder.send_signal(signal.SIGINT)  # Lets ffmpeg finish the last segment cleanly.
            recorder.wait()
            recorder = None
            print("meeting ended, stopped", flush=True)
        segments = sorted(spool.glob("*.m4a"))
        if recorder:
            segments = segments[:-1]  # The newest file is still being written.
        for path in segments:
            if upload(path, args.data_dir, device, args.receiver):
                path.unlink()
        time.sleep(5)
    if recorder:
        recorder.send_signal(signal.SIGINT)
        recorder.wait()


if __name__ == "__main__":
    main()
