from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ailocaltools.history import HistoryStore
from ailocaltools.models import OrganizerRun, OrganizerSuggestion, SummaryResult


class HistoryTests(unittest.TestCase):
    def test_summary_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            store = HistoryStore(Path(temp_dir) / "history.sqlite3")
            for index in range(25):
                store.save_summary(
                    SummaryResult(
                        title=f"title-{index}",
                        style="bullets",
                        length="short",
                        summary_text=f"summary-{index}",
                        source_kind="text",
                        created_at=f"2026-03-11T00:00:{index:02d}+00:00",
                    )
                )
            recent = store.list_recent_results()
            self.assertEqual(len(recent.summaries), 20)
            self.assertEqual(recent.summaries[0].title, "title-24")

    def test_organizer_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            store = HistoryStore(Path(temp_dir) / "history.sqlite3")
            for index in range(12):
                store.save_organizer_run(
                    OrganizerRun(
                        source_root=f"/tmp/run-{index}",
                        started_at=f"2026-03-11T00:00:{index:02d}+00:00",
                        suggestions=[
                            OrganizerSuggestion(
                                source_path=f"/tmp/file-{index}.txt",
                                target_folder_name="Documents",
                                is_new_folder=True,
                                reason_ja="test",
                                evidence_summary="evidence",
                                confidence=0.8,
                                suggested_tags=["書類", "要確認"],
                            )
                        ],
                    )
                )
            recent = store.list_recent_results()
            self.assertEqual(len(recent.organizer_runs), 10)
            self.assertEqual(recent.organizer_runs[0].source_root, "/tmp/run-11")
            self.assertEqual(recent.organizer_runs[0].suggestions[0].suggested_tags, ["書類", "要確認"])
