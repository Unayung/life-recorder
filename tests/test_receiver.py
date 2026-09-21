from datetime import timezone
import gc
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
import uuid
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "receiver"))
import receiver
from receiver import Handler, Inbox, Receiver, clean_transcript, load_vocabulary, transcribe


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.inbox = Inbox(Path(self.temp.name), timezone.utc)
        self.server = Receiver(("127.0.0.1", 0), Handler)
        self.server.inbox = self.inbox
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.device = str(uuid.uuid4())

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def upload(self, body=b"test audio", chunk_id=None, started="2026-09-10T12:00:00.000Z", **overrides):
        chunk_id = chunk_id or str(uuid.uuid4())
        headers = {
            "Authorization": "Bearer " + self.inbox.token,
            "X-Device-ID": self.device,
            "X-Started-At": started,
            "X-Duration-Seconds": "60.0",
            "X-Audio-SHA256": hashlib.sha256(body).hexdigest(),
            "Content-Type": "audio/mp4",
        }
        headers.update(overrides)
        client = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        client.request("POST", "/v1/chunks/" + chunk_id, body, headers)
        response = client.getresponse()
        result = response.status, json.loads(response.read()), chunk_id
        client.close()
        return result

    def test_acknowledgment_survives_receiver_restart(self):
        status, receipt, chunk_id = self.upload()
        self.assertEqual(status, 201)
        self.assertTrue(receipt["durable"])
        reopened = Inbox(self.inbox.root)
        row = reopened.receipt(chunk_id)
        self.assertEqual(Path(row["path"]).read_bytes(), b"test audio")
        self.assertEqual(row["sha256"], receipt["sha256"])

    def test_lost_receipt_retry_is_idempotent_even_after_audio_deletion(self):
        _, _, chunk_id = self.upload()
        self.inbox.complete(chunk_id, "A test sentence.")
        status, receipt, _ = self.upload(chunk_id=chunk_id)
        self.assertEqual(status, 200)
        self.assertTrue(receipt["durable"])
        self.assertEqual(self.inbox.status(), {"complete": 1})
        self.assertEqual((self.inbox.root / "life.md").read_text().count("A test sentence."), 1)
        self.assertEqual(list(self.inbox.audio.iterdir()), [])

    def test_id_collision_rejected(self):
        _, _, chunk_id = self.upload()
        status, _, _ = self.upload(body=b"different recording", chunk_id=chunk_id)
        self.assertEqual(status, 409)
        self.assertEqual(Path(self.inbox.receipt(chunk_id)["path"]).read_bytes(), b"test audio")

    def test_checksum_failure_keeps_no_receipt(self):
        status, _, chunk_id = self.upload(**{"X-Audio-SHA256": "0" * 64})
        self.assertEqual(status, 422)
        self.assertIsNone(self.inbox.receipt(chunk_id))
        self.assertEqual(list(self.inbox.audio.iterdir()), [])

    def test_unauthorized_upload_rejected(self):
        status, _, _ = self.upload(**{"Authorization": "Bearer wrong"})
        self.assertEqual(status, 401)
        self.assertEqual(self.inbox.status(), {})

    def test_offline_backlog_is_exported_by_capture_time(self):
        _, _, later = self.upload(started="2026-09-10T16:00:00.000Z")
        self.inbox.complete(later, "Later audio arrived.")
        _, _, earlier = self.upload(started="2026-09-09T16:00:00.000Z")
        self.inbox.complete(earlier, "Earlier audio arrived.")
        text = (self.inbox.root / "life.md").read_text()
        self.assertLess(text.index("Earlier audio arrived."), text.index("Later audio arrived."))
        self.assertTrue((self.inbox.days / "2026-09-09.md").exists())
        self.assertTrue((self.inbox.days / "2026-09-10.md").exists())

    def test_untranscribed_audio_retained(self):
        _, _, chunk_id = self.upload()
        self.inbox.cleanup_completed()
        self.assertTrue(Path(self.inbox.receipt(chunk_id)["path"]).exists())

    def test_bad_metadata_and_path_rejected(self):
        for override in ({"X-Duration-Seconds": "NaN"}, {"X-Duration-Seconds": "601"},
                         {"X-Started-At": "2026-09-10"}, {"X-Device-ID": "../escape"}):
            self.assertEqual(self.upload(**override)[0], 400)
        self.assertEqual(self.upload(chunk_id="../escape")[0], 400)

    def test_concurrent_duplicate_uploads_get_one_receipt(self):
        chunk_id = str(uuid.uuid4())
        responses = []
        jobs = [threading.Thread(target=lambda: responses.append(self.upload(chunk_id=chunk_id)[0])) for _ in range(4)]
        for job in jobs: job.start()
        for job in jobs: job.join()
        self.assertEqual(sorted(responses), [200, 200, 200, 201])
        self.assertEqual(self.inbox.status(), {"pending": 1})

    def test_interrupted_upload_never_acknowledged(self):
        chunk_id = str(uuid.uuid4())
        headers = (f"POST /v1/chunks/{chunk_id} HTTP/1.1\r\nHost: localhost\r\n"
                   f"Authorization: Bearer {self.inbox.token}\r\nX-Device-ID: {self.device}\r\n"
                   "X-Started-At: 2026-09-10T12:00:00.000Z\r\nX-Duration-Seconds: 60\r\n"
                   f"X-Audio-SHA256: {hashlib.sha256(b'abcd').hexdigest()}\r\nContent-Length: 4\r\n\r\nab")
        with socket.create_connection(self.server.server_address) as client:
            client.sendall(headers.encode())
            client.shutdown(socket.SHUT_WR)
            response = client.recv(4096)
        self.assertIn(b"400", response)
        self.assertIsNone(self.inbox.receipt(chunk_id))

    def test_database_connections_do_not_leak_file_descriptors(self):
        # launchd gives the receiver 256 descriptors; leaked handles once stopped uploads and transcription.
        gc.disable()  # Garbage collection must not be what closes connections.
        try:
            before = len(os.listdir("/dev/fd"))
            for _ in range(300):
                self.inbox.receipt(str(uuid.uuid4()))
                self.inbox.status()
            after = len(os.listdir("/dev/fd"))
        finally:
            gc.enable()
        self.assertLess(after - before, 10)

    def get(self, path, token=None):
        client = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        client.request("GET", path, headers={"Authorization": "Bearer " + (token or self.inbox.token)})
        response = client.getresponse()
        result = response.status, json.loads(response.read())
        client.close()
        return result

    def test_day_index_lists_dates_newest_first_and_flags_summaries(self):
        for started, text in (("2026-09-09T16:00:00.000Z", "早上的會議。"),
                              ("2026-09-10T16:00:00.000Z", "下午的討論。")):
            _, _, chunk_id = self.upload(started=started)
            self.inbox.complete(chunk_id, text)
        (self.inbox.summaries / "2026-09-10.md").write_text("# 2026-09-10\n\n重點是上線時程。\n")
        status, payload = self.get("/v1/days")
        self.assertEqual(status, 200)
        self.assertEqual([day["date"] for day in payload["days"]], ["2026-09-10", "2026-09-09"])
        self.assertTrue(payload["days"][0]["summarized"])
        self.assertFalse(payload["days"][1]["summarized"])

    def test_day_document_prefers_the_summary_and_keeps_the_transcript(self):
        _, _, chunk_id = self.upload(started="2026-09-10T16:00:00.000Z")
        self.inbox.complete(chunk_id, "下午的討論。")
        (self.inbox.summaries / "2026-09-10.md").write_text("重點是上線時程。")
        status, payload = self.get("/v1/days/2026-09-10")
        self.assertEqual(status, 200)
        self.assertEqual(payload["summary"], "重點是上線時程。")
        self.assertIn("下午的討論。", payload["transcript"])

    def test_reading_requires_the_token_and_rejects_odd_dates(self):
        self.assertEqual(self.get("/v1/days", token="wrong")[0], 401)
        for path in ("/v1/days/2026-13-45", "/v1/days/../../etc/passwd", "/v1/days/2026-09-10.md"):
            self.assertEqual(self.get(path)[0], 404, path)

    def test_day_files_and_markers_use_local_capture_time(self):
        inbox = Inbox(Path(self.temp.name) / "taipei", ZoneInfo("Asia/Taipei"))
        tmp = inbox.audio / "clip.upload"
        tmp.write_bytes(b"audio")
        chunk_id = str(uuid.uuid4())
        inbox.accept(tmp, chunk_id, "0" * 64, self.device, "2026-09-09T16:30:00.000Z", 60.0)
        inbox.complete(chunk_id, "午夜的會議。")
        day = (inbox.days / "2026-09-10.md").read_text()
        self.assertIn("### 2026-09-10 00:00 (UTC+08:00)\n\n[00:30] 午夜的會議。", day)
        self.assertFalse((inbox.days / "2026-09-09.md").exists())


class TLSTests(unittest.TestCase):
    def test_silent_client_does_not_block_other_handshakes(self):
        with tempfile.TemporaryDirectory() as temp:
            cert, key = Path(temp, "c.pem"), Path(temp, "k.pem")
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=test", "-keyout", key, "-out", cert],
                           check=True, capture_output=True)
            server = Receiver(("127.0.0.1", 0), Handler)
            server.inbox = Inbox(Path(temp), timezone.utc)
            receiver.enable_tls(server, cert, key)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stalled = socket.create_connection(server.server_address)  # connects, never says hello
            try:
                client = http.client.HTTPSConnection(*server.server_address, timeout=5,
                                                     context=ssl._create_unverified_context())
                client.request("GET", "/health")
                self.assertEqual(client.getresponse().status, 401)
            finally:
                stalled.close()
                server.shutdown()
                server.server_close()


class TranscriptionTests(unittest.TestCase):
    def test_subtitle_credit_and_repeated_hallucinations_removed(self):
        for text in ("字幕由Amara.org社區提供", "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
                     "謝謝觀看!", "感謝收看。", "thank you thank you thank you",
                     "我們下次再見 我們下次再見 我們下次再見", "<|12.34|><|56.78|>", "[BLANK_AUDIO]"):
            self.assertEqual(clean_transcript(text), "", text)

    def test_code_switched_speech_kept(self):
        for text in ("這個 PR 先 deploy 到 staging, 好 下次再見", "謝謝觀看的人都有回饋"):
            self.assertEqual(clean_transcript(text), text)
        self.assertEqual(clean_transcript("[音樂] 字幕由Amara.org社區提供 我們開始吧"), "我們開始吧")

    def test_lone_latin_words_dropped_but_short_chinese_replies_kept(self):
        # Observed in a real afternoon of recording: lone words decoded from background noise.
        for text in ("Send", "CNN.", "batch host", "inter-tool.js", "staging,"):
            self.assertEqual(clean_transcript(text), "", text)
        for text in ("好", "沒錯", "好 好", "shall we see."):
            self.assertEqual(clean_transcript(text), text)

    def test_long_phrase_loop_collapsed_but_emphasis_kept(self):
        self.assertEqual(clean_transcript("重點我們下午再確認一次我們下午再確認一次我們下午再確認一次欸我現在"),
                         "重點我們下午再確認一次欸我現在")
        for text in ("成 model 要換要換要換要換你已經有決定了喔", "它就會在背景一直錄一直錄一直錄一直錄錄音",
                     "填什麼之類的 blah blah blah blah 所以大家都用這個"):
            self.assertEqual(clean_transcript(text), text)

    def test_response_to_disconnected_phone_is_silent(self):
        class Disconnected:
            def write(self, data):
                raise ssl.SSLEOFError("EOF occurred in violation of protocol")

        handler = Handler.__new__(Handler)
        handler.request_version = "HTTP/1.1"
        handler.requestline = "POST /v1/chunks/x HTTP/1.1"
        handler.wfile = Disconnected()
        handler.respond(400, {"error": "Invalid or incomplete chunk"})  # Must not raise.
        self.assertTrue(handler.close_connection)

    def test_vocabulary_file_supplies_only_its_prompt_section(self):
        with tempfile.TemporaryDirectory() as home:
            glossary = Path(home) / "vocabulary.md"
            glossary.write_text("# 詞彙表\n\n說明文字，提示詞用在下一節。\n\n## 提示詞用（精簡版）\n\n"
                                "Aurora, Nova AI, 小明\noutbound, 外撥\n\n## 人名\n\n| 正確 | 角色 |\n",
                                encoding="utf-8")
            self.assertEqual(load_vocabulary(glossary), "Aurora, Nova AI, 小明 outbound, 外撥")
            long_terms = Path(home) / "long.md"
            long_terms.write_text("## 提示詞用\n\n" + "詞, " * 500, encoding="utf-8")
            self.assertLessEqual(len(load_vocabulary(long_terms)), 800)
        # A missing or unreadable glossary must never stop transcription.
        self.assertEqual(load_vocabulary(Path("/nonexistent/vocabulary.md")), "")
        self.assertEqual(load_vocabulary(None), "")

    def test_glossary_terms_are_appended_to_the_prompt(self):
        commands = []

        def fake_run(command, **kwargs):
            commands.append(command)
            if command[0] == "whisper-cli":
                prefix = Path(command[command.index("-of") + 1])
                prefix.with_suffix(".json").write_text(json.dumps({"transcription": [{"text": "Aurora"}]}))

        with tempfile.TemporaryDirectory() as work, mock.patch.object(receiver.subprocess, "run", fake_run):
            glossary = Path(work) / "vocabulary.md"
            glossary.write_text("## 提示詞用\n\nAurora, 小明\n", encoding="utf-8")
            transcribe({"id": "clip", "path": "clip.m4a"}, Path("breeze.bin"), Path(work),
                       "whisper-cli", "ffmpeg", prompt="PR, deploy", vocabulary=glossary)
        whisper = commands[1]
        self.assertEqual(whisper[whisper.index("--prompt") + 1], "PR, deploy, Aurora, 小明")

    def test_whisper_command_uses_language_vad_and_prompt(self):
        commands = []

        def fake_run(command, **kwargs):
            commands.append(command)
            if command[0] == "whisper-cli":
                prefix = Path(command[command.index("-of") + 1])
                prefix.with_suffix(".json").write_text(json.dumps(
                    {"transcription": [{"text": "這個 PR"}, {"text": "先 deploy"}]}))

        with tempfile.TemporaryDirectory() as work, mock.patch.object(receiver.subprocess, "run", fake_run):
            text = transcribe({"id": "clip", "path": "clip.m4a"}, Path("breeze.bin"), Path(work),
                              "whisper-cli", "ffmpeg", vad_model=Path("vad.bin"), prompt="PR, deploy")
        self.assertEqual(text, "這個 PR 先 deploy")
        whisper = commands[1]
        self.assertEqual(whisper[whisper.index("-l") + 1], "zh")
        self.assertEqual(whisper[whisper.index("-vm") + 1], "vad.bin")
        self.assertIn("--vad", whisper)
        self.assertEqual(whisper[whisper.index("--prompt") + 1], "PR, deploy")


if __name__ == "__main__":
    unittest.main()


class VocabularyTests(unittest.TestCase):
    """The glossary is edited from the phone, so it is read and written over the same API."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.inbox = Inbox(root, timezone.utc)
        self.vocabulary = root / "vocabulary.md"
        self.vocabulary.write_text("# 提示詞用\nJayce Eris\n", encoding="utf-8")
        self.server = Receiver(("127.0.0.1", 0), Handler)
        self.server.inbox = self.inbox
        self.server.vocabulary = self.vocabulary
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, method, body=None, token=None):
        headers = {"Authorization": "Bearer " + (token or self.inbox.token)}
        payload = json.dumps(body).encode() if body is not None else None
        client = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        client.request(method, "/v1/vocabulary", payload, headers)
        response = client.getresponse()
        result = response.status, json.loads(response.read() or b"{}")
        client.close()
        return result

    def test_edit_from_the_phone_reaches_the_next_clip(self):
        status, document = self.request("GET")
        self.assertEqual(status, 200)
        self.assertIn("Jayce", document["text"])
        status, saved = self.request("PUT", {"text": "# 提示詞用\nJayce Eris Connie\n",
                                             "updated": document["updated"]})
        self.assertEqual(status, 200)
        self.assertIn("Connie", self.vocabulary.read_text(encoding="utf-8"))
        self.assertIn("Connie", receiver.load_vocabulary(self.vocabulary))
        self.assertNotEqual(saved["updated"], "")

    def test_stale_edit_is_refused_with_the_current_text(self):
        self.vocabulary.write_text("# 提示詞用\nwritten on the desktop\n", encoding="utf-8")
        status, conflict = self.request("PUT", {"text": "from the phone", "updated": "2020-01-01T00:00:00Z"})
        self.assertEqual(status, 409)
        self.assertIn("desktop", conflict["text"])
        self.assertIn("desktop", self.vocabulary.read_text(encoding="utf-8"))

    def test_edit_without_a_version_overwrites(self):
        status, _ = self.request("PUT", {"text": "deliberate replacement"})
        self.assertEqual(status, 200)
        self.assertEqual(self.vocabulary.read_text(encoding="utf-8"), "deliberate replacement")

    def test_glossary_needs_the_token(self):
        self.assertEqual(self.request("GET", token="wrong")[0], 401)
        self.assertEqual(self.request("PUT", {"text": "no"}, token="wrong")[0], 401)
        self.assertNotIn("no", self.vocabulary.read_text(encoding="utf-8"))

    def test_missing_glossary_is_not_found(self):
        self.server.vocabulary = None
        self.assertEqual(self.request("GET")[0], 404)
        self.assertEqual(self.request("PUT", {"text": "nowhere"})[0], 404)
