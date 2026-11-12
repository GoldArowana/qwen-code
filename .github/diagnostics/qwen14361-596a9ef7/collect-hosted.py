"""Print bounded diagnostics from the local fake-model Hosted Shell fixture."""

import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import stat
import sys

EVIDENCE = Path("packages/managed-agent-server/verification/target/l4-shell-lifecycle")
CASES = ("resident-expiry", "spring-kill", "settle-ack", "detach-ack")
MAX_ENTRIES_PER_CASE = 256
MAX_FILES_PER_CASE = 16
MAX_BYTES_PER_FILE = 2 * 1024 * 1024

SIGNATURES = {
    "publication_verification_handling_failed": rb"Tool publication verification handling failed",
    "publication_verification_expired": rb"Tool publication verification expired",
    "original_segment_receipt_conflicts": rb"Original segment receipt conflicts",
    "original_publication_receipt_conflicts": rb"Original publication receipt conflicts",
    "original_receipt_is_missing": rb"Original receipt is missing",
    "receipt_error_text": rb"(?i)(?:receipt[^\r\n]{0,80}(?:invalid|missing|conflict|mismatch|malformed|failed|unexpected)|(?:invalid|missing|malformed|unexpected)[^\r\n]{0,80}receipt)",
    "publication_error_text": rb"(?i)publication[^\r\n]{0,80}(?:failed|expired|denied|timeout|conflict)",
    "segment_resource_shape_marker": rb"(?i)managed-tool-segment",
    "segment_identifier_shape_marker": rb"(?i)captureId[^\r\n]{0,256}streamId[^\r\n]{0,128}ordinal",
    "capture_stdout_marker": rb"L4_CAPTURE_STDOUT",
    "recovery_complete_marker": rb"L4_SHELL_RECOVERY_OK",
}
SAFE_CODES = (
    "managed_tool_publication_busy",
    "managed_tool_publication_capacity_exhausted",
    "managed_tool_publication_claim_expired",
    "managed_tool_publication_claim_lost",
    "managed_tool_publication_failed",
    "managed_tool_publication_operation_expired",
    "managed_tool_publication_operation_unknown",
    "managed_tool_publication_predecessor_failed",
    "managed_tool_publication_quota_exhausted",
    "managed_tool_publication_retention_exhausted",
    "managed_tool_publication_storage_denied",
    "managed_tool_publication_unknown",
    "managed_tool_result_conflict",
    "managed_tool_result_digest_mismatch",
    "ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "EACCES", "ENOENT",
)
SIGNATURES = {name: re.compile(expression) for name, expression in SIGNATURES.items()}
CODE_RE = re.compile(rb"(?<![A-Za-z0-9_])(?:" + b"|".join(code.encode() for code in SAFE_CODES) + rb")(?![A-Za-z0-9_])")


def role(path):
    if path == Path("evidence.json"):
        return "fixture_evidence"
    if path == Path("harness.log"):
        return "harness"
    if len(path.parts) == 1 and re.fullmatch(r"spring-[0-9]+\.log", path.name):
        return "spring"
    if path.parts[:3] == ("runtime", "debug", "daemon"):
        return "daemon"
    return "other_process_log"


def counts(pattern, chunks):
    return sum(sum(1 for _ in pattern.finditer(chunk)) for chunk in chunks)


def read_record(path, relative):
    # Emit file roles and hashes only. Raw filenames can contain fixture IDs.
    record = {
        "role": role(relative),
        "path_sha256": hashlib.sha256(os.fsencode(relative.as_posix())).hexdigest(),
    }
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        with os.fdopen(os.open(path, flags), "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                return {**record, "status": "not_regular"}
            record["bytes"] = metadata.st_size
            if metadata.st_size <= MAX_BYTES_PER_FILE:
                chunks = [source.read(MAX_BYTES_PER_FILE)]
                record["sample"] = "full"
            else:
                half = MAX_BYTES_PER_FILE // 2
                first = source.read(half)
                source.seek(metadata.st_size - half)
                chunks = [first, source.read(half)]
                record["sample"] = "prefix_and_suffix"
    except OSError:
        return {**record, "status": "read_failed"}

    record["status"] = "read"
    record["sample_sha256"] = [hashlib.sha256(chunk).hexdigest() for chunk in chunks]
    if record["role"] == "fixture_evidence":
        if record["sample"] != "full":
            return {**record, "fixture_evidence_status": "too_large"}
        try:
            data = json.loads(chunks[0])
        except (ValueError, UnicodeError):
            return {**record, "fixture_evidence_status": "malformed"}
        if not isinstance(data, dict):
            return {**record, "fixture_evidence_status": "malformed"}
        record["fixture_evidence_status"] = "parsed"
        record["stop_proof_verified"] = data.get("originalStopProofVerified") is True
        lost_replies = data.get("lostReplies")
        if type(lost_replies) is int and lost_replies in (0, 1):
            record["lost_replies"] = lost_replies
        return record

    record["signature_counts"] = {
        name: count for name, pattern in SIGNATURES.items() if (count := counts(pattern, chunks))
    }
    code_counts = {}
    for chunk in chunks:
        for match in CODE_RE.finditer(chunk):
            code = match.group().decode("ascii")
            code_counts[code] = code_counts.get(code, 0) + 1
    record["safe_code_counts"] = code_counts
    return record


def scan_case(directory, case):
    path = directory / case
    result = {"case": case, "files": []}
    if path.is_symlink() or not path.is_dir():
        return {**result, "status": "case_directory_missing", "process_log_count": 0}
    entries = list(itertools.islice(path.rglob("*"), MAX_ENTRIES_PER_CASE + 1))
    available = [
        entry for entry in entries[:MAX_ENTRIES_PER_CASE]
        if not entry.is_symlink() and entry.is_file()
        and (entry.suffix == ".log" or entry.relative_to(path) == Path("evidence.json"))
    ]
    result["directory_scan_limited"] = len(entries) > MAX_ENTRIES_PER_CASE
    result["file_scan_limited"] = len(available) > MAX_FILES_PER_CASE
    result["files"] = [
        read_record(entry, entry.relative_to(path))
        for entry in sorted(available)[:MAX_FILES_PER_CASE]
    ]
    logs = [file for file in result["files"] if file["role"] != "fixture_evidence"]
    result["process_log_count"] = len(logs)
    result["readable_process_log_count"] = sum(file["status"] == "read" for file in logs)
    result["status"] = "process_logs_present" if logs else "no_process_logs_found"
    return result


def main():
    checkout = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
    root = checkout / EVIDENCE
    exists = root.is_dir() and not root.is_symlink()
    report = {
        "evidence_directory_present": exists,
        "cases": [scan_case(root, case) if exists else {
            "case": case, "status": "evidence_directory_missing", "process_log_count": 0, "files": [],
        } for case in CASES],
        "scope": "Counts cover scanned bytes. Log markers alone do not establish causality.",
    }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
