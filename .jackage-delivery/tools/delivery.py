#!/usr/bin/env python3
"""Local handoff and evidence tool. This does not implement or certify Jackage."""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform as host_platform
import signal
import subprocess
import sys
import time
import uuid

from oracle import canonical_bytes, digest, portable_path

DEFAULT_KIT = Path(__file__).resolve().parents[1]
ROLES = {"portable", "host", "windows-x86_64", "windows-aarch64",
         "linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64"}
STAGES = {"red", "green", "characterize", "fault", "regression"}


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inside(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("invalid relative pack path")
    parts = relative.split("/")
    if any(p in ("", ".", "..") for p in parts) or ":" in relative:
        raise ValueError("unsafe relative pack path")
    p = root.joinpath(*parts).resolve()
    if not p.is_relative_to(root.resolve()):
        raise ValueError("path escapes pack")
    return p


def catalog(kit: Path):
    cases = load(kit / "acceptance/cases.json")["cases"]
    milestones = load(kit / "acceptance/milestones.json")["milestones"]
    return {c["id"]: c for c in cases}, {m["id"]: m for m in milestones}


def case_digest(case: dict) -> str:
    return hashlib.sha256(canonical_bytes(case)).hexdigest()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds")


def timestamp(value: str) -> dt.datetime:
    result = dt.datetime.fromisoformat(value)
    if result.tzinfo is None:
        raise ValueError("evidence timestamp lacks timezone")
    return result


def native_target() -> str:
    os_name = {"Windows": "windows", "Linux": "linux", "Darwin": "macos"}.get(
        host_platform.system(), host_platform.system().lower())
    arch = host_platform.machine().lower()
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(arch, arch)
    return os_name + "-" + arch


def role_is_native(role: str, actual: str) -> bool:
    if role == "portable":
        return True
    if role == "host":
        # Case zero is the user's Windows host, not the pack author's container.
        return actual.startswith("windows-")
    return role == actual


def git_observation(cwd: Path) -> dict:
    def command(args):
        try:
            run = subprocess.run(["git", *args], cwd=cwd, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=10, check=False)
            return run.stdout if run.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None
    head = command(["rev-parse", "HEAD"])
    status = command(["status", "--porcelain=v1", "-z"])
    diff = command(["diff", "--binary", "HEAD", "--", ".",
                    ":(exclude).jackage-delivery/state"])
    return {
        "observationKind": "git-head-status-and-tracked-diff",
        "head": head.decode("ascii", errors="replace").strip() if head else None,
        "statusSha256": hashlib.sha256(status).hexdigest() if status is not None else None,
        "trackedDiffSha256": hashlib.sha256(diff).hexdigest() if diff is not None else None,
        "untrackedContentIncluded": False,
    }


def save_new(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Unique names avoid overwriting earlier command evidence.
    with path.open("x", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")


def stop_owned_tree(process: subprocess.Popen) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=10, check=False)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


def record_run(kit: Path, case_id: str, stage: str, test_id: str, marker: str,
               command: list[str], cwd: Path, role: str | None = None,
               timeout: float = 300, max_log_bytes: int = 16 * 1024 * 1024) -> dict:
    cases, _ = catalog(kit)
    if case_id not in cases or stage not in STAGES:
        raise ValueError("unknown case or evidence stage")
    case = cases[case_id]
    role = role or case["platforms"][0]
    actual = native_target()
    if role not in case["platforms"] or not role_is_native(role, actual):
        raise ValueError("run the command on its required native platform; do not relabel a host process")
    if not command or not test_id.strip() or not marker:
        raise ValueError("command, test identifier, and an actual test-output marker are required")
    if timeout <= 0 or max_log_bytes <= 0:
        raise ValueError("resource limits must be positive")
    cwd = cwd.resolve(strict=True)
    run_id = uuid.uuid4().hex
    rel_log = "state/evidence/" + run_id + ".log"
    log = inside(kit, rel_log)
    log.parent.mkdir(parents=True, exist_ok=True)
    before = git_observation(cwd)
    started = utc_now()
    infrastructure = None
    code = None
    process = None
    with log.open("xb") as output:
        try:
            kwargs = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
            process = subprocess.Popen(command, cwd=cwd, stdout=output,
                                       stderr=subprocess.STDOUT, shell=False, **kwargs)
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    infrastructure = "timeout"
                    stop_owned_tree(process)
                    break
                if log.stat().st_size > max_log_bytes:
                    infrastructure = "log-limit"
                    stop_owned_tree(process)
                    break
                time.sleep(0.02)
            code = process.wait(timeout=10)
        except KeyboardInterrupt:
            infrastructure = "recorder-canceled"
            if process is not None:
                stop_owned_tree(process)
        except (OSError, subprocess.SubprocessError) as exc:
            infrastructure = type(exc).__name__
            output.write(("Evidence recorder error: " + str(exc) + "\n").encode("utf-8", errors="replace"))
            if process is not None and process.poll() is None:
                stop_owned_tree(process)
    if log.stat().st_size > max_log_bytes:
        infrastructure = infrastructure or "log-limit"
    # Search a bounded log. An over-limit log remains evidence of infrastructure failure.
    content = log.read_bytes() if log.stat().st_size <= max_log_bytes else b""
    marker_found = marker.encode("utf-8") in content
    expected_failure = stage in {"red", "fault"}
    # Signals and launch errors are not relevant assertion failures.
    status_ok = (code is not None and code > 0) if expected_failure else code == 0
    accepted = infrastructure is None and marker_found and status_ok
    record = {
        "schemaVersion": 1, "id": run_id, "case": case_id,
        "caseDigest": case_digest(case), "stage": stage, "testId": test_id,
        "platformRole": role, "actualPlatform": actual,
        "command": command, "cwd": str(cwd), "startedUtc": started,
        "finishedUtc": utc_now(), "exitCode": code, "infrastructureFailure": infrastructure,
        "marker": marker, "markerFound": marker_found,
        "logPath": rel_log, "logSha256": sha_file(log), "acceptedObservation": accepted,
        "sourceBefore": before, "sourceAfter": git_observation(cwd),
        "note": "Local observation only. Review and independent CI replay remain required.",
    }
    save_new(kit / "state/evidence" / (run_id + ".json"), record)
    return record


def evidence(kit: Path, case_id: str) -> list[dict]:
    result = []
    for path in sorted((kit / "state/evidence").glob("*.json")):
        value = load(path)
        if value.get("case") == case_id:
            result.append(value)
    return sorted(result, key=lambda r: timestamp(r["startedUtc"]))


def valid_record(kit: Path, case: dict, record: dict) -> bool:
    try:
        log = inside(kit, record["logPath"])
        if not record["logPath"].startswith("state/evidence/"):
            return False
        expected_fail = record["stage"] in {"red", "fault"}
        code = record["exitCode"]
        status_ok = isinstance(code, int) and code > 0 if expected_fail else code == 0
        return bool(
            record["case"] == case["id"]
            and record["caseDigest"] == case_digest(case)
            and record["stage"] in STAGES
            and record["platformRole"] in case["platforms"]
            and role_is_native(record["platformRole"], record["actualPlatform"])
            and record["acceptedObservation"]
            and record["infrastructureFailure"] is None
            and status_ok and record["marker"]
            and timestamp(record["finishedUtc"]) >= timestamp(record["startedUtc"])
            and log.is_file() and log.stat().st_size <= 16 * 1024 * 1024
            and sha_file(log) == record["logSha256"]
            and record["marker"].encode("utf-8") in log.read_bytes()
        )
    except (KeyError, ValueError, OSError, TypeError):
        return False


def evidence_bundle(kit: Path, case: dict, role: str) -> list[dict]:
    records = [r for r in evidence(kit, case["id"]) if r.get("platformRole") == role]
    if not records:
        raise ValueError("no command evidence for " + case["id"] + " / " + role)
    by_stage = {}
    for r in records:
        by_stage[r["stage"]] = r
    red_candidates = [by_stage[s] for s in ("red", "fault") if s in by_stage]
    if not red_candidates or "green" not in by_stage or "regression" not in by_stage:
        raise ValueError("red/fault, green, and regression evidence are required")
    red = max(red_candidates, key=lambda r: timestamp(r["startedUtc"]))
    green, regression = by_stage["green"], by_stage["regression"]
    bundle = [red, green, regression]
    if red["testId"] != green["testId"] or red["command"] != green["command"]:
        raise ValueError("red and green must use the same named test and command")
    if not (timestamp(red["finishedUtc"]) <= timestamp(green["startedUtc"])
            <= timestamp(green["finishedUtc"]) <= timestamp(regression["startedUtc"])):
        raise ValueError("evidence order must be red, green, then regression")
    if red["stage"] == "fault":
        char = by_stage.get("characterize")
        if char is None or char["testId"] != red["testId"] or char["command"] != red["command"]:
            raise ValueError("a fault route needs the same prior characterization test")
        if timestamp(char["finishedUtc"]) > timestamp(red["startedUtc"]):
            raise ValueError("characterization must precede the deliberate fault")
        bundle.insert(0, char)
    if not all(valid_record(kit, case, r) for r in bundle):
        raise ValueError("invalid, incomplete, wrong-platform, or modified command evidence")
    # A later failed attempt cannot be hidden behind an older successful bundle.
    if timestamp(records[-1]["startedUtc"]) > timestamp(regression["startedUtc"]):
        raise ValueError("run a final regression after the latest command observation")
    return bundle


def review_case(kit: Path, case_id: str, reviewer: str, note: str) -> dict:
    cases, _ = catalog(kit)
    if case_id not in cases or not reviewer.strip() or not note.strip():
        raise ValueError("a known case, named reviewer, and review note are required")
    case = cases[case_id]
    records = [r for role in case["platforms"] for r in evidence_bundle(kit, case, role)]
    review = {
        "schemaVersion": 1, "id": uuid.uuid4().hex, "case": case_id,
        "caseDigest": case_digest(case), "reviewer": reviewer, "note": note,
        "reviewedUtc": utc_now(), "records": [r["id"] for r in records],
        "recordDigests": {r["id"]: hashlib.sha256(canonical_bytes(r)).hexdigest() for r in records},
        "authority": "self-reported local review, not independent attestation",
    }
    save_new(kit / "state/reviews" / (review["id"] + ".json"), review)
    return review


def case_complete(kit: Path, case: dict) -> tuple[bool, str]:
    try:
        records = [r for role in case["platforms"] for r in evidence_bundle(kit, case, role)]
        reviews = [load(p) for p in (kit / "state/reviews").glob("*.json")]
        reviews = [r for r in reviews if r.get("case") == case["id"]]
        if not reviews:
            return False, "review required"
        review = max(reviews, key=lambda r: timestamp(r["reviewedUtc"]))
        expected = {r["id"]: hashlib.sha256(canonical_bytes(r)).hexdigest() for r in records}
        if (review["caseDigest"] != case_digest(case) or review["recordDigests"] != expected
                or set(review["records"]) != set(expected)
                or not review["reviewer"].strip() or not review["note"].strip()):
            return False, "stale or incomplete review"
        if any(timestamp(r["finishedUtc"]) > timestamp(review["reviewedUtc"]) for r in records):
            return False, "review precedes evidence"
        return True, "local evidence structure complete; independent release gates remain"
    except (ValueError, KeyError, OSError, TypeError) as exc:
        return False, str(exc)


def status(kit: Path) -> dict:
    cases, milestones = catalog(kit)
    checks = {cid: case_complete(kit, case) for cid, case in cases.items()}
    phases = []
    completed = set()
    for mid, m in milestones.items():
        ids = [cid for cid,c in cases.items() if c["milestone"] == mid and c["required"]]
        count = sum(checks[cid][0] for cid in ids)
        own = count == len(ids) and len(ids) > 0
        if own:
            completed.add(mid)
        phases.append({"id":mid,"title":m["title"],"completeCases":count,"requiredCases":len(ids),"ownCasesComplete":own})
    # A downstream milestone is not ready through an incomplete ancestor.
    effective = set()
    for _ in range(len(milestones)):
        for mid in completed:
            if all(dep in effective for dep in milestones[mid]["dependsOn"]):
                effective.add(mid)
    for p in phases:
        m = milestones[p["id"]]
        p["ready"] = all(dep in effective for dep in m["dependsOn"])
        p["completeWithPrerequisites"] = p["id"] in effective
    return {"kind":"local-evidence-status", "productCompletionCertified":False,
            "completedCases":sum(v[0] for v in checks.values()), "totalCases":len(cases),
            "milestones":phases}


def validate_kit(kit: Path, integrity: bool = False) -> dict:
    case_list = load(kit / "acceptance/cases.json")["cases"]
    phase_list = load(kit / "acceptance/milestones.json")["milestones"]
    cases, phases = catalog(kit)
    if len(cases) != len(case_list) or len(phases) != len(phase_list):
        raise ValueError("duplicate case or milestone identifier")
    active, visited = set(), set()
    def visit(mid):
        if mid in active:
            raise ValueError("milestone dependency cycle")
        if mid in visited:
            return
        if mid not in phases:
            raise ValueError("unknown prerequisite")
        active.add(mid)
        for dep in phases[mid]["dependsOn"]:
            visit(dep)
        active.remove(mid)
        visited.add(mid)
    for mid in phases:
        visit(mid)
    for case in cases.values():
        if case["milestone"] not in phases or not case["required"]:
            raise ValueError("invalid milestone or silently optional product requirement")
        if not case["platforms"] or any(p not in ROLES for p in case["platforms"]):
            raise ValueError("unknown platform role")
        for field in ("id","title","given","when","then","spec"):
            if not isinstance(case[field], str) or not case[field].strip():
                raise ValueError("empty acceptance field")
        if not inside(kit, case["spec"]).is_file():
            raise ValueError("missing referenced specification")
    vectors = load(kit / "fixtures/canonical-vectors.json")["vectors"]
    for v in vectors:
        if canonical_bytes(v["value"]).hex() != v["canonicalUtf8Hex"]:
            raise ValueError("canonical vector mismatch")
        for domain in ("tree","action","plan"):
            if digest(domain, v["value"]) != v[domain+"Digest"]:
                raise ValueError("digest vector mismatch")
    paths = load(kit / "fixtures/portable-path-vectors.json")["vectors"]
    if any(portable_path(v["path"]) != v["valid"] for v in paths):
        raise ValueError("portable-path vector mismatch")
    schema_files = list((kit / "schemas").glob("*.json"))
    for p in schema_files:
        value = load(p)
        if "$schema" not in value or "$id" not in value:
            raise ValueError("schema metadata missing")
    covered = {c["milestone"] for c in cases.values()}
    if covered != set(phases):
        raise ValueError("a milestone has no acceptance cases")
    manifest_count = 0
    if integrity:
        for line in (kit / "MANIFEST.sha256").read_text(encoding="utf-8").splitlines():
            expected, name = line.split("  ",1)
            p = inside(kit.parent, name)
            if sha_file(p) != expected:
                raise ValueError("static payload changed: " + name)
            manifest_count += 1
    return {"kind":"pack-validation", "productTestsExecuted":False,
            "cases":len(cases), "milestones":len(phases),
            "canonicalVectors":len(vectors), "pathVectors":len(paths),
            "schemaFilesParsed":len(schema_files), "manifestFilesVerified":manifest_count}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    v = sub.add_parser("validate-kit")
    v.add_argument("--integrity", action="store_true")
    sub.add_parser("status")
    sub.add_parser("next")
    g = sub.add_parser("gate")
    g.add_argument("milestone", nargs="?", default="all")
    run = sub.add_parser("run")
    run.add_argument("--case", required=True)
    run.add_argument("--stage", required=True, choices=sorted(STAGES))
    run.add_argument("--test-id", required=True)
    run.add_argument("--marker", required=True)
    run.add_argument("--platform", choices=sorted(ROLES))
    run.add_argument("--timeout", type=float, default=300)
    run.add_argument("--cwd", type=Path, default=Path.cwd())
    run.add_argument("command", nargs=argparse.REMAINDER)
    r = sub.add_parser("review")
    r.add_argument("--case", required=True)
    r.add_argument("--reviewer", required=True)
    r.add_argument("--note", required=True)
    args = parser.parse_args(argv)
    kit = DEFAULT_KIT
    code = 0
    try:
        if args.operation == "validate-kit":
            result = validate_kit(kit, args.integrity)
        elif args.operation in {"status","next","gate"}:
            result = status(kit)
            if args.operation == "next":
                result = {"readyMilestones":[m for m in result["milestones"] if m["ready"] and not m["ownCasesComplete"]]}
            elif args.operation == "gate":
                _, phases = catalog(kit)
                if args.milestone != "all" and args.milestone not in phases:
                    raise ValueError("unknown milestone")
                needed = set(phases) if args.milestone == "all" else {args.milestone}
                def add_deps(mid):
                    for dep in phases[mid]["dependsOn"]:
                        if dep not in needed:
                            needed.add(dep)
                            add_deps(dep)
                for mid in list(needed):
                    add_deps(mid)
                result["milestones"] = [m for m in result["milestones"] if m["id"] in needed]
                result["localGateComplete"] = all(m["ownCasesComplete"] for m in result["milestones"])
                code = 0 if result["localGateComplete"] else 2
        elif args.operation == "run":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            result = record_run(kit,args.case,args.stage,args.test_id,args.marker,command,
                                args.cwd,args.platform,args.timeout)
            code = result["exitCode"] if result["exitCode"] is not None else 2
            if code < 0:
                code = 128 + abs(code)
            if code == 0 and not result["acceptedObservation"]:
                code = 2
        else:
            result = review_case(kit,args.case,args.reviewer,args.note)
        print(json.dumps(result,indent=2,ensure_ascii=False))
        return code
    except (ValueError,KeyError,OSError,TypeError) as exc:
        print(json.dumps({"error":str(exc),"productCompletionCertified":False}),file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
