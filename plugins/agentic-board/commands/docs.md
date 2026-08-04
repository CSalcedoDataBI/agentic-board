---
description: Publish all wiki pages (product docs + knowledge registry) in a single push; or check DeepWiki indexing status for this repo.
---

# /docs

Route the request to the docs publisher.

- `wiki` → run `Publish-DocsWiki.ps1` to publish all wiki pages in one clone → commit → push.
- `deepwiki` → run `Get-DeepWikiStatus.ps1` to report DeepWiki indexing status for this repo.
- no argument → show this menu.

## What gets published

`/docs wiki` generates and pushes every wiki page in one operation:

**Product docs** (always):
- `Docs-Home` — from `README.md` (HTML stripped)
- `Docs-Command-<X>` — one page per `commands/*.md` file (frontmatter stripped)

**Knowledge registry** (when `knowledge/registry.json` exists):
- `Home` — index of domains and reference counts
- `Knowledge-<Domain>` — one page per domain in the registry

**Navigation** (always):
- `_Sidebar` — links to all product docs pages + all knowledge domain pages
- `_Footer` — "generated from the repository" notice

All pages carry a `<!-- GENERATED -->` marker. Never edit the wiki directly — changes will be
overwritten on the next publish. Source of truth stays in the repo.

## Prerequisites

The wiki must be initialized before the first publish. If you see an error, follow the
steps it prints to create the first page via the GitHub web UI, then re-run.

`/knowledge wiki` is a deprecated alias for `/docs wiki` — it delegates here.

## `/docs deepwiki`

Reports whether [DeepWiki](https://deepwiki.com) has indexed this repository.

**PUBLIC REPOS ONLY.** DeepWiki indexes only public GitHub repositories. Private repos require a
paid Devin subscription — the command reports this clearly and exits cleanly; it never appears
broken for private repos.

DeepWiki generates AI-written wikis (architecture overview, module docs, diagrams) from the
code — a different artifact from the product manual published by `/docs wiki`. It documents
*how the code works* for developers, not how the commands are used.

Run `Get-DeepWikiStatus.ps1` to get the structured result. The script:
1. Resolves the repo from `git remote origin` (or from `-Repo owner/name`).
2. Calls `gh api repos/{owner}/{name}` to check visibility.
3. For private repos → reports `private` status with a note about Devin.
4. For public repos → probes `https://deepwiki.com/{owner}/{name}` and classifies as
   `indexed`, `not-indexed`, or `unknown` (network error / timeout).

If the DeepWiki MCP server is installed (`deepwiki-mcp` from `/tools`), prefer calling
`ask_question` or `read_wiki_structure` directly over HTTP probing — the MCP answer is
authoritative. Use `Get-DeepWikiStatus.ps1 -Json` to get the URL to pass to the MCP tools.
