"""Check that nothing private would be published with this repo. Run before every push.

    python scripts/check_public_safety.py

What it checks, over every tracked file AND every commit in the history (a file deleted later
is still in the history, and a push publishes the history):

1. Commit identities: every author and committer email must be a GitHub noreply address
   (or a bot/co-author noreply address in a trailer).
2. Local paths: no absolute home-directory paths (C:\\Users\\<name>, /c/Users/<name>,
   /home/<name>, /Users/<name>), which would reveal the machine's user name.
3. Email addresses: only placeholder domains (example.com) and noreply addresses.
4. Forbidden files: no databases, generated data, dbt build output, or local-only files.
5. Personal blocklist: strings listed in a file OUTSIDE the repo, so the list itself is never
   published. Default location: ~/.config/public-repo-scan/blocklist.txt, or set
   PUBLIC_SAFETY_BLOCKLIST. One entry per line; `#` starts a comment. A plain line matches
   case-insensitively anywhere; a line starting with `word:` matches a case-sensitive whole
   word and is reported for review instead of failing (for words that are also ordinary words).

Exit code 0 if clean, 1 if anything must be fixed. Review-level findings print but do not fail.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ALLOWED_EMAIL = re.compile(
    r"(@users\.noreply\.github\.com|@noreply\.github\.com|noreply@anthropic\.com"
    r"|@example\.com|@test\.example\.com)$",
    re.IGNORECASE,
)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
LOCAL_PATH = re.compile(
    # The user name must start with a letter or digit, so placeholders such as <name> pass.
    r"([A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9]|/c/Users/[A-Za-z0-9]|/home/[A-Za-z0-9]|/Users/[A-Za-z0-9])"
)
FORBIDDEN_FILES = re.compile(
    r"(\.duckdb(\.wal)?$|\.parquet$|^target/|^target_|^logs/|^logs_|^dbt_packages/"
    r"|(^|/)\.user\.yml$|(^|/)CLAUDE\.local\.md$|(^|/)\.env$|^data/generated/)"
)
DEFAULT_BLOCKLIST = Path.home() / ".config" / "public-repo-scan" / "blocklist.txt"


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args], capture_output=True, text=True, encoding="utf-8", errors="replace", check=True
    )
    return result.stdout


def load_blocklist() -> tuple[list[str], list[str]]:
    path = Path(os.environ.get("PUBLIC_SAFETY_BLOCKLIST", DEFAULT_BLOCKLIST))
    if not path.exists():
        print(f"WARNING: no blocklist at {path.name} in the configured folder; personal check skipped")
        return [], []
    deny, review = [], []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("word:"):
            review.append(line[len("word:"):].strip())
        else:
            deny.append(line)
    return deny, review


def main() -> int:
    errors: list[str] = []
    reviews: list[str] = []
    deny, review_words = load_blocklist()
    review_res = [re.compile(rf"\b{re.escape(w)}\b") for w in review_words]

    def scan_text(where: str, text: str) -> None:
        lowered = text.lower()
        for entry in deny:
            if entry.lower() in lowered:
                errors.append(f"{where}: blocklisted string (entry #{deny.index(entry) + 1})")
        for i, rx in enumerate(review_res):
            if rx.search(text):
                reviews.append(f"{where}: review word (entry word #{i + 1})")
        for m in LOCAL_PATH.finditer(text):
            errors.append(f"{where}: local path {m.group(0)[:12]}...")
        for m in EMAIL.finditer(text):
            if not ALLOWED_EMAIL.search(m.group(0)):
                errors.append(f"{where}: email address with domain {m.group(0).split('@')[1]}")

    # 1. Identities in every commit.
    for line in git("log", "--all", "--format=%H%x09%ae%x09%ce").splitlines():
        sha, author, committer = line.split("\t")
        for role, email in (("author", author), ("committer", committer)):
            if not ALLOWED_EMAIL.search(email):
                errors.append(f"commit {sha[:8]}: {role} email is not a noreply address")

    # 2-5 over commit messages.
    for block in git("log", "--all", "--format=%H%x00%B%x1e").split("\x1e"):
        if "\x00" in block:
            sha, message = block.strip("\n").split("\x00", 1)
            scan_text(f"commit {sha[:8]} message", message)

    # 4. Forbidden files anywhere in history, and 2/3/5 over every file version in history.
    seen_blobs: set[str] = set()
    for sha in git("rev-list", "--all").split():
        for entry in git("ls-tree", "-r", sha).splitlines():
            meta, path = entry.split("\t", 1)
            blob = meta.split()[2]
            if FORBIDDEN_FILES.search(path):
                errors.append(f"commit {sha[:8]}: forbidden file {path}")
            if blob in seen_blobs:
                continue
            seen_blobs.add(blob)
            content = subprocess.run(["git", "cat-file", "-p", blob], capture_output=True).stdout
            if b"\x00" in content[:8000]:
                continue  # binary
            scan_text(f"{path} (blob {blob[:8]})", content.decode("utf-8", errors="replace"))

    # Untracked-but-not-ignored files would be committed by a careless `git add -A`.
    for path in git("ls-files", "--others", "--exclude-standard").splitlines():
        if FORBIDDEN_FILES.search(path):
            errors.append(f"untracked file not ignored: {path}")

    for r in sorted(set(reviews)):
        print(f"REVIEW  {r}")
    for e in sorted(set(errors)):
        print(f"ERROR   {e}")
    print(f"{len(set(errors))} error(s), {len(set(reviews))} item(s) to review, "
          f"{len(seen_blobs)} file versions scanned")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
