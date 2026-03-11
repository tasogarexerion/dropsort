from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ailocaltools import bridge
from ailocaltools.models import OrganizerRun, OrganizerSuggestion, SummaryResult


class BridgeTests(unittest.TestCase):
    def test_parse_request_requires_type(self) -> None:
        with self.assertRaises(ValueError):
            bridge.parse_request("{}")

    def test_run_from_stream_returns_error_envelope(self) -> None:
        code = bridge.cli_main(["{}"])
        self.assertEqual(code, 1)

    def test_handle_list_recent_uses_history_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "history.sqlite3"
            os.environ["APPLE_LOCAL_AI_HISTORY_DB"] = str(db_path)
            try:
                result = bridge.cli_main(
                    [json.dumps({"type": "ListRecentResults", "payload": {}})]
                )
            finally:
                os.environ.pop("APPLE_LOCAL_AI_HISTORY_DB", None)
            self.assertEqual(result, 0)


class HandleRequestTests(unittest.IsolatedAsyncioTestCase):
    async def test_check_environment(self) -> None:
        result = await bridge.handle_request(bridge.RequestEnvelope(type="CheckEnvironment"))
        self.assertIn("shell_supported", result)

    async def test_summarize_file_saves_history(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "notes.txt"
            target.write_text("hello world", encoding="utf-8")
            db_path = Path(temp_dir) / "history.sqlite3"
            with mock.patch.dict(os.environ, {"APPLE_LOCAL_AI_HISTORY_DB": str(db_path)}):
                fake = SummaryResult(
                    title="hello",
                    style="bullets",
                    length="short",
                    summary_text="- hello",
                    source_kind="text",
                    created_at="2026-03-11T00:00:00+00:00",
                )
                with mock.patch(
                    "ailocaltools.bridge.summarize_ingested",
                    new=mock.AsyncMock(return_value=fake),
                ):
                    result = await bridge.handle_request(
                        bridge.RequestEnvelope(
                            type="SummarizeFile",
                            payload={"path": str(target)},
                        )
                    )
            self.assertEqual(result["title"], "hello")

    async def test_scan_folder_returns_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "scan"
            target.mkdir()
            (target / "sample.zip").write_text("binary placeholder", encoding="utf-8")
            db_path = Path(temp_dir) / "history.sqlite3"
            with mock.patch.dict(os.environ, {"APPLE_LOCAL_AI_HISTORY_DB": str(db_path)}):
                result = await bridge.handle_request(
                    bridge.RequestEnvelope(
                        type="ScanFolder",
                        payload={"path": str(target)},
                    )
                )
            self.assertEqual(result["source_root"], str(target.resolve()))
            self.assertEqual(len(result["suggestions"]), 1)

    async def test_apply_suggestions_moves_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "scan"
            target.mkdir()
            sample = target / "sample.zip"
            sample.write_text("binary placeholder", encoding="utf-8")
            result = await bridge.handle_request(
                bridge.RequestEnvelope(
                    type="ApplyOrganizerSuggestions",
                    payload={
                        "source_root": str(target),
                        "suggestions_json": json.dumps(
                            [{"source_path": str(sample), "target_folder_name": "Installers"}]
                        ),
                    },
                )
            )
            self.assertEqual(result["moved_count"], 1)
            self.assertTrue((target / "Installers" / "sample.zip").exists())
