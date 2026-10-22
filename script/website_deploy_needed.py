"""Compare this validated revision with the last successful production run."""
import json
import os
import subprocess


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


repo = os.environ["GITHUB_REPOSITORY"]
head = os.environ["GITHUB_SHA"]
deployments = api(f"repos/{repo}/deployments?environment=website-production&per_page=100")
base = None
for deployment in deployments:
    statuses = api(f"repos/{repo}/deployments/{deployment['id']}/statuses?per_page=1")
    if statuses and statuses[0]["state"] == "success":
        base = deployment["sha"]
        break

# First run (or no recent successful baseline): publish rather than miss changes.
changed = True
if base:
    result = subprocess.run([
        "git", "diff", "--quiet", base, head, "--", "website/",
        ".github/workflows/ci.yml", "script/website_deploy_needed.py",
    ], check=False)
    if result.returncode not in (0, 1):
        raise SystemExit("Could not compare production baseline; refusing to skip deployment")
    changed = result.returncode == 1
print(f"changed={str(changed).lower()}")
