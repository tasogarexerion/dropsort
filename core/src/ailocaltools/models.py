from __future__ import annotations

from dataclasses import asdict, dataclass, field, is_dataclass
from typing import Any, Literal

RequestType = Literal[
    "CheckEnvironment",
    "SummarizeClipboard",
    "SummarizeFile",
    "ScanFolder",
    "ApplyOrganizerSuggestions",
    "ListRecentResults",
]


@dataclass(slots=True)
class EnvironmentStatus:
    shell_supported: bool
    ai_supported: bool
    reason: str
    os_version: str


@dataclass(slots=True)
class SummaryResult:
    title: str
    style: str
    length: str
    summary_text: str
    source_kind: str
    created_at: str


@dataclass(slots=True)
class OrganizerSuggestion:
    source_path: str
    target_folder_name: str
    is_new_folder: bool
    reason_ja: str
    evidence_summary: str
    confidence: float


@dataclass(slots=True)
class OrganizerRun:
    source_root: str
    started_at: str
    suggestions: list[OrganizerSuggestion] = field(default_factory=list)


@dataclass(slots=True)
class OrganizerMoveItem:
    source_path: str
    destination_path: str | None
    target_folder_name: str
    status: str
    message: str


@dataclass(slots=True)
class OrganizerApplyResult:
    source_root: str
    applied_at: str
    moved_count: int
    skipped_count: int
    items: list[OrganizerMoveItem] = field(default_factory=list)


@dataclass(slots=True)
class RecentResults:
    summaries: list[SummaryResult] = field(default_factory=list)
    organizer_runs: list[OrganizerRun] = field(default_factory=list)


@dataclass(slots=True)
class RequestEnvelope:
    type: RequestType
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class ValidationCheck:
    name: str
    input_kind: str
    ok: bool
    duration_ms: int
    details: dict[str, Any] = field(default_factory=dict)
    error: str | None = None


@dataclass(slots=True)
class ValidationSummary:
    total: int
    passed: int
    failed: int


@dataclass(slots=True)
class ValidationReport:
    started_at: str
    environment: EnvironmentStatus
    checks: list[ValidationCheck] = field(default_factory=list)
    summary: ValidationSummary = field(
        default_factory=lambda: ValidationSummary(total=0, passed=0, failed=0)
    )


def to_dict(value: Any) -> Any:
    if is_dataclass(value):
        return {key: to_dict(item) for key, item in asdict(value).items()}
    if isinstance(value, list):
        return [to_dict(item) for item in value]
    if isinstance(value, dict):
        return {key: to_dict(item) for key, item in value.items()}
    return value
