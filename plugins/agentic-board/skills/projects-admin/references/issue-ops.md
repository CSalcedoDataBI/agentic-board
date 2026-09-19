# issue-ops — Issue, Label, and Board-Item Recipes

Concrete commands for creating issues, managing labels, adding items to a board, and creating native sub-issues. All commands assume `$env:GH_TOKEN` has been set via the `gh-account` skill (Step 0 in SKILL.md).

**Hard rule:** all issues MUST be created in the `origin` owner/repo only. Resolve it first:

```bash
# Run inside the repo working directory
origin=$(gh repo view --json nameWithOwner -q .nameWithOwner)
# e.g. "CSalcedoDataBI/agentic-board"
```

---

## Ensure a label exists (idempotent)

`--force` is the key flag: it creates the label if absent, or silently succeeds if it already exists. Use this pattern before any `gh issue create` that references a label.

```bash
gh label create board --color 0E8A16 --repo <owner>/<repo> --force
```

---

## Create an issue in the origin repo

```bash
gh issue create \
  --repo <owner>/<repo> \
  --title "<title>" \
  --label board \
  --body "<body>"
```

- Replace `<owner>/<repo>` with the value resolved from `gh repo view` above.
- The body may contain Markdown and full GitHub URLs (see URL rule below).
- Returns the new issue URL (e.g. `https://github.com/CSalcedoDataBI/agentic-board/issues/12`).

---

## Add an existing issue or PR to a board

```bash
gh project item-add <num> --owner <owner> --url <issueUrl>
```

`<issueUrl>` is the full URL returned by `gh issue create` or a PR URL. After adding, verify with `gh project item-list <num> --owner <owner> --format json`.

---

## Native sub-issues via the GitHub MCP

`gh` CLI has no stable sub-issue command. Use the `github-business` MCP tool `sub_issue_write` with `method: add` instead.

### Get the child issue's REST ID (not its number)

The MCP requires the child's REST numeric ID, which differs from the issue number:

```bash
gh api repos/<owner>/<repo>/issues/<child_issue_number> --jq .id
# Returns an integer like 2987654321
```

### Add the sub-issue via MCP

```json
{
  "tool": "sub_issue_write",
  "method": "add",
  "owner": "<owner>",
  "repo": "<repo>",
  "issue_number": <parent_issue_number>,
  "sub_issue_id": <child_rest_id>
}
```

`issue_number` is the parent's issue number (e.g. 10); `sub_issue_id` is the child's REST `.id` integer retrieved above.

---

## Native blocked-by dependencies (`Board-Depend.ps1`, #521)

`/board work -Start` reads native blocked-by links and refuses an issue that still has open
blockers. To WRITE them, use the script - never the raw endpoint:

```powershell
& "<plugin-root>/scripts/Board-Depend.ps1" -Issue 40 -BlockedBy 36,37,38          # 40 waits for 36, 37, 38
& "<plugin-root>/scripts/Board-Depend.ps1" -Issue 40 -BlockedBy 36 -DryRun         # resolve + validate, write nothing
```

Why not `gh api .../dependencies/blocked_by --input {"issue_id": N}`: `issue_id` is the issue's
**database id**, not its number. A number does not fail - it links whatever issue anywhere on
GitHub has that database id (`{"issue_id": 17}` linked `jbarnette/johnson#3`). The script resolves
number -> id first, refuses any blocker outside the target repo (`owner/repo#N` of another repo,
foreign URLs), reads the list before and after, and exits 1 if the requested blocker did not appear
with the right number and repository or if anything unrequested did. Re-running is safe (an existing
link is reported as `already`). It is not yet called from `/board plan`.

---

## URL rule for issue bodies and board descriptions

Any file or resource link placed in an issue body, project description, or comment MUST be a full remote URL in this form:

```
https://github.com/<owner>/<repo>/blob/<branch>/<path/to/file>
```

Examples of what NOT to use:
- `../../skills/gh-account/SKILL.md` — relative path, renders broken on GitHub
- `/skills/gh-account/SKILL.md` — absolute local path, meaningless on GitHub

The file must be pushed to the remote before you link to it. A link to an unpushed file is as broken as a relative path.

---

## Move an item's Status field

Defer to the single-select set recipe in `board-ops.md` (the four-step flow: get project node ID → get field + option IDs → get item ID → `gh project item-edit`). There is no shortcut command for moving a card by status name alone.

---

## Bulk operations (move / close / label)

For any bulk operation, always show a dry-run list of affected items and wait for explicit user confirmation before mutating. See the Safety section in SKILL.md.

```bash
# Example: list open issues with label "board" before bulk-closing
gh issue list --repo <owner>/<repo> --state open --label board --json number,title

# After confirmation — close them
gh issue list --repo <owner>/<repo> --state open --label board --json number \
  | jq -r '.[].number' \
  | xargs -I{} gh issue close {} --repo <owner>/<repo>
```
