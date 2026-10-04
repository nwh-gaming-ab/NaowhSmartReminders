"""Release helper for .github/workflows/release.yml. From the repo root:

    python Tools/release.py prepare [--bump patch|minor|major] [--beta | --no-beta]
                                    [--version V]
    python Tools/release.py notes <tag>
    python Tools/release.py start-next

prepare: "## Unreleased" in CHANGELOG.md becomes "## <version>", and the TOC "## Version" and
ns.CODE_BUILD are set to it; prints the version. A changelog already headed "## <version>"
(written by hand) is left as it is. The version is the newest tag bumped
(patch: 1.4.27 -> 1.4.28, minor: -> 1.5.0, major: -> 2.0.0), with
"-beta" added (--beta), dropped (--no-beta) or kept as the tag has it; --version overrides
all that. Versions before 1.0.0 must be betas or alphas. Everything is checked before
any file is written, and each file keeps its line endings.

notes: the tag's CHANGELOG.md section for players, then every commit since the previous
tag, grouped by Conventional Commit type.

start-next: an empty "## Unreleased" back at the top of CHANGELOG.md after a release, so
the next pull request only adds its line. Does nothing if the heading is already there.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

TOC = "NaowhSmartReminders.toc"
CORE = "NaowhUI_SmartReminders_Core.lua"
CHANGELOG = "CHANGELOG.md"

VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.]+)?")
TYPES = "feat|fix|perf|refactor|docs|test|ci|build|chore|revert"
SUBJECT = re.compile(rf"({TYPES})(?:\(([^)]*)\))?!?: (.+)")
GROUPS = {"feat": "Features", "fix": "Fixes", "perf": "Performance"}
ORDER = ("Features", "Fixes", "Performance", "Other changes")


class ReleaseError(Exception):
    pass


def git(root, *args, check=True):
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise ReleaseError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result


def read(root, name):
    with open(Path(root) / name, encoding="utf-8", newline="") as f:
        return f.read()


def write(root, name, text):
    with open(Path(root) / name, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def tag_exists(root, tag):
    return git(root, "rev-parse", "-q", "--verify", f"refs/tags/{tag}", check=False).returncode == 0


def newest_tag(root):
    tags = [t for t in git(root, "tag", "--list").stdout.split() if VERSION.fullmatch(t)]
    if not tags:
        return None
    # 1.0.0 is newer than 1.0.0-beta.
    return max(tags, key=lambda t: (*(int(n) for n in VERSION.fullmatch(t).groups()[:3]),
                                    VERSION.fullmatch(t).group(4) is None))


def next_version(tag, bump="patch", beta=None):
    """The version after tag. beta: True adds "-beta", False drops any suffix, None keeps it."""
    major, minor, patch, suffix = VERSION.fullmatch(tag).groups()
    major, minor, patch = int(major), int(minor), int(patch)
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    if beta is not None:
        suffix = "-beta" if beta else ""
    return f"{major}.{minor}.{patch}{suffix or ''}"


def section(text, heading):
    """The lines under "## heading", up to the next "## ", or None without that heading."""
    lines = [line.rstrip() for line in text.splitlines()]
    try:
        start = lines.index(f"## {heading}") + 1
    except ValueError:
        return None
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    return lines[start:end]


def replace_line(text, pattern, replacement, missing):
    new, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise ReleaseError(missing)
    return new


def prepare(root, version=None, bump="patch", beta=None):
    if not version:
        tag = newest_tag(root)
        if not tag:
            raise ReleaseError("no version tag yet: give the version")
        version = next_version(tag, bump, beta)
    match = VERSION.fullmatch(version)
    if not match:
        raise ReleaseError(f"'{version}' is not a version like 0.5.17-beta")
    # The packager publishes a tag without "beta" or "alpha" as a full release everywhere,
    # CurseForge included; before 1.0.0 every release is a pre-release.
    suffix = (match.group(4) or "").lower()
    if match.group(1) == "0" and "beta" not in suffix and "alpha" not in suffix:
        raise ReleaseError(f"{version}: versions before 1.0.0 are pre-releases, tick Beta")
    if tag_exists(root, version):
        raise ReleaseError(f"tag {version} already exists")

    changelog = read(root, CHANGELOG)
    plain = changelog.replace("\r", "")
    first = next((line[3:].strip() for line in plain.splitlines() if line.startswith("## ")),
                 None)
    if first == "Unreleased":
        if not any(line.strip() for line in section(plain, "Unreleased")):
            raise ReleaseError(f"'## Unreleased' in {CHANGELOG} is empty: nothing to release")
        changelog = replace_line(changelog, r"^## Unreleased[ \t]*(?=\r?$)", f"## {version}",
                                 f"{CHANGELOG}: no '## Unreleased' line")
    elif first != version:
        raise ReleaseError(f"{CHANGELOG} must start with '## Unreleased' or '## {version}', "
                           f"not '## {first}'")

    toc = replace_line(read(root, TOC), r"^(## Version:[ \t]*)[^\r\n]*", rf"\g<1>{version}",
                       f"{TOC} has no '## Version' line")
    core = replace_line(read(root, CORE), r'^(ns\.CODE_BUILD = ")[^"\r\n]*(")',
                        rf"\g<1>{version}\g<2>", f"{CORE} has no ns.CODE_BUILD line")

    write(root, CHANGELOG, changelog)
    write(root, TOC, toc)
    write(root, CORE, core)
    return version


def notes(root, tag):
    player = section(read(root, CHANGELOG).replace("\r", ""), tag) or []
    while player and not player[0].strip():
        player.pop(0)
    while player and not player[-1].strip():
        player.pop()

    previous = git(root, "describe", "--tags", "--abbrev=0", f"{tag}^", check=False)
    previous = previous.stdout.strip() if previous.returncode == 0 else None
    log = git(root, "log", "--no-merges", "--format=%h%x09%s",
              f"{previous}..{tag}" if previous else tag).stdout

    grouped = {}
    for line in log.splitlines():
        commit, subject = line.split("\t", 1)
        # Release commits: "chore(release): x" from the workflow, "x" or "x (#n)" by hand.
        if subject.startswith("chore(release)") or re.fullmatch(rf"{re.escape(tag)}( \(#\d+\))?", subject):
            continue
        name, text = "Other changes", subject
        match = SUBJECT.fullmatch(subject)
        if match:
            kind, scope, summary = match.groups()
            name = GROUPS.get(kind, "Other changes")
            text = f"**{scope}:** {summary}" if scope else summary
        grouped.setdefault(name, []).append(f"- {text} ({commit})")

    out = ["## What's new", "", *player, ""]
    out += [f"## Commits since {previous}" if previous else "## Commits", ""]
    for name in ORDER:
        if name in grouped:
            out += [f"### {name}", "", *grouped[name], ""]
    return "\n".join(out)


def start_next(root):
    changelog = read(root, CHANGELOG)
    lines = changelog.replace("\r", "").splitlines()
    first = next((i for i, line in enumerate(lines) if line.startswith("## ")), None)
    if first is not None and lines[first].rstrip() == "## Unreleased":
        return False
    newline = "\r\n" if "\r\n" in changelog else "\n"
    heading = f"## Unreleased{newline}{newline}"
    if first is None:
        changelog = changelog.rstrip("\r\n") + newline + newline + heading
    else:
        changelog = re.sub(r"^## ", lambda _: heading + "## ", changelog, count=1,
                           flags=re.MULTILINE)
    write(root, CHANGELOG, changelog)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description="Release helper for the Release workflow.")
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_args = commands.add_parser("prepare")
    prepare_args.add_argument("--bump", choices=("patch", "minor", "major"), default="patch")
    prepare_args.add_argument("--beta", action=argparse.BooleanOptionalAction, default=None)
    prepare_args.add_argument("--version")
    commands.add_parser("notes").add_argument("tag")
    commands.add_parser("start-next")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            print(prepare(".", args.version, args.bump, args.beta))
        elif args.command == "notes":
            print(notes(".", args.tag))
        else:
            start_next(".")
    except ReleaseError as error:
        print(f"release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
