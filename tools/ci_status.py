#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.github.com"

def remote_slug():
    url = subprocess.run(["git", "remote", "get-url", "origin"],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip()
    match = re.search(r"github\.com[:/]([^/]+)/([^/.]+)", url)
    if not match:
        raise SystemExit("Не удалось разобрать origin: %s" % url)
    return match.group(1), match.group(2)

def token():
    result = subprocess.run(["git", "credential", "fill"], cwd=ROOT,
                            input="protocol=https\nhost=github.com\n\n",
                            capture_output=True, text=True, timeout=60)
    for line in result.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("Нет сохранённых credentials — сначала сделай git push вручную.")

class NoRedirect(urllib.request.HTTPRedirectHandler):

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def get(path, auth, raw=False):
    request = urllib.request.Request(API + path)
    request.add_header("Authorization", "Bearer " + auth)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "talkingjohn-ci-check")
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=60) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        if raw and error.code in (301, 302, 303, 307, 308):
            location = error.headers.get("Location")
            if location:
                plain = urllib.request.Request(location)
                plain.add_header("User-Agent", "talkingjohn-ci-check")
                with urllib.request.urlopen(plain, timeout=120) as response:
                    return response.read()
        raise
    return data if raw else json.loads(data)

def main():
    owner, repo = remote_slug()
    auth = token()

    info = get("/repos/%s/%s" % (owner, repo), auth)
    print("Репозиторий: %s | приватный: %s" % (info["full_name"], info["private"]))

    runs = get("/repos/%s/%s/actions/runs?per_page=5" % (owner, repo), auth)
    if not runs.get("workflow_runs"):
        print("Запусков Actions пока нет.")
        return 0

    for run in runs["workflow_runs"]:
        print("\n#%s %s" % (run["run_number"], run["name"]))
        print("  статус: %s / %s" % (run["status"], run["conclusion"] or "в процессе"))
        print("  коммит: %s" % run["head_sha"][:7])
        print("  ссылка: %s" % run["html_url"])

    latest = runs["workflow_runs"][0]
    jobs = get("/repos/%s/%s/actions/runs/%s/jobs" % (owner, repo, latest["id"]), auth)
    print("\nШаги последнего запуска:")
    for job in jobs.get("jobs", []):
        print("  [%s] %s" % (job["conclusion"] or job["status"], job["name"]))
        for step in job.get("steps", []):
            mark = {"success": "ok", "failure": "FAIL", "skipped": "skip"}.get(
                step["conclusion"], step["status"])
            print("      %-8s %s" % (mark, step["name"]))

    if "--log" in sys.argv:
        for job in jobs.get("jobs", []):
            if job["conclusion"] != "failure":
                continue
            print("\n=== Лог упавшего шага: %s ===" % job["name"])
            try:
                raw = get("/repos/%s/%s/actions/jobs/%s/logs" % (owner, repo, job["id"]),
                          auth, raw=True)
            except urllib.error.HTTPError as error:
                print("  лог недоступен: %s" % error)
                continue
            text = raw.decode("utf-8", errors="replace")
            if "--save" in sys.argv:
                path = os.path.join(ROOT, "ci.log")
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
                print("  полный лог сохранён: %s (%d строк)" % (path, len(text.splitlines())))
            errors = [l for l in text.splitlines() if re.search(r"error:", l)]
            seen = set()
            print("  ошибок: %d" % len(errors))
            for line in errors:
                clean = re.sub(r"^\S+Z\s*", "", line)
                clean = clean.replace(
                    "/Users/runner/work/Talking-bacteria-John-64-bits/Talking-bacteria-John-64-bits/", "")
                if clean in seen:
                    continue
                seen.add(clean)
                print("   " + clean[:240])
    return 0

if __name__ == "__main__":
    sys.exit(main())
