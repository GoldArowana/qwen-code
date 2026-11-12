import os
from pathlib import Path
from xml.etree import ElementTree

root = Path("packages/managed-agent-server/verification/target")
classes = {
    "ToolPublicationAsyncVerificationTest": "surefire-reports",
    "ToolPublicationAsyncVerificationMySqlIT": "failsafe-reports",
    "HostedShellLifecycleRecoveryIT": "failsafe-reports",
}
for class_name, folder in classes.items():
    directory = Path(os.environ["RUNNER_TEMP"]) / "qwen-h2" if folder == "surefire-reports" else root / folder
    reports = list(directory.glob(f"TEST-*.{class_name}.xml"))
    if not reports:
        print(f"{class_name}: no completed XML report")
        continue
    for report in reports:
        suite = ElementTree.parse(report).getroot()
        print(report.name, {key: suite.get(key) for key in ("tests", "errors", "failures", "skipped")})
        for case in suite.findall("testcase"):
            problem = next((item for item in case if item.tag in {"failure", "error", "skipped"}), None)
            print(case.attrib["name"], "passed" if problem is None else problem.tag)
            if problem is not None:
                print((problem.get("message") or "")[:1000])
