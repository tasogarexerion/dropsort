from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

from .bridge import handle_request
from .models import RequestEnvelope, to_dict
from .validation import validate_device


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="DropSort core CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("check-environment")

    summary_clipboard = subparsers.add_parser("summarize-clipboard")
    _add_summary_options(summary_clipboard)

    summary_file = subparsers.add_parser("summarize-file")
    summary_file.add_argument("path")
    _add_summary_options(summary_file)

    extract_file = subparsers.add_parser("extract-file-text")
    extract_file.add_argument("path")

    scan_folder = subparsers.add_parser("scan-folder")
    scan_folder.add_argument("path")

    apply_run = subparsers.add_parser("apply-run")
    apply_run.add_argument("run_json", help="Path to a JSON file created from scan-folder output")

    subparsers.add_parser("list-recent")

    validate_device_parser = subparsers.add_parser("validate-device")
    validate_device_parser.add_argument("--report", required=True)
    validate_device_parser.add_argument(
        "--fixtures",
        default="fixtures/generated",
        help="Directory containing generated validation fixtures",
    )
    validate_device_parser.add_argument(
        "--samples",
        help="Optional directory of redacted device samples",
    )
    return parser


def _add_summary_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--style",
        default="bullets",
        choices=["plain", "bullets", "action-items", "title-and-summary"],
    )
    parser.add_argument(
        "--length",
        default="short",
        choices=["short", "medium", "long"],
    )
    parser.add_argument("--instruction")


async def _dispatch(args: argparse.Namespace) -> dict:
    if args.command == "check-environment":
        request = RequestEnvelope(type="CheckEnvironment")
    elif args.command == "summarize-clipboard":
        request = RequestEnvelope(
            type="SummarizeClipboard",
            payload={
                "style": args.style,
                "length": args.length,
                "instruction": args.instruction,
            },
        )
    elif args.command == "summarize-file":
        request = RequestEnvelope(
            type="SummarizeFile",
            payload={
                "path": args.path,
                "style": args.style,
                "length": args.length,
                "instruction": args.instruction,
            },
        )
    elif args.command == "extract-file-text":
        request = RequestEnvelope(
            type="ExtractFileText",
            payload={"path": args.path},
        )
    elif args.command == "scan-folder":
        request = RequestEnvelope(
            type="ScanFolder",
            payload={"path": args.path},
        )
    elif args.command == "apply-run":
        run = json.loads(Path(args.run_json).read_text(encoding="utf-8"))
        request = RequestEnvelope(
            type="ApplyOrganizerSuggestions",
            payload={
                "source_root": run["source_root"],
                "suggestions_json": json.dumps(run["suggestions"], ensure_ascii=False),
            },
        )
    elif args.command == "list-recent":
        request = RequestEnvelope(type="ListRecentResults")
    elif args.command == "validate-device":
        result = await validate_device(
            report_path=args.report,
            fixtures_dir=args.fixtures,
            samples_dir=args.samples,
        )
        return to_dict(result)
    else:
        raise ValueError(f"Unsupported command: {args.command}")
    return await handle_request(request)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        result = asyncio.run(_dispatch(args))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def legacy_summary_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Minimal local summarizer for Apple Foundation Models")
    src = parser.add_mutually_exclusive_group()
    src.add_argument("--text", help="Input text")
    src.add_argument("--file", help="Path to a UTF-8 text file")
    src.add_argument("--clipboard", action="store_true", help="Read from macOS clipboard")
    parser.add_argument(
        "--style",
        choices=["plain", "bullets", "action-items", "title-and-summary"],
        default="bullets",
    )
    parser.add_argument(
        "--length",
        choices=["short", "medium", "long"],
        default="short",
    )
    parser.add_argument("--instruction")
    args = parser.parse_args(argv)

    if args.text:
        temp_file = Path("/tmp/apple_local_organizer_input.txt")
        temp_file.write_text(args.text, encoding="utf-8")
        return main(
            [
                "summarize-file",
                str(temp_file),
                "--style",
                args.style,
                "--length",
                args.length,
            ]
            + (["--instruction", args.instruction] if args.instruction else [])
        )
    if args.file:
        return main(
            [
                "summarize-file",
                args.file,
                "--style",
                args.style,
                "--length",
                args.length,
            ]
            + (["--instruction", args.instruction] if args.instruction else [])
        )
    return main(
        [
            "summarize-clipboard",
            "--style",
            args.style,
            "--length",
            args.length,
        ]
        + (["--instruction", args.instruction] if args.instruction else [])
    )


if __name__ == "__main__":
    raise SystemExit(main())
