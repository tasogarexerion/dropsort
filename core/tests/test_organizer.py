from __future__ import annotations
import tempfile
import unittest
from pathlib import Path

from ailocaltools.organizer import (
    apply_suggestions,
    build_reason,
    scan_folder,
    suggest_folder_name,
    suggest_tags,
)


class OrganizerTests(unittest.TestCase):
    def test_suggest_folder_name(self) -> None:
        folder = suggest_folder_name(
            Path("/tmp/receipt.pdf"),
            "ファイル名: receipt.pdf / 本文抜粋: Invoice from Apple Store",
        )
        self.assertEqual(folder, "Receipts")

    def test_build_reason(self) -> None:
        reason, confidence = build_reason(Path("/tmp/archive.zip"), "Installers", "zip")
        self.assertIn("Installers", reason)
        self.assertGreater(confidence, 0.5)

    def test_suggest_tags(self) -> None:
        tags = suggest_tags(
            Path("/tmp/スクリーンショット 2026-03-11.png"),
            "Screenshots",
            "OCR抜粋: 請求書 Invoice",
        )
        self.assertIn("スクリーンショット", tags)
        self.assertIn("領収書", tags)

    def test_scan_folder_non_mutating(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            target = root / "スクリーンショット.png"
            target.write_text("fake image", encoding="utf-8")
            before = set(path.name for path in root.iterdir())
            run = scan_folder(root)
            after = set(path.name for path in root.iterdir())
            self.assertEqual(before, after)
            self.assertEqual(run.suggestions[0].target_folder_name, "Screenshots")
            self.assertIn("スクリーンショット", run.suggestions[0].suggested_tags)

    def test_apply_suggestions_moves_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            target = root / "invoice.pdf"
            target.write_text("invoice", encoding="utf-8")

            result = apply_suggestions(
                root,
                [{"source_path": str(target), "target_folder_name": "Receipts"}],
            )

            moved = root / "Receipts" / "invoice.pdf"
            self.assertEqual(result.moved_count, 1)
            self.assertTrue(moved.exists())
            self.assertFalse(target.exists())

    def test_apply_suggestions_avoids_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "notes.txt"
            source.write_text("new", encoding="utf-8")
            receipts = root / "Documents"
            receipts.mkdir()
            existing = receipts / "notes.txt"
            existing.write_text("old", encoding="utf-8")

            result = apply_suggestions(
                root,
                [{"source_path": str(source), "target_folder_name": "Documents"}],
            )

            moved = receipts / "notes 2.txt"
            self.assertEqual(result.moved_count, 1)
            self.assertTrue(existing.exists())
            self.assertTrue(moved.exists())
