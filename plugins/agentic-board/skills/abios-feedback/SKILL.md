---
name: abios-feedback
description: Use when, while working in ANY project (especially a PRIVATE one), you notice a bug or improvement for the agentic-board tool itself. Captures it as a SANITIZED issue on the tool's OWN public repo/board — never touching the current project and never leaking private data. Triggers — "mejora para la herramienta", "esto es una mejora para agentic-board", "abios bug", "esto deberíamos arreglarlo en el plugin", a guard block, a recurring gh/board failure.
user-invocable: false
---

# abios-feedback — improvements flow back, private data never leaks

## How to invoke
Say it in natural language while in any repo: *"esto es una mejora para agentic-board"*,
*"abios bug: …"*, or *"arréglalo en el plugin"*. The agent then runs the flow below. (Once the
plugin is installed you can also reach it via the `/board` command for the board part.)

## The principle
The cause may be in a private project; the captured improvement must be **public-only** and must
land on the **tool's own** repo — not the project you are currently in.

## Anti-confusion rules (so it never targets the wrong project)
These are absolute:
1. **Target is a CONSTANT, not the current repo.** Always operate on `CSalcedoDataBI/agentic-board`.
   **NEVER** resolve the target with `gh repo view` of the working directory — that would be the
   private project you are standing in. Pass `--repo CSalcedoDataBI/agentic-board` explicitly.
2. **Identity is the personal account**, via [[gh-account]] (`GITHUB_TOKEN_PERSONAL`), **even if the
   current project is a PAL-Devs repo**. The tool's repo is personal.
3. **Do NOT git add / commit / write files in the current project** for this. Capture goes to the
   tool's repo only (an issue), never the cwd repo tree.
4. **Sanitize first** (next section). The guard in the tool's repo is the backstop, not the cwd.
5. **Write the issue in ENGLISH — title AND body — even when the conversation is in Spanish.**
   The language follows the **target repo, not the chat**: this repo is English-only, and the target
   is always this repo (rule 1), so the answer here is always English. Keep talking to the user in
   their language; only the issue text is English. Do **not** generalise this rule — `/scan` and
   `/board plan` target the user's OWN repo and may legitimately be Spanish there.

## Step 1 — Abstract / sanitize
Describe ONLY the public tool — which skill/script/recipe is wrong and the correct behavior. Strip:
- ❌ private repo names, client/customer names, data values, row counts
- ❌ Fabric/Power BI workspace or model GUIDs, OneLake paths, local file paths
- ❌ secrets/tokens, internal URLs, screenshots of private data
- ✅ the public file (`skills/…`, `scripts/…`, `references/…`), the wrong command/flag, the right
  one, and a generic repro (e.g. "on any repo, `gh project delete` has no `--yes`").

## Step 2a — Search first: is this defect already filed? (#675)
The same defect was filed three times in a row (#654, #658, #667) and once as a month-old duplicate
(#661). Before creating anything, run the duplicate check on the **sanitized** title and body:
```bash
pwsh -NoProfile -File "<plugin-root>/scripts/Find-DuplicateIssue.ps1" -Title "<sanitized title>" -Body "<sanitized body>"
```
It searches the tool's open issues plus those closed in the last 30 days (a recently closed twin is a
recurrence, not a new defect) and acts on its exit code:
- **exit 3 — probable duplicate.** Do **not** file. Show the user the listed issues; if it is the
  same defect, add the new evidence (sanitized) as a comment on the existing one — or reopen it when it
  was closed — after the user agrees. Only file a new issue if the user says it is genuinely different.
- **exit 0 — nothing likely.** Go on to step 2. Issues listed as `relacionado` are worth a glance:
  same script, different symptom.
- **exit 2 — the search could not run.** That is **not** "no duplicates". Tell the user the check was
  unavailable and ask before filing.

## Step 2 — Capture as a sanitized issue on the tool's own board (PRIMARY, path-independent)
```bash
tok=$(powershell.exe -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL','User')" | tr -d '\r')
GH_TOKEN=$tok gh issue create --repo CSalcedoDataBI/agentic-board \
  --label tool-improvement --title "<sanitized title>" --body "<sanitized body>"
# add it to the tool's roadmap board (its own water):
GH_TOKEN=$tok gh project item-add 13 --owner CSalcedoDataBI --url "<issue url from above>"
```
This needs no local path and cannot hit the current project — the target is explicit.

## Step 3 — Implement the fix (only when you choose to), in the tool's clone
Do this deliberately, not from the private project tree:
```bash
cd "$env:ABIOS_HOME"   # set ABIOS_HOME once to your local agentic-board clone path
# edit skills/scripts/references, then commit — the guard runs automatically
```
If `ABIOS_HOME` is unset, ask the user for the clone path; do **not** guess or write into the cwd.
Also append a dated, sanitized note to `inbox/IMPROVEMENTS.md` in that clone (optional log).

## Safety backstops (you do not rely on discipline alone)
Two, because both of these rules have been broken by an agent who meant well:

- **Private content** — a guard (`scripts/guard-no-private.ps1`, wired pre-commit + pre-push)
  **blocks** any commit/push whose added lines contain a secret pattern or a term from the local
  `.abios/private-denylist.txt`. If it blocks you, it caught a leak — do not `--no-verify` unless you
  have confirmed a genuine false positive. Note it is inert in a fresh clone until
  `scripts/install-guard.ps1` has been run: hooks need `core.hooksPath`, and the denylist is
  gitignored so it never arrives with the clone.
- **Language** — `.github/workflows/issue-language.yml` scores every opened/edited issue and applies
  a `needs-english` label when it reads as Spanish (rule 5). It cannot block — GitHub has no
  pre-create hook for issues — so it is a net, not a gate: getting rule 5 right up front is still
  your job. The label clears itself once the text is fixed. `lang-ok` opts an issue out.

See [[gh-account]] for identity; projects-admin for board recipes.
