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
AUDIO_EXTENSIONS = {".mp3", ".m4a", ".wav", ".aac", ".flac"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v"}

FOLDER_SCREENSHOTS = "スクリーンショット"
FOLDER_RECEIPTS = "領収書"
FOLDER_IMAGES = "画像"
FOLDER_INSTALLERS = "インストーラ"
FOLDER_CODE = "コード"
FOLDER_MEETING_NOTES = "議事録"
FOLDER_DOCUMENTS = "書類"
FOLDER_DATA = "データ"
FOLDER_AUDIO = "音楽"
FOLDER_VIDEO = "動画"
FOLDER_DESIGN = "デザイン"
FOLDER_MISC = "その他"


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
        suggested_tags = suggest_tags(item, folder, evidence.evidence_summary)
        suggested_tag_color = suggest_tag_color(item, folder, evidence.evidence_summary)
        priority = suggest_priority(item, folder, evidence.evidence_summary)
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
                suggested_tags=suggested_tags,
                suggested_tag_color=suggested_tag_color,
                priority=priority,
            )
        )

    run = OrganizerRun(
        source_root=str(source_root),
        started_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        suggestions=sorted(suggestions, key=lambda item: (item.priority, -item.confidence, item.source_path)),
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

        try:
            target_dir = _next_available_directory(source_root / folder_name)
            target_dir.mkdir(parents=True, exist_ok=True)
            destination = _next_available_destination(target_dir / source.name)
            actual_folder_name = target_dir.name
            shutil.move(str(source), str(destination))
            moved_count += 1
            results.append(
                OrganizerMoveItem(
                    source_path=str(source),
                    destination_path=str(destination),
                    target_folder_name=actual_folder_name,
                    status="moved",
                    message=f"{actual_folder_name} へ移動しました。",
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
        return FOLDER_SCREENSHOTS
    if suffix in IMAGE_EXTENSIONS:
        if any(token in lowered_evidence for token in ["receipt", "invoice", "領収", "請求"]):
            return FOLDER_RECEIPTS
        return FOLDER_IMAGES
    if suffix in ARCHIVE_EXTENSIONS:
        return FOLDER_INSTALLERS
    if suffix in CODE_EXTENSIONS:
        return FOLDER_CODE
    if suffix in DOCUMENT_EXTENSIONS:
        if any(token in lowered_evidence for token in ["receipt", "invoice", "領収", "請求"]):
            return FOLDER_RECEIPTS
        if any(token in lowered_evidence for token in ["meeting", "議事録", "minutes"]):
            return FOLDER_MEETING_NOTES
        return FOLDER_DOCUMENTS
    if suffix in {".csv", ".xlsx", ".numbers"}:
        return FOLDER_DATA
    if suffix in AUDIO_EXTENSIONS:
        return FOLDER_AUDIO
    if suffix in VIDEO_EXTENSIONS:
        return FOLDER_VIDEO
    if any(token in lowered_evidence for token in ["design", "figma", "mock", "wireframe"]):
        return FOLDER_DESIGN
    return _sanitize_folder_name(path.suffix.lower().replace(".", "").title() or FOLDER_MISC)


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
    if folder in {FOLDER_RECEIPTS, FOLDER_SCREENSHOTS, FOLDER_INSTALLERS}:
        confidence += 0.1
    return reason, min(confidence, 0.95)


def suggest_tags(path: Path, folder: str, evidence_summary: str) -> list[str]:
    suffix = path.suffix.lower()
    lowered_name = path.name.lower()
    lowered_evidence = evidence_summary.lower()
    tags: list[str] = []

    if folder == FOLDER_SCREENSHOTS or "screenshot" in lowered_name or "スクリーンショット" in path.name:
        tags.extend(["スクリーンショット", "要確認"])
    elif folder == FOLDER_RECEIPTS:
        tags.extend(["領収書", "会計"])
    elif folder == FOLDER_INSTALLERS:
        tags.append("インストーラ")
    elif folder == FOLDER_CODE:
        tags.append("コード")
    elif folder == FOLDER_DOCUMENTS:
        tags.append("書類")
    elif folder == FOLDER_MEETING_NOTES:
        tags.append("議事録")
    elif folder == FOLDER_IMAGES:
        tags.append("画像")
    elif folder == FOLDER_DATA:
        tags.append("データ")
    elif folder == FOLDER_AUDIO:
        tags.append("音楽")
    elif folder == FOLDER_VIDEO:
        tags.append("動画")
    elif folder == FOLDER_DESIGN:
        tags.append("デザイン")

    if suffix == ".pdf":
        tags.append("PDF")
    if suffix in IMAGE_EXTENSIONS and "画像" not in tags and "スクリーンショット" not in tags:
        tags.append("画像")
    if any(token in lowered_evidence for token in ["invoice", "receipt", "領収", "請求"]):
        tags.extend(["領収書", "会計"])
    if any(token in lowered_evidence for token in ["meeting", "minutes", "議事録"]):
        tags.append("議事録")

    deduped: list[str] = []
    for tag in tags:
        cleaned = tag.strip()
        if cleaned and cleaned not in deduped:
            deduped.append(cleaned)
    return deduped[:3]


def suggest_tag_color(path: Path, folder: str, evidence_summary: str) -> str | None:
    lowered_name = path.name.lower()
    lowered_evidence = evidence_summary.lower()

    if folder == FOLDER_RECEIPTS or any(token in lowered_evidence for token in ["invoice", "receipt", "領収", "請求"]):
        return "red"
    if folder == FOLDER_INSTALLERS:
        return "orange"
    if folder == FOLDER_SCREENSHOTS or "screenshot" in lowered_name or "スクリーンショット" in path.name:
        return "yellow"
    if folder in {FOLDER_DOCUMENTS, FOLDER_MEETING_NOTES}:
        return "blue"
    if folder in {FOLDER_IMAGES, FOLDER_DESIGN}:
        return "purple"
    if folder in {FOLDER_CODE, FOLDER_DATA}:
        return "green"
    if folder in {FOLDER_AUDIO, FOLDER_VIDEO}:
        return "gray"
    return None


def suggest_priority(path: Path, folder: str, evidence_summary: str) -> int:
    lowered_name = path.name.lower()
    lowered_evidence = evidence_summary.lower()
    if folder == FOLDER_RECEIPTS or any(token in lowered_evidence for token in ["invoice", "receipt", "領収", "請求"]):
        return 1
    if folder == FOLDER_INSTALLERS:
        return 1
    if folder == FOLDER_SCREENSHOTS or "screenshot" in lowered_name or "スクリーンショット" in path.name:
        return 2
    if path.suffix.lower() == ".pdf":
        return 2
    return 3


def _sanitize_folder_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9 _\-\u3040-\u30ff\u31f0-\u31ff\u3400-\u4dbf\u4e00-\u9fff]+", "", value).strip()
    return cleaned or FOLDER_MISC


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


def _next_available_directory(path: Path) -> Path:
    if not path.exists():
        return path
    if path.is_dir():
        return path
    base_name = path.name
    counter = 2
    while True:
        candidate = path.with_name(f"{base_name} {counter}")
        if not candidate.exists():
            return candidate
        if candidate.is_dir():
            return candidate
        counter += 1
