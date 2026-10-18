"""Conservative PR selection; main/manual runs always keep full validation."""

import os
import subprocess


PROSE = {
    "README.md", "CHANGELOG.md", "ARCHITECTURE.md", "CONTRIBUTING.md", "LICENSE",
    "example/README.md", "doc/local-retrieval.md", "doc/resource-input.md",
    "doc/decision-flows.md", "doc/media-models.md", "doc/migration.md",
    "doc/tool-input-schemas.md", "doc/reasoning-history.md", "doc/prompt-caches.md", "doc/bidi-sessions.md", "doc/model-inspection.md", "doc/model-preparation.md",
    "doc/next-token-scoring.md", "doc/live-lora-qualification.md", "doc/observability.md",
    "doc/runtime-isolation-design.md", "doc/runtime-owners.md", "doc/runtime-support.md", "doc/usage.md",
}


def changed_paths():
    if os.environ.get("EVENT_NAME") != "pull_request":
        return None
    base, head = os.environ.get("BASE_SHA", ""), os.environ.get("HEAD_SHA", "")
    if not base or not head:
        return None
    try:
        # Disable rename detection so both the removed and added paths count.
        result = subprocess.run(
            ["git", "diff", "--no-renames", "--name-only", "-z", f"{base}...{head}", "--"],
            check=True, capture_output=True,
        )
    except subprocess.CalledProcessError:
        print("::warning::Could not compare PR revisions; running all checks")
        return None
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def select(paths):
    return {"runtime": not paths or any(path not in PROSE for path in paths)}


if __name__ == "__main__":
    selection = select(changed_paths())
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for lane, enabled in selection.items():
            print(f"{lane}={str(enabled).lower()}", file=output)
    print(f"CI selection: {selection}")
