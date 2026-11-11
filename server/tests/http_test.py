#!/usr/bin/env python3
"""Exercise the real userver HTTP listener and optional QuickJS worker."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--worker", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="music-http-") as temporary:
        root = Path(temporary)
        collection = root / "collection"
        collection.mkdir()
        audio = collection / "tone.flac"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                        "sine=frequency=440:duration=0.2", str(audio)], check=True)
        sources = [{"id": "collection", "type": "storage", "root": str(collection)}]
        config = {"data_dir": str(root / "data"), "sources": {"alice": sources, "bob": sources}}
        if args.worker:
            package = root / "example.audio.mornye-ext"
            encoded = json.dumps(base64.b64encode(audio.read_bytes()).decode())
            with zipfile.ZipFile(package, "w") as archive:
                archive.writestr("manifest.json", json.dumps({
                    "name": "example.audio", "version": "1", "description": "Server test fixture",
                    "type": ["download_provider"], "permissions": {"file": True}, "skipMetadataEnrichment": True}))
                archive.writestr("index.js", "registerExtension({checkAvailability(){return {available:true,track_id:'track'};},"
                    "download(id,quality,path){file.writeBytes(path," + encoded + ");return {success:true,file_path:path,actual_extension:'.flac'};}});")
            sources.append({"id": "extension", "type": "extension", "provider_id": "example.audio",
                            "package": str(package), "qualities": ["LOSSLESS"]})
            config["extension_worker"] = str(args.worker.resolve())
        config_path = root / "service.json"
        config_path.write_text(json.dumps(config))
        for user in ("alice", "bob"):
            subprocess.run([str(args.build / "music-admin"), str(config_path), "create-user", user],
                           input="fixture-password-long\n", text=True, check=True, stdout=subprocess.DEVNULL)
        def free_port():
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                return sock.getsockname()[1]
        port, api_port = free_port(), free_port()
        static = root / "static.yaml"
        template = Path(__file__).parents[1] / "config" / "static.yaml"
        static.write_text(template.read_text().replace("port: 8080", f"port: {api_port}"))
        env = dict(os.environ, MUSIC_CONFIG=str(config_path))
        log = open(root / "server.log", "w+")
        process = subprocess.Popen([str(args.build / "music-server"), "--config", str(static)],
                                   env=env, stdout=log, stderr=log)
        nginx_config = root / "nginx.conf"
        nginx_config.write_text((template.parent / "nginx.conf").read_text()
            .replace("worker_processes auto", "worker_processes 1")
            .replace("pid /tmp/nginx.pid", f"pid {root}/nginx.pid")
            .replace("listen 8080", f"listen {port}")
            .replace("http://music:8080", f"http://127.0.0.1:{api_port}")
            .replace("/data/media/", f"{root}/data/media/")
            .replace("/tmp/client-body", f"{root}/client-body")
            .replace("/tmp/proxy", f"{root}/proxy"))
        gateway = subprocess.Popen(["nginx", "-p", str(root), "-c", str(nginx_config), "-g", "daemon off;"], stdout=log, stderr=log)
        def request(method, path, body=None, token=None, headers=None):
            request_headers = {"Content-Type": "application/json", **(headers or {})}
            if token:
                request_headers["Authorization"] = f"Bearer {token}"
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
                data=json.dumps(body).encode() if body is not None else None, method=method, headers=request_headers)
            try:
                response = urllib.request.urlopen(req, timeout=10)
            except urllib.error.HTTPError as error:
                response = error
            data = response.read()
            return response.status, (json.loads(data) if response.headers.get_content_type() == "application/json" and data else data), response.headers
        try:
            for _ in range(100):
                if process.poll() is not None or gateway.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                try:
                    if request("GET", "/health")[0] == 200:
                        break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("HTTP server did not start")
            tokens = {}
            for user in ("alice", "bob"):
                status, body, _ = request("POST", "/v1/auth/login", {"username": user, "password": "fixture-password-long"})
                assert status == 200, (status, body)
                tokens[user] = body["access_token"]
            payloads = [{"source": {"connection_id": "collection", "path": "tone.flac"}, "title": "Fixture"}]
            if args.worker:
                payloads.append({"source": {"connection_id": "extension", "track_id": "track"}, "quality": "LOSSLESS", "title": "Fixture"})
            for payload in payloads:
                status, job, _ = request("POST", "/v1/playback/prepare", payload, tokens["alice"])
                assert status == 202, (status, job)
                identifier = job["id"]
                duplicate = request("POST", "/v1/playback/prepare", payload, tokens["alice"])[1]
                assert duplicate["id"] == identifier
                assert request("GET", f"/v1/downloads/{identifier}", token=tokens["bob"])[0] == 404
                for _ in range(300):
                    job = request("GET", f"/v1/downloads/{identifier}", token=tokens["alice"])[1]
                    if job["state"] in ("ready", "failed"):
                        break
                    time.sleep(0.1)
                assert job["state"] == "ready", job
                ticket = request("POST", f"/v1/assets/{identifier}/playback-ticket", {}, tokens["alice"])[1]
                status, data, headers = request("GET", ticket["path"], headers={"Range": "bytes=1-15"})
                assert status == 206 and data == audio.read_bytes()[1:16], (status, data)
                assert headers["Content-Range"].startswith("bytes 1-15/")
                status, data, headers = request("HEAD", ticket["path"])
                assert status == 200 and not data and int(headers["Content-Length"]) == audio.stat().st_size
                assert request("GET", ticket["path"], headers={"Range": "bytes=999999999-"})[0] == 416
            assert request("GET", "/v1/tracks", token=tokens["bob"])[1]["items"] == []
            assert request("GET", "/_protected_media/")[0] == 404
            if args.worker:
                status, other_job, _ = request("POST", "/v1/playback/prepare", payloads[-1], tokens["bob"])
                assert status == 202 and other_job["id"] != identifier
                for _ in range(300):
                    other_job = request("GET", f"/v1/downloads/{other_job['id']}", token=tokens["bob"])[1]
                    if other_job["state"] in ("ready", "failed"):
                        break
                    time.sleep(0.1)
                assert other_job["state"] == "ready", other_job
                keys = list((root / "data/users").glob("*/master.key"))
                assert len(keys) == 2 and keys[0].read_bytes() != keys[1].read_bytes()
            request("POST", "/v1/auth/logout", {}, tokens["alice"])
            assert request("GET", ticket["path"])[0] == 404
            print("HTTP: login, private libraries, deduplication, streaming, HEAD, Range and revocation passed")
            if args.worker:
                print("Worker: existing JavaScript extension executed by the Rust/QuickJS runtime")
        finally:
            gateway.terminate()
            gateway.wait(timeout=15)
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()


if __name__ == "__main__":
    main()
