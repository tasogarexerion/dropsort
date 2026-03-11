from __future__ import annotations

import asyncio
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

from .history import HistoryStore
from .ingest import IMAGE_EXTENSIONS, PDF_EXTENSIONS, TEXT_EXTENSIONS, ingest_path
from .models import OrganizerApplyResult, OrganizerMoveItem, OrganizerRun, OrganizerSuggestion
from .summary import SummaryClient, generate_japanese_reason

ARCHIVE_EXTENSIONS = {".zip", ".dmg", ".pkg", ".tar", ".gz", ".7z"}
CODE_EXTENSIONS = {".py", ".js", ".ts", ".swift", ".json", ".yaml", ".yml"}
DOCUMENT_EXTENSIONS = TEXT_EXTENSIONS | PDF_EXTENSIONS | {".docx", ".pages"}


def scan_folder(
    root: str | Path,
    history_store: HistoryStore | None = None,
    ai_client: SummaryClient | None = None,
) -> OrganizerRun:
    source_root = Path(root).expanduser().resolve()
    if not source_root.exists() or not source_root.is_dir():
        raise NotADirectoryError(f"Folder not found: {source_root}")

    suggestions: list[OrganizerSuggestion] = []
    for item in sorted(source_root.iterdir(), key=lambda candidate: candidate.name.lower()):
        if item.name.startswith(".") or item.is_dir():
            continue
        evidence = ingest_path(item)
        folder = suggest_folder_name(item, evidence.evidence_summary)
        is_new = not (source_root / folder).exists()
        reason, confidence = build_reason(item, folder, evidence.evidence_summary)
        if ai_client and evidence.evidence_summary:
            try:
                reason, confidence = asyncio.run(
                    generate_japanese_reason(
                        evidence_summary=evidence.evidence_summary,
                        suggested_folder=folder,
                        client=ai_client,
                    )
                )
            except Exception:
                pass
        suggestions.append(
            OrganizerSuggestion(
                source_path=str(item),
                target_folder_name=folder,
                is_new_folder=is_new,
                reason_ja=reason,
                evidence_summary=evidence.evidence_summary,
                confidence=round(confidence, 2),
            )
        )

    run = OrganizerRun(
        source_root=str(source_root),
        started_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        suggestions=sorted(suggestions, key=lambda item: (-item.confidence, item.source_path)),
    )
    if history_store:
        history_store.save_organizer_run(run)
    return run


def apply_suggestions(
    root: str | Path,
    suggestions: list[dict[str, str]] | list[OrganizerSuggestion],
) -> OrganizerApplyResult:
    source_root = Path(root).expanduser().resolve()
    if not source_root.exists() or not source_root.is_dir():
        raise NotADirectoryError(f"Folder not found: {source_root}")

    results: list[OrganizerMoveItem] = []
    moved_count = 0
    skipped_count = 0

    for raw in suggestions:
        if isinstance(raw, OrganizerSuggestion):
            source_path = raw.source_path
            target_folder_name = raw.target_folder_name
        else:
            source_path = raw["source_path"]
            target_folder_name = raw["target_folder_name"]

        source = Path(source_path).expanduser().resolve()
        folder_name = _sanitize_folder_name(target_folder_name)

        try:
            source.relative_to(source_root)
        except ValueError:
            skipped_count += 1
            results.append(
                OrganizerMoveItem(
                    source_path=str(source),
                    destination_path=None,
                    target_folder_name=folder_name,
                    status="skipped",
                    message="対象フォルダ直下のファイルではないため移動しませんでした。",
                )
            )
            continue

        if not source.exists() or not source.is_file():
            skipped_count += 1
            results.append(
                OrganizerMoveItem(
                    source_path=str(source),
                    destination_path=None,
                    target_folder_name=folder_name,
                    status="skipped",
                    message="元ファイルが見つからないため移動しませんでした。",
                )
            )
            continue

        target_dir = source_root / folder_name
        target_dir.mkdir(parents=True, exist_ok=True)
        destination = _next_available_destination(target_dir / source.name)

        try:
            shutil.move(str(source), str(destination))
            moved_count += 1
            results.append(
                OrganizerMoveItem(
                    source_path=str(source),
                    destination_path=str(destination),
                    target_folder_name=folder_name,
                    status="moved",
                    message=f"{folder_name} へ移動しました。",
                )
            )
        except Exception as exc:
            skipped_count += 1
            results.append(
                OrganizerMoveItem(
                    source_path=str(source),
                    destination_path=None,
                    target_folder_name=folder_name,
                    status="error",
                    message=f"移動できませんでした: {exc}",
                )
            )

    return OrganizerApplyResult(
        source_root=str(source_root),
        applied_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        moved_count=moved_count,
        skipped_count=skipped_count,
        items=results,
    )


def suggest_folder_name(path: Path, evidence_summary: str) -> str:
    suffix = path.suffix.lower()
    name = path.stem.lower()
    lowered_evidence = evidence_summary.lower()

    if "screenshot" in name or "スクリーンショット" in path.name:
        return "Screenshots"
    if suffix in IMAGE_EXTENSIONS:
        if any(token in lowered_evidence for token in ["receipt", "invoice", "領収", "請求"]):
            return "Receipts"
        return "Images"
    if suffix in ARCHIVE_EXTENSIONS:
        return "Installers"
    if suffix in CODE_EXTENSIONS:
        return "Code"
    if suffix in DOCUMENT_EXTENSIONS:
        if any(token in lowered_evidence for token in ["receipt", "invoice", "領収", "請求"]):
            return "Receipts"
        if any(token in lowered_evidence for token in ["meeting", "議事録", "minutes"]):
            return "Meeting Notes"
        return "Documents"
    if suffix in {".csv", ".xlsx", ".numbers"}:
        return "Data"
    if suffix in {".mp3", ".m4a", ".wav", ".mp4", ".mov"}:
        return "Media"
    if any(token in lowered_evidence for token in ["design", "figma", "mock", "wireframe"]):
        return "Design Assets"
    return _sanitize_folder_name(path.suffix.lower().replace(".", "").title() or "Misc")


def build_reason(path: Path, folder: str, evidence_summary: str) -> tuple[str, float]:
    suffix = path.suffix.lower()
    basis = []
    if suffix:
        basis.append(f"{suffix} ファイル")
    if evidence_summary:
        basis.append("内容やメタデータ")
    if "screenshot" in path.name.lower():
        basis.append("ファイル名")
    reason = f"{'・'.join(basis)} をもとに {folder} へ整理する候補です。"
    confidence = 0.55
    if suffix in IMAGE_EXTENSIONS | DOCUMENT_EXTENSIONS | ARCHIVE_EXTENSIONS:
        confidence += 0.15
    if len(evidence_summary) > 50:
        confidence += 0.15
    if folder in {"Receipts", "Screenshots", "Installers"}:
        confidence += 0.1
    return reason, min(confidence, 0.95)


def _sanitize_folder_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9 _-]+", "", value).strip()
    return cleaned or "Misc"


def _next_available_destination(path: Path) -> Path:
    if not path.exists():
        return path
    stem = path.stem
    suffix = path.suffix
    counter = 2
    while True:
        candidate = path.with_name(f"{stem} {counter}{suffix}")
        if not candidate.exists():
            return candidate
        counter += 1
