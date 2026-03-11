from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any

from .environment import check_environment
from .history import HistoryStore
from .ingest import ingest_clipboard, ingest_path
from .models import RequestEnvelope, to_dict
from .organizer import apply_suggestions, scan_folder
from .summary import SummaryConfig, summarize_ingested


def _history_store() -> HistoryStore:
    db_override = os.getenv("APPLE_LOCAL_AI_HISTORY_DB")
    return HistoryStore(db_override)


async def handle_request(envelope: RequestEnvelope) -> dict[str, Any]:
    if envelope.type == "CheckEnvironment":
        return to_dict(check_environment())

    if envelope.type == "SummarizeClipboard":
        history = _history_store()
        cfg = SummaryConfig(
            style=envelope.payload.get("style", "bullets"),
            length=envelope.payload.get("length", "short"),
            system_prompt=envelope.payload.get("instruction"),
        )
        content = ingest_clipboard()
        result = await summarize_ingested(content, cfg)
        history.save_summary(result)
        return to_dict(result)

    if envelope.type == "SummarizeFile":
        history = _history_store()
        path = envelope.payload["path"]
        cfg = SummaryConfig(
            style=envelope.payload.get("style", "bullets"),
            length=envelope.payload.get("length", "short"),
            system_prompt=envelope.payload.get("instruction"),
        )
        content = ingest_path(path)
        result = await summarize_ingested(content, cfg)
        history.save_summary(result)
        return to_dict(result)

    if envelope.type == "ExtractFileText":
        path = envelope.payload["path"]
        content = ingest_path(path)
        return to_dict(
            {
                "title": os.path.basename(path),
                "source_kind": content.source_kind,
                "extracted_text": content.text.strip(),
                "evidence_summary": content.evidence_summary,
                "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
            }
        )

    if envelope.type == "ScanFolder":
        history = _history_store()
        run = scan_folder(
            envelope.payload["path"],
            history_store=history,
        )
        return to_dict(run)

    if envelope.type == "ApplyOrganizerSuggestions":
        suggestions = json.loads(envelope.payload["suggestions_json"])
        result = apply_suggestions(
            envelope.payload["source_root"],
            suggestions=suggestions,
        )
        return to_dict(result)

    if envelope.type == "ListRecentResults":
        history = _history_store()
        return to_dict(history.list_recent_results())

    raise ValueError(f"Unknown request type: {envelope.type}")


def parse_request(raw: str) -> RequestEnvelope:
    payload = json.loads(raw)
    if "type" not in payload:
        raise ValueError("Request is missing 'type'.")
    return RequestEnvelope(
        type=payload["type"],
        payload=payload.get("payload", {}),
    )


async def run_from_stream(raw: str) -> int:
    try:
        envelope = parse_request(raw)
        result = await handle_request(envelope)
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(
            json.dumps({"ok": False, "error": {"message": str(exc)}}, ensure_ascii=False),
            file=sys.stdout,
        )
        return 1


def cli_main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args:
        raw = " ".join(args)
    else:
        raw = sys.stdin.read()
    if not raw.strip():
        print(
            json.dumps(
                {"ok": False, "error": {"message": "No JSON request provided."}},
                ensure_ascii=False,
            )
        )
        return 1
    return asyncio.run(run_from_stream(raw))


if __name__ == "__main__":
    raise SystemExit(cli_main())
