"""BDD cases for real workflow conditions/run blocks; no network actions execute."""
import copy
import itertools
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from __main__ import ContractError, Expression, Workflow, WorkflowReader, equal, evaluate, require, truth


CASES = []


def case(name):
    """Register one executable case; the runner also checks the expected total."""
    def register(function):
        CASES.append((name, function))
        return function
    return register


def rejected(function):
    """Require an assertion/parser rejection, never count an exception as a skip."""
    try:
        function()
    except (ContractError, KeyError):
        return
    raise ContractError("invalid contract unexpectedly accepted")


def context_case(workflow, raw, expected):
    context = workflow.context(raw)
    require(context["env.PUBLISH"] == expected, f"publish={raw!r}: {context}")


for raw, expected in ((None, "true"), ("", "true"), ("true", "true"),
                      ("false", "false"), ("invalid", "false")):
    case(f"event publish={raw!r} normalizes to {expected}")(
        lambda workflow, raw=raw, expected=expected: context_case(workflow, raw, expected))


@case("boolean default and old device choices remain compatible")
def inputs_contract(workflow):
    inputs = workflow.data["on"]["workflow_dispatch"]["inputs"]
    require(inputs["publish"]["type"] == "boolean", "publish is not boolean")
    require(inputs["publish"]["default"] is True, "publish default changed")
    require(inputs["publish"]["required"] is False, "legacy caller must not need publish")
    require(inputs["device"]["options"] == ["all", "r2s", "r3s", "r5s", "r5s-outdoor", "r68s", "x86"],
            "device options changed")
    require(inputs["device"]["default"] == "all", "device default changed")
    require(inputs["openwrt_tag"]["default"] == "v24.10.6", "tag default changed")
    require(workflow.data["env"]["UPLOAD_RELEASE"] is True, "legacy release default changed")
    prepare = next(step for step in workflow.data["jobs"]["prepare"]["steps"]
                   if step.get("name") == "Generate build matrix")
    require(prepare["env"]["INPUT_DEVICE"] == "${{ github.event.inputs.device }}", "matrix input drift")
    with tempfile.TemporaryDirectory(prefix="ci-matrix-") as temporary:
        env = dict(os.environ, INPUT_DEVICE=inputs["device"]["default"],
                   GITHUB_OUTPUT=str(Path(temporary) / "output"))
        result = run(["bash", "-e", "-o", "pipefail", "-c", prepare["run"]],
                     Path(__file__).resolve().parents[3], env)
        print(f"RUN legacy prepare matrix: exit={result.returncode}\n{result.stdout}{result.stderr}", end="")
        require(json.loads(result.stdout) == inputs["device"]["options"][1:], "legacy default matrix changed")


for successful, cancelled, release in itertools.product((True, False), repeat=3):
    case(f"false disables all effects success={successful} cancelled={cancelled} release={release}")(
        lambda workflow, successful=successful, cancelled=cancelled, release=release:
        require(not workflow.effects(workflow.context(
            "false", success=successful, cancelled=cancelled,
            **{"env.UPLOAD_RELEASE": str(release).lower()})), "false allowed a side effect"))


for raw in (None, "true"):
    case(f"normal publish={raw!r} retains all four effects")(
        lambda workflow, raw=raw: require(workflow.effects(workflow.context(raw)) == list(Workflow.EFFECTS),
                                         "normal publishing or cleanup suppressed"))


@case("workflow run cleanup retains implicit success behavior")
def cleanup_status(workflow):
    require(not workflow.eligible("Delete workflow runs", workflow.context("true", success=False)),
            "workflow deletion ignores prior failure")
    require(workflow.eligible("Delete workflow runs", workflow.context("true")), "normal deletion lost")
    context = workflow.context("true", **{"env.UPLOAD_RELEASE": "false"})
    require(workflow.effects(context) == ["Upload firmware to release", "Delete workflow runs"],
            "legacy UPLOAD_RELEASE qualification changed (tag output intentionally forged)")


@case("artifact requires provenance success, not publishing")
def artifact_conditions(workflow):
    require(workflow.eligible("Upload firmware directory", workflow.context("false")), "artifact disabled")
    for failed in ("organize", "provenance"):
        context = workflow.context("false", **{f"steps.{failed}.outputs.status": ""})
        require(not workflow.eligible("Upload firmware directory", context), f"artifact ignores {failed}")
    require(not workflow.eligible("Upload firmware directory", workflow.context("false", cancelled=True)),
            "cancelled artifact allowed")
    record = workflow.get("Record build provenance")
    require(record["id"] == "provenance", "provenance output name drift")
    require(not workflow.eligible("Record build provenance", workflow.context(
        "false", **{"steps.compile.outputs.status": ""})), "record ignores compiler failure")
    upload = workflow.get("Upload firmware directory")
    require(upload["uses"] == "actions/upload-artifact@v7.0.1", "artifact action changed")
    require(upload["with"]["if-no-files-found"] == "error", "empty upload accepted")
    require(upload["with"]["path"] == "${{ env.FIRMWARE }}", "artifact does not consume firmware directory")
    require(upload["with"]["name"] == "OpenWrt_firmware${{ env.DEVICE_NAME }}${{ env.FILE_DATE }}",
            "artifact name compatibility broken")


@case("all checkouts and release tags bind the dispatch SHA")
def checkout_contract(workflow):
    jobs = workflow.data["jobs"]
    require(set(jobs) == {"lint", "prepare", "build"}, "job topology changed")
    for name in jobs:
        checkouts = [step for step in jobs[name]["steps"]
                     if step.get("uses", "").startswith("actions/checkout@")]
        require(len(checkouts) == 1, f"ambiguous {name} checkout")
        require(checkouts[0]["with"]["ref"] == "${{ github.sha }}", f"{name} checkout not SHA-bound")
    release = workflow.get("Upload firmware to release")
    require(release["with"]["target_commitish"] == "${{ github.sha }}", "tag commit not SHA-bound")
    source = workflow.get("Verify source revision")
    require(source["id"] == "source", "source output name drift")
    names = [step["name"] for step in workflow.build]
    require(names.index("Checkout") < names.index("Verify source revision") <
            names.index("Setup Environment and Dependencies"), "source check runs too late")


@case("lint runs the disk-backed suite and compile remains unconditional")
def lint_contract(workflow):
    lint = workflow.data["jobs"]["lint"]["steps"]
    suite = [step for step in lint if step.get("run", "").strip() == "bash tests/bdd-ci-build-only.sh"]
    require(len(suite) == 1 and "if" not in suite[0], "independent suite missing or gated")
    script = "\n".join(step.get("run", "") for step in lint)
    require("shellcheck tests/bdd-ci-build-only.sh" in script, "suite not shellchecked")
    require("tests/bdd-ci-build-only.sh; do" in script, "suite not syntax checked")
    compile_step = workflow.get("Build firmware core (build-firmware.sh)")
    require("if" not in compile_step, "publish must not gate compiler")
    require(workflow.data["jobs"]["build"]["needs"] == "prepare", "build dependency changed")
    require(workflow.data["jobs"]["prepare"]["needs"] == "lint", "lint dependency lost")
    for name in ("Generate build matrix",):
        steps = workflow.data["jobs"]["prepare"]["steps"]
        require(any(step.get("name") == name and "if" not in step for step in steps), "matrix gated")


@case("the declared effects are the real action/API boundaries")
def effect_boundaries(workflow):
    require(workflow.get("Upload firmware to release")["uses"] == "softprops/action-gh-release@v3.0.0",
            "release action changed")
    cleanup = workflow.get("Delete workflow runs")
    require(cleanup["uses"] == "Mattraks/delete-workflow-runs@v2.1.0", "cleanup action changed")
    require(cleanup["with"] == {"retain_days": "0", "keep_minimum_runs": "2"}, "retention changed")
    deletion = workflow.get("Remove old Releases by device")["run"]
    require('-X DELETE' in deletion and '/releases/$ID' in deletion and '/git/refs/tags/$TAG' in deletion,
            "DELETE boundaries missing")
    for step in workflow.build:
        if "action-gh-release@" in step.get("uses", "") or "delete-workflow-runs@" in step.get("uses", ""):
            require(step["name"] in Workflow.EFFECTS, "unclassified external action")
        if re.search(r"-X\s+DELETE", step.get("run", "")):
            require(step["name"] == "Remove old Releases by device", "unguarded DELETE block")
        if "if" in step:
            evaluate(step["if"], workflow.context(), step=True)  # Unsupported conditions fail closed.


@case("Actions coercion, case comparison and status semantics are explicit")
def actions_model(_workflow):
    require(truth("false") and not truth(False) and not truth(None), "truthiness model drift")
    require(equal(None, "") and equal(False, "") and equal(True, "1"), "numeric coercion drift")
    require(equal("TRUE", "true") and not equal("false", False), "string comparison drift")
    context = {"inputs.publish": False, "success": False, "cancelled": False}
    require(evaluate("inputs.publish || true", context) is True, "fallback must expose false bug")
    require(not evaluate("true", context, step=True), "implicit success missing")
    require(evaluate("!cancelled()", context, step=True), "explicit status override missing")
    require(evaluate("(false || true) && !false", context) is True, "precedence drift")
    rejected(lambda: Expression("contains(env.PUBLISH, 'true')", {}).evaluate())
    rejected(lambda: Expression("true ? true : false", {}).evaluate())
    rejected(lambda: Expression("true &&", {}).evaluate())


@case("missing/duplicate steps and unknown YAML are rejected")
def parser_contract(workflow):
    mutated = copy.deepcopy(workflow)
    del mutated.steps["Delete workflow runs"]
    rejected(lambda: mutated.get("Delete workflow runs"))
    rejected(lambda: WorkflowReader("env:\n  PUBLISH: true\n  PUBLISH: false\n").read())
    rejected(lambda: WorkflowReader("env: &shared\n").read())
    rejected(lambda: WorkflowReader("env: >\n  true\n").read())
    # Duplicate and missing production steps are also tested through the full reader.
    data = "\n".join(["jobs:", "  build:", "    steps:"] +
                     [f"    - name: {name}" for name in Workflow.EFFECTS])
    rejected(lambda: Workflow(data + "\n    - name: Delete workflow runs\n"))
    rejected(lambda: Workflow(data.replace("    - name: Delete workflow runs\n", "")))


def run(command, cwd, env=None, check=True):
    """Capture fixture command output; a failed command carries its real diagnostics."""
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, timeout=20)
    if check and result.returncode:
        raise ContractError(f"{command}: exit={result.returncode}\n{result.stdout}{result.stderr}")
    return result


def git(directory, *arguments):
    return run(["git", *arguments], directory).stdout.strip()


def commit(directory, content):
    """Create a distinct fixture commit, never write the project's .git."""
    (directory / "identity").write_text(content)
    git(directory, "add", "identity")
    git(directory, "-c", "user.name=BDD", "-c", "user.email=bdd@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", content)
    return git(directory, "rev-parse", "HEAD")


class BuildFixture:
    """Own disposable git trees/compiler outputs; execute only safe real run blocks."""
    def __init__(self, directory, workflow):
        self.root, self.workflow = directory, workflow
        git(directory, "init", "--quiet")
        self.old_sha = commit(directory, "default-branch")
        git(directory, "checkout", "--quiet", "-b", "feature-ci")
        self.sha = commit(directory, "feature-branch")
        upstream = directory / "openwrt"
        upstream.mkdir()
        git(upstream, "init", "--quiet")
        self.upstream_sha = commit(upstream, "upstream-source")
        self.firmware = directory / "firmware"
        self.firmware.mkdir()
        (self.firmware / "fixture-firmware.img.gz").write_bytes(b"BDD firmware sentinel, not a real image")
        self.env = dict(os.environ, GITHUB_WORKSPACE=str(directory), GITHUB_SHA=self.sha,
                        GITHUB_REF="refs/heads/feature-ci", GITHUB_REPOSITORY="fixture/repository",
                        GITHUB_RUN_ID="991", GITHUB_RUN_ATTEMPT="2", DEVICE="r5s-outdoor",
                        OPENWRT_TAG="v24.10.6", PUBLISH="false", FIRMWARE=str(self.firmware),
                        GITHUB_ENV=str(directory / "github-env"), GITHUB_OUTPUT=str(directory / "github-output"))
        (directory / "scripts").mkdir()
        # Only this boundary is substituted; compile's actual run block is not copied.
        (directory / "scripts/build-firmware.sh").write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            'printf "%s\\n" "$@" > "$GITHUB_WORKSPACE/compiler-args"\n'
            'printf "BUILD_STATUS=success\\n" > "$GITHUB_WORKSPACE/build-vars.env"\n')

    def execute(self, name, checked=True):
        step = self.workflow.get(name)
        env = self.env.copy()
        context = self.workflow.context("false", **{"steps.source.outputs.source_sha": self.sha})
        for key, value in step.get("env", {}).items():
            env[key] = str(evaluate(value, context)) if str(value).startswith("${{") else str(value)
        result = run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", step["run"]],
                     self.root, env, check=checked)
        print(f"RUN {name}: exit={result.returncode}\n{result.stdout}{result.stderr}", end="")
        return result


def with_fixture(workflow, function):
    with tempfile.TemporaryDirectory(prefix="ci-build-only-") as temporary:
        function(BuildFixture(Path(temporary), workflow))


@case("false executes real source/compiler/provenance blocks and retains firmware")
def successful_build(workflow):
    def exercise(fixture):
        fixture.execute("Verify source revision")
        require(f"source_sha={fixture.sha}" in (fixture.root / "github-output").read_text(), "wrong source output")
        fixture.execute("Build firmware core (build-firmware.sh)")
        arguments = (fixture.root / "compiler-args").read_text().splitlines()
        require(arguments == ["--device", "r5s-outdoor", "--tag", "v24.10.6", "--repo-root", str(fixture.root),
                              "--openwrt-dir", str(fixture.root / "openwrt"), "--skip-clone", "--vars-out",
                              str(fixture.root / "build-vars.env")], "actual compiler invocation drift")
        fixture.execute("Record build provenance")
        manifest = json.loads((fixture.firmware / "build-provenance.json").read_text())
        expected = {"repository": "fixture/repository", "ref": "refs/heads/feature-ci", "source_sha": fixture.sha,
                    "openwrt_sha": fixture.upstream_sha, "openwrt_tag": "v24.10.6", "device": "r5s-outdoor",
                    "run_id": "991", "run_attempt": "2", "publish": "false"}
        require(manifest == expected and fixture.sha != fixture.upstream_sha, "provenance does not reflect actual trees")
        require((fixture.firmware / "fixture-firmware.img.gz").is_file(), "firmware sentinel lost")
    with_fixture(workflow, exercise)


for mismatch in ("old-main", "moved-tip", "empty-dispatch"):
    def source_failure(workflow, mismatch=mismatch):
        def exercise(fixture):
            if mismatch == "old-main":
                git(fixture.root, "checkout", "--quiet", fixture.old_sha)
            elif mismatch == "moved-tip":
                commit(fixture.root, "moved-after-dispatch")
            else:
                fixture.env["GITHUB_SHA"] = ""
            require(fixture.execute("Verify source revision", checked=False).returncode != 0,
                    f"source check accepted {mismatch}")
            require(not workflow.eligible("Build firmware core (build-firmware.sh)",
                                          workflow.context("false", success=False)),
                    "compiler condition permits execution after source failure")
            require(not (fixture.root / "compiler-args").exists(), "compiler started after source failure")
            require(not (fixture.firmware / "build-provenance.json").exists(), "false success artifact")
        with_fixture(workflow, exercise)
    case(f"source check rejects {mismatch} before compiler")(source_failure)


for mismatch in ("changed-head", "wrong-source-output", "missing-upstream"):
    def record_failure(workflow, mismatch=mismatch):
        def exercise(fixture):
            fixture.execute("Verify source revision")
            fixture.execute("Build firmware core (build-firmware.sh)")
            if mismatch == "changed-head":
                commit(fixture.root, "changed-during-compile")
            elif mismatch == "wrong-source-output":
                fixture.sha = fixture.old_sha  # The actual HEAD and GITHUB_SHA stay unchanged.
            else:
                (fixture.root / "openwrt/.git").rename(fixture.root / "hidden-upstream-git")
            (fixture.root / "github-output").write_text("before-record\n")
            require(fixture.execute("Record build provenance", checked=False).returncode != 0,
                    f"record accepted {mismatch}")
            require(not (fixture.firmware / "build-provenance.json").exists(), "record written after mismatch")
            require((fixture.root / "github-output").read_text() == "before-record\n", "failed record marked success")
        with_fixture(workflow, exercise)
    case(f"provenance rejects {mismatch} without success output")(record_failure)


for effect in Workflow.EFFECTS:
    def guard_mutation(workflow, effect=effect):
        mutated = copy.deepcopy(workflow)
        step = mutated.get(effect)
        original = step["if"]
        guard = "env.PUBLISH == 'true'"
        require(guard in original, f"no direct guard at {effect}")
        step["if"] = original.replace(guard + " && ", "", 1) if guard + " && " in original else original.replace(guard, "true", 1)
        rejected(lambda: require(not mutated.effects(mutated.context("false")), f"MUTATION {effect} leaks effect"))
        print(f"MUTATION KILLED remove guard: {effect}")
    case(f"mutation removes {effect} guard and must fail")(guard_mutation)


@case("mutation false fallback is rejected")
def fallback_mutation(workflow):
    mutated = copy.deepcopy(workflow)
    mutated.data["env"]["PUBLISH"] = "${{ inputs.publish || true }}"
    rejected(lambda: context_case(mutated, "false", "false"))
    require(mutated.context("false")["env.PUBLISH"] == "true", "typed false fallback not exposed")
    print("MUTATION KILLED truthy string normalization and typed-false fallback")


@case("mutation main checkout is rejected")
def main_mutation(workflow):
    mutated = copy.deepcopy(workflow)
    step = next(step for step in mutated.build if step.get("uses", "").startswith("actions/checkout@"))
    step["with"]["ref"] = "main"
    rejected(lambda: checkout_contract(mutated))
    print("MUTATION KILLED checkout ref=main")


@case("mutation copied input SHA without HEAD check is rejected")
def provenance_mutation(workflow):
    mutated = copy.deepcopy(workflow)
    step = mutated.get("Record build provenance")
    step["run"] = re.sub(r'^.*source_sha = subprocess\.check_output.*$',
                         'source_sha = os.environ["GITHUB_SHA"]', step["run"], flags=re.MULTILINE)
    require(step["run"] != workflow.get("Record build provenance")["run"], "provenance mutation did not apply")
    rejected(lambda: record_failure_for_mutation(mutated))
    print("MUTATION KILLED provenance uses input SHA without reading HEAD")


def record_failure_for_mutation(workflow):
    def exercise(fixture):
        fixture.execute("Verify source revision")
        commit(fixture.root, "changed-before-record")
        require(fixture.execute("Record build provenance", checked=False).returncode != 0,
                "MUTATION provenance accepted changed source")
    with_fixture(workflow, exercise)


# A fixed count catches a truncated registration tail, not just missing calls at runtime.
EXPECTED_CASES = 37


def run_cases(path, baseline):
    """Execute every registered case and print complete per-case diagnostics/counts."""
    text = path.read_text()
    workflow = Workflow(text)
    if baseline:
        effects = workflow.effects(workflow.context("false"))
        print(f"RED BASELINE publish=false effects={json.dumps(effects)}")
        require(set(effects) == set(Workflow.EFFECTS), "baseline did not reproduce all unsafe boundaries")
        require(not workflow.get("Checkout").get("with", {}).get("ref"), "baseline SHA already bound")
        print("RED BASELINE observed real old conditions: 4 side effects eligible, checkout unbound")
        return 0
    require(len(CASES) == EXPECTED_CASES, f"expected {EXPECTED_CASES} registered cases, got {len(CASES)}")
    passed = failed = 0
    for name, function in CASES:
        try:
            function(workflow)
            print(f"PASS {name}")
            passed += 1
        except (ContractError, KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"FAIL {name}: {error}")
            failed += 1
    ran = passed + failed
    print(f"ran={ran} passed={passed} failed={failed} expected={EXPECTED_CASES}")
    return 0 if ran == EXPECTED_CASES and failed == 0 else 1
