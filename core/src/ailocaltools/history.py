from __future__ import annotations

import json
import sqlite3
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

from .models import OrganizerRun, OrganizerSuggestion, RecentResults, SummaryResult


def default_db_path() -> Path:
    support_root = Path.home() / "Library" / "Application Support"
    current = support_root / "DropSort" / "history.sqlite3"
    legacy = support_root / "AppleLocalOrganizer" / "history.sqlite3"
    if not current.exists() and legacy.exists():
        return legacy
    return current


class HistoryStore:
    def __init__(self, db_path: Path | str | None = None) -> None:
        self.db_path = self._prepare_db_path(Path(db_path) if db_path else default_db_path())
        self._initialize()

    def _prepare_db_path(self, path: Path) -> Path:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            return path
        except PermissionError:
            fallback = Path(tempfile.gettempdir()) / "DropSort" / "history.sqlite3"
            fallback.parent.mkdir(parents=True, exist_ok=True)
            return fallback

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path)
        try:
            conn.row_factory = sqlite3.Row
            yield conn
            conn.commit()
        finally:
            conn.close()

    def _initialize(self) -> None:
        with self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS summaries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    style TEXT NOT NULL,
                    length TEXT NOT NULL,
                    summary_text TEXT NOT NULL,
                    source_kind TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS organizer_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_root TEXT NOT NULL,
                    started_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS organizer_suggestions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER NOT NULL REFERENCES organizer_runs(id) ON DELETE CASCADE,
                    source_path TEXT NOT NULL,
                    target_folder_name TEXT NOT NULL,
                    is_new_folder INTEGER NOT NULL,
                    reason_ja TEXT NOT NULL,
                    evidence_summary TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    suggested_tags TEXT NOT NULL DEFAULT '[]',
                    suggested_tag_color TEXT,
                    priority INTEGER NOT NULL DEFAULT 2
                );
                """
            )
            columns = {
                row["name"]
                for row in conn.execute("PRAGMA table_info(organizer_suggestions)")
            }
            if "suggested_tags" not in columns:
                conn.execute(
                    "ALTER TABLE organizer_suggestions ADD COLUMN suggested_tags TEXT NOT NULL DEFAULT '[]'"
                )
            if "suggested_tag_color" not in columns:
                conn.execute(
                    "ALTER TABLE organizer_suggestions ADD COLUMN suggested_tag_color TEXT"
                )
            if "priority" not in columns:
                conn.execute(
                    "ALTER TABLE organizer_suggestions ADD COLUMN priority INTEGER NOT NULL DEFAULT 2"
                )

    def save_summary(self, result: SummaryResult, keep: int = 20) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO summaries(title, style, length, summary_text, source_kind, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    result.title,
                    result.style,
                    result.length,
                    result.summary_text,
                    result.source_kind,
                    result.created_at,
                ),
            )
            self._prune_summaries(conn, keep=keep)

    def save_organizer_run(self, run: OrganizerRun, keep: int = 10) -> None:
        with self._connect() as conn:
            cursor = conn.execute(
                """
                INSERT INTO organizer_runs(source_root, started_at)
                VALUES (?, ?)
                """,
                (run.source_root, run.started_at),
            )
            run_id = int(cursor.lastrowid)
            conn.executemany(
                """
                INSERT INTO organizer_suggestions(
                    run_id, source_path, target_folder_name, is_new_folder, reason_ja,
                    evidence_summary, confidence, suggested_tags, suggested_tag_color, priority
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        run_id,
                        item.source_path,
                        item.target_folder_name,
                        int(item.is_new_folder),
                        item.reason_ja,
                        item.evidence_summary,
                        item.confidence,
                        json.dumps(item.suggested_tags, ensure_ascii=False),
                        item.suggested_tag_color,
                        item.priority,
                    )
                    for item in run.suggestions
                ],
            )
            self._prune_runs(conn, keep=keep)

    def _prune_summaries(self, conn: sqlite3.Connection, keep: int) -> None:
        conn.execute(
            """
            DELETE FROM summaries
            WHERE id NOT IN (
                SELECT id FROM summaries
                ORDER BY datetime(created_at) DESC, id DESC
                LIMIT ?
            )
            """,
            (keep,),
        )

    def _prune_runs(self, conn: sqlite3.Connection, keep: int) -> None:
        rows = conn.execute(
            """
            SELECT id FROM organizer_runs
            ORDER BY datetime(started_at) DESC, id DESC
            LIMIT -1 OFFSET ?
            """,
            (keep,),
        ).fetchall()
        stale_ids = [row["id"] for row in rows]
        if not stale_ids:
            return
        marks = ", ".join("?" for _ in stale_ids)
        conn.execute(
            f"DELETE FROM organizer_suggestions WHERE run_id IN ({marks})",
            stale_ids,
        )
        conn.execute(
            f"DELETE FROM organizer_runs WHERE id IN ({marks})",
            stale_ids,
        )

    def list_recent_results(
        self,
        summary_limit: int = 20,
        organizer_limit: int = 10,
    ) -> RecentResults:
        with self._connect() as conn:
            summaries = [
                SummaryResult(
                    title=row["title"],
                    style=row["style"],
                    length=row["length"],
                    summary_text=row["summary_text"],
                    source_kind=row["source_kind"],
                    created_at=row["created_at"],
                )
                for row in conn.execute(
                    """
                    SELECT title, style, length, summary_text, source_kind, created_at
                    FROM summaries
                    ORDER BY datetime(created_at) DESC, id DESC
                    LIMIT ?
                    """,
                    (summary_limit,),
                )
            ]
            run_rows = conn.execute(
                """
                SELECT id, source_root, started_at
                FROM organizer_runs
                ORDER BY datetime(started_at) DESC, id DESC
                LIMIT ?
                """,
                (organizer_limit,),
            ).fetchall()
            organizer_runs: list[OrganizerRun] = []
            for row in run_rows:
                suggestions = [
                    OrganizerSuggestion(
                        source_path=item["source_path"],
                        target_folder_name=item["target_folder_name"],
                        is_new_folder=bool(item["is_new_folder"]),
                        reason_ja=item["reason_ja"],
                        evidence_summary=item["evidence_summary"],
                        confidence=item["confidence"],
                        suggested_tags=json.loads(item["suggested_tags"] or "[]"),
                        suggested_tag_color=item["suggested_tag_color"],
                        priority=item["priority"],
                    )
                    for item in conn.execute(
                        """
                        SELECT source_path, target_folder_name, is_new_folder, reason_ja,
                               evidence_summary, confidence, suggested_tags, suggested_tag_color, priority
                        FROM organizer_suggestions
                        WHERE run_id = ?
                        ORDER BY priority ASC, confidence DESC, source_path ASC
                        """,
                        (row["id"],),
                    )
                ]
                organizer_runs.append(
                    OrganizerRun(
                        source_root=row["source_root"],
                        started_at=row["started_at"],
                        suggestions=suggestions,
                    )
                )
        return RecentResults(summaries=summaries, organizer_runs=organizer_runs)
