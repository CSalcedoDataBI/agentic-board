# /cleanup sessions — close every session of this repo and leave nothing dangling (full recipe)

Loaded on demand by /cleanup (#734). Formerly `/board close-cycle --all`.


For when the sidebar is full of old sessions and nobody remembers which one still holds work. It runs
`scripts/Cleanup-Sessions.ps1`, which reuses the `/board doctor` inventory. For each local branch
it chooses **one** disposition, and then decides which host-app sessions may be archived.

**Recipe (follow in order):**

1. **Read the host's sessions.** Call the app's session-list tool (`list_sessions`, `limit` 200, not
   archived). A long list comes back saved to a file; use that file. A short one: write the JSON array
   to a scratch file. Without a host app (plain terminal), skip `-HostSessionsFile`: only the git side
   is planned.
2. **Plan (writes nothing):** `Cleanup-Sessions.ps1 -HostSessionsFile <file> -Json`, run from the
   repo to clean. **The scope defaults to `repo`**: only this repo's branches and the sessions that live in
   it (its root, its worktrees, and its worktrees that are gone). It never reaches into another repo or
   another session's work, so every repo is cleaned from inside itself.
   - `-Scope orphans`: only the sessions no existing repo owns (folder gone, or outside any repo). No
     branch is touched. Run it once from anywhere.
   - `-Scope all [-Root <folder>]`: the machine-wide sweep over every repo a session lives in. Use it
     only when the user asks for exactly that.
   - Show the user:
     - the counts per action
     - the `needs-decision` rows by name with their reason
     - how many sessions will be archived and how many kept, with the reasons grouped
3. **One confirmation**, in plain words: what gets deleted (proven-merged and empty branches), what
   gets pushed as a draft PR, and how many sessions get archived. Nothing runs without a yes.
4. **Execute:** the same call with `-Force -Json`. A step that fails turns its branch back into "not
   resolved", so its session lands in `keep`, never in `archive`.
5. **Archive** every entry of `archive` with the app's archive-session tool (`reason` = the entry's
   reason).
   - Never archive `self`.
   - Never archive an entry from `keep`.
   - The app may ask per session.
6. **Report:** what was done, the parked PRs (the default branch now knows about them; `/board work`
   resumes them), and the `keep` list with the reason for each.

**Branch dispositions:**

| Action | When | What it does |
|---|---|---|
| `teardown` | PR merged at the branch tip | Deletes the branch and worktree through `Board-Doctor -Fix -Auto` (its dirty and current-worktree guards apply) |
| `park` | commits with no PR, or commits after a merge | `git push` + DRAFT PR labelled `parked`. The body says `Refs #n` (never a closing keyword) and links the session |
| `wip-park` | uncommitted changes | Commits them as `wip: parked by close-cycle --all` (hooks run), then parks |
| `keep-review` | PR open, everything pushed | Nothing; the PR already makes it visible. Commits the PR does not have yet are pushed first (as `park`), because archiving removes the worktree |
| `delete-empty` | clean branch with no commits | Deletes it; there is no work to lose |
| `needs-decision` | PR closed unmerged, unreadable state, or parking in **another account's** repo | Nothing; reported with the reason |
| `skip-open` | a session is still working on it | Nothing |

**Session archive rule:** a session is archived only when the work behind it is resolved:
- its branch was torn down, parked or is in review; or
- its folder no longer exists; or
- it has no branch of its own (repo root, or outside any repo) and has been idle for `-IdleDays`
  (default 7).

A session is always kept when:
- it is running;
- it is pinned;
- its branch needs a decision;
- or its repo was not scanned (e.g. the token cannot read it). A skipped repo is never counted as
  "scanned with nothing pending".

**Identity guard:** parking publishes (a push and a PR), so it only happens in repos of `-Owner`,
which defaults to the token's login. In a client or business repo that the personal token can read,
only the local cleanup runs.

Nothing is deleted in this pass: archiving is reversible, and the transcripts stay on disk.
Compressing old transcripts is `#736`.
