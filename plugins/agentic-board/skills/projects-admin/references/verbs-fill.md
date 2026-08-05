# /board fill — detect and fill board gaps (full recipe)

Loaded on demand by /board (#573).

- **fill** — detect and fill ALL gaps across the board by running `scripts/Board-Fill.ps1`
  (pass -Owner, -Repo, -ProjectNum for the current repo's board):
  - The script converts any draft notes to REAL issues in the repo first, then fills gaps:
    Assignees (owner), Status (from issue/PR state), Priority (P2 Medium), Size (M),
    Type (from labels, else Feature).
  - No flags: run with neither -DryRun nor -Auto — the script prints the plan and asks (s/n).
  - `--dry-run`: run with -DryRun — plan only, executes nothing.
  - `--auto`: run with -Auto — fills everything without asking. Use for CI or when already approved.
  - NOTE: Linked PRs and Sub-issues progress are system-derived columns — GitHub sets them
    automatically from PR mentions and sub-issue state. They are NOT writable via API; do not
    attempt to fill them and explain this to the user if asked.
  - NOTE: which columns a VIEW displays is UI-only — if fields look "empty" on the board page,
    tell the user to click `+` at the right of the view header and enable Priority/Size/Type.

Scans the board for missing values (assignees, Status) and fills them. In CI it runs `scripts/board-sync.sh`; in interactive sessions it runs the PowerShell sequence below.

| Variant | Behavior |
|---------|----------|
| `/board fill` | Shows a full plan and asks for confirmation before acting |
| `/board fill --dry-run` | Prints what would change, executes nothing |
| `/board fill --auto` | Fills without asking — for CI or when the user has already approved |

### What gets filled

| Column | Fill rule |
|--------|-----------|
| **Assignees** | If empty, assign the board owner (`$OWNER`) |
| **Status** | Issue closed → `Done`; PR merged → `Done`; open PR → `In Review`; else → `Backlog` |
| **Linked PRs** | System-derived by GitHub from PR mentions — not writable via API |
| **Sub-issues progress** | System-derived from closed sub-issues — not writable via API |

### Interactive mode (Claude Code session)

```powershell
# 1. Load token
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL', 'User'); $env:GH_TOKEN = $t

# 2. Read all board items via GraphQL
$proj = gh api graphql -f query='
query($owner:String!, $num:Int!) {
  user(login:$owner) {
    projectV2(number:$num) {
      id
      items(first:100) {
        nodes {
          id
          fieldValues(first:20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2SingleSelectField { name } } optionId }
            }
          }
          content {
            ... on Issue { number state title assignees(first:5) { nodes { login } } }
          }
        }
      }
      fields(first:30) {
        nodes { ... on ProjectV2SingleSelectField { id name options { id name } } }
      }
    }
  }
}' -F owner=<owner> -F num=<project-num>

# 3. Detect gaps — items missing assignee or Status
# 4. --dry-run: print plan
# 5. --auto or after confirmation: execute
#    a) Empty assignee
gh issue edit <issue-num> --repo <owner>/<repo> --add-assignee <owner>
#    b) Wrong / missing Status
gh api graphql -f query='mutation(...) { updateProjectV2ItemFieldValue(...) { projectV2Item { id } } }' ...
```

### CI mode (GitHub Actions)

The workflow `.github/workflows/board-sync.yml` runs `bash scripts/board-sync.sh` automatically on every issue or PR event. This is equivalent to `/board fill --auto` with no manual intervention.

Triggers already configured:
```yaml
on:
  issues:    [opened, closed, reopened, assigned]
  pull_request: [opened, closed]
  schedule:  # Monday 9am UTC — weekly health check
  workflow_dispatch:
```
