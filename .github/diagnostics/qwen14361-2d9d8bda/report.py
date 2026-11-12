import argparse
import json
from pathlib import Path
from shutil import copyfile
from xml.etree import ElementTree

COUNTS = ("tests", "errors", "failures", "skipped")
EXPECTED_FAILURES = {"asyncSegmentReceiptNamesTheOriginalCaptureStreamAndOrdinal"}

def cases(path, include_messages):
    report = ElementTree.parse(path).getroot()
    results = []
    for case in report.findall("testcase"):
        problem = next((element for element in case if element.tag in {"failure", "error", "skipped"}), None)
        row = {"name": case.get("name"), "outcome": problem.tag if problem is not None else "passed"}
        if problem is not None and include_messages:
            row["message"] = (problem.get("message") or "")[:1800]
        results.append(row)
    return {"counts": {key: int(report.get(key)) for key in COUNTS}, "cases": results}

def collect_hosted(source, destination):
    source, destination = Path(source), Path(destination)
    for path in (source / "failsafe-reports").glob("TEST-*.HostedShellLifecycleRecoveryIT.xml"):
        (destination / "case-outcomes.json").write_text(json.dumps(cases(path, False), indent=2) + "\n")
    diagnostics = source / "l4-shell-lifecycle/resident-expiry/receipt-diagnostics.json"
    if diagnostics.is_file():
        copyfile(diagnostics, destination / diagnostics.name)

def paired_database_expected(phase, arm, evidence):
    counts = evidence.get("counts")
    if counts is None or evidence["source_restore_exit"] != 0:
        return False
    if arm == "variant":
        return evidence["maven_exit"] == 0 and counts == dict(tests=7, errors=0, failures=0, skipped=0)
    failures = [row for row in evidence["cases"] if row["outcome"] == "failure"]
    return (evidence["maven_exit"] == 1 and counts == dict(tests=7, errors=0, failures=2, skipped=0)
            and len(failures) == 2
            and all(row["name"].split("(")[0].split("[")[0] in EXPECTED_FAILURES
                    and "captureId" in row.get("message", "") and "resourceId" in row.get("message", "")
                    for row in failures))

def read_exit(directory, file):
    path = directory / file
    return int(path.read_text().strip()) if path.is_file() else None

def summarize(root, database_only=False):
    root = Path(root)
    outcome = {}
    database_verified = True
    phases = ("h2", "mysql", "checkstyle") if database_only else ("h2", "mysql", "hosted", "checkstyle")
    for phase in phases:
        outcome[phase] = {}
        for arm in (("variant",) if phase == "checkstyle" else ("base", "variant")):
            directory = root / phase / arm
            evidence = {"maven_exit": read_exit(directory, "maven.exit"),
                        "source_restore_exit": read_exit(directory, "source-restore.exit")}
            if phase in {"h2", "mysql"}:
                paths = list(directory.glob("TEST-*.xml"))
                if len(paths) == 1:
                    evidence.update(cases(paths[0], True))
                evidence["expected"] = paired_database_expected(phase, arm, evidence)
                database_verified &= evidence["expected"]
            elif phase == "hosted":
                for name in ("case-outcomes", "receipt-diagnostics"):
                    path = directory / f"{name}.json"
                    if path.is_file():
                        evidence[name] = json.loads(path.read_text())
                report = evidence.get("case-outcomes", {}).get("counts")
                if evidence["maven_exit"] is None:
                    evidence["hosted_status"] = "not_run"
                elif evidence["maven_exit"] == 0 and evidence["source_restore_exit"] == 0 \
                        and report == dict(tests=1, errors=0, failures=0, skipped=0):
                    evidence["hosted_status"] = "passed"
                elif report and (report["errors"] or report["failures"]):
                    evidence["hosted_status"] = "failed_case"
                else:
                    evidence["hosted_status"] = "incomplete_or_failed_setup"
            outcome[phase][arm] = evidence
    outcome["database_comparison_verified"] = database_verified
    root.mkdir(parents=True, exist_ok=True)
    (root / ("database-summary.json" if database_only else "paired-summary.json")).write_text(json.dumps(outcome, indent=2) + "\n")
    print(json.dumps(outcome, indent=2))
    database_pass = (database_verified and outcome["checkstyle"]["variant"]["maven_exit"] == 0
                     and outcome["checkstyle"]["variant"]["source_restore_exit"] == 0)
    hosted_pass = database_only or all(row["hosted_status"] == "passed" for row in outcome["hosted"].values())
    return 0 if database_pass and hosted_pass else 1

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--hosted-source")
    parser.add_argument("--destination")
    parser.add_argument("--summarize")
    parser.add_argument("--database-only", action="store_true")
    arguments = parser.parse_args()
    if arguments.summarize:
        raise SystemExit(summarize(arguments.summarize, arguments.database_only))
    collect_hosted(arguments.hosted_source, arguments.destination)
