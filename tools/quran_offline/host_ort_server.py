#!/usr/bin/env python3
"""Local-only ONNX Runtime endpoint used by the Flutter host benchmark.

The request body is little-endian float32 PCM at 16 kHz.  Responses are the
little-endian flattened ``log_probs`` tensor, with its dimensions in headers.
This is deliberately a localhost tool: it is not an application API.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Final

import numpy as np
import onnxruntime as ort


DEFAULT_MODEL: Final = Path("assets/quran_offline/fastconformer_full_mixed_ort122.onnx")
DEFAULT_CACHE: Final = Path("/tmp/quran-host-ort-cache")
MAX_REQUEST_BYTES: Final = 64 * 1024 * 1024


class OrtModel:
    """One process-wide CPU session and a disk cache keyed by model and PCM."""

    def __init__(self, model_path: Path, cache_dir: Path, threads: int) -> None:
        self.model_path = model_path.resolve()
        self.model_sha256 = _sha256_file(self.model_path)
        self.cache_dir = cache_dir
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(
            str(self.model_path), sess_options=options, providers=["CPUExecutionProvider"]
        )
        self.audio_name = next(item.name for item in self.session.get_inputs() if "audio" in item.name)
        self.length_name = next(item.name for item in self.session.get_inputs() if "length" in item.name)
        self.output_name = self.session.get_outputs()[0].name

    def run(self, raw_pcm: bytes) -> tuple[bytes, int, int, bool]:
        if len(raw_pcm) % 4:
            raise ValueError("PCM body length must be a multiple of four bytes")
        cache_key = hashlib.sha256(self.model_sha256.encode() + raw_pcm).hexdigest()
        data_path = self.cache_dir / f"{cache_key}.f32"
        meta_path = self.cache_dir / f"{cache_key}.json"
        if data_path.exists() and meta_path.exists():
            try:
                metadata = json.loads(meta_path.read_text())
                output = data_path.read_bytes()
                if len(output) == metadata["timeSteps"] * metadata["vocabSize"] * 4:
                    return output, metadata["timeSteps"], metadata["vocabSize"], True
            except (OSError, ValueError, KeyError):
                pass

        samples = np.frombuffer(raw_pcm, dtype="<f4")
        if samples.size == 0:
            raise ValueError("PCM body is empty")
        output = self.session.run(
            [self.output_name],
            {
                self.audio_name: samples.reshape(1, -1),
                self.length_name: np.asarray([samples.size], dtype=np.int64),
            },
        )[0]
        if output.ndim != 3 or output.shape[0] != 1:
            raise RuntimeError(f"unexpected model output shape: {output.shape}")
        time_steps, vocab_size = (int(output.shape[1]), int(output.shape[2]))
        binary = np.asarray(output[0], dtype="<f4", order="C").tobytes()
        _atomic_write(data_path, binary)
        _atomic_write(meta_path, json.dumps({"timeSteps": time_steps, "vocabSize": vocab_size}).encode())
        return binary, time_steps, vocab_size, False


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _atomic_write(path: Path, content: bytes) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    temporary.write_bytes(content)
    temporary.replace(path)


def make_handler(model: OrtModel):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802
            if self.path != "/health":
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            self._json(HTTPStatus.OK, {"modelSha256": model.model_sha256, "ort": ort.__version__})

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/run":
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            content_length = self.headers.get("Content-Length")
            try:
                size = int(content_length or "-1")
            except ValueError:
                size = -1
            if size <= 0 or size > MAX_REQUEST_BYTES:
                self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "invalid PCM body size")
                return
            try:
                binary, time_steps, vocab_size, cached = model.run(self.rfile.read(size))
            except (ValueError, RuntimeError) as error:
                self.send_error(HTTPStatus.BAD_REQUEST, str(error))
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(binary)))
            self.send_header("X-Quran-Time-Steps", str(time_steps))
            self.send_header("X-Quran-Vocab-Size", str(vocab_size))
            self.send_header("X-Quran-Cache", "hit" if cached else "miss")
            self.end_headers()
            self.wfile.write(binary)

        def _json(self, status: HTTPStatus, value: object) -> None:
            content = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def log_message(self, format: str, *args: object) -> None:
            print(f"{self.client_address[0]} {format % args}", flush=True)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", choices=("127.0.0.1",))
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--model", default=str(DEFAULT_MODEL), type=Path)
    parser.add_argument("--cache-dir", default=str(DEFAULT_CACHE), type=Path)
    parser.add_argument("--threads", default=max(1, (os.cpu_count() or 2) // 2), type=int)
    args = parser.parse_args()
    if not args.model.is_file():
        parser.error(f"model does not exist: {args.model}")
    model = OrtModel(args.model, args.cache_dir, args.threads)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(model))
    print(f"Quran host ORT server http://{args.host}:{args.port} model={model.model_path}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
