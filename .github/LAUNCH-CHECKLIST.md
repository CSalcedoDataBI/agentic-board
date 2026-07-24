# Launch & distribution checklist

A practical, honest checklist for putting **agentic-board** in front of people. Order matters:
get the repo launch-ready first, then share — a good landing page converts a click into a star.

## The angle (lead with this everywhere)

- **One line:** *Run coding agents off your **real GitHub Projects board** — a quota-aware,
  review-gated coordinator, not another local Kanban.*
- **Proof, not claims:** it **governs its own roadmap board** (see `SHOWCASE.md`) — every fix was
  found while using it and shipped through its own PR + review gate. Dogfooding is the story.
- **Differentiators to name:** your real board (not a throwaway Kanban), a quota-aware multi-CLI
  fleet (Claude/Gemini/Codex/…), and review-gated merges.

## Pre-launch readiness

- [x] README above-the-fold: what / for whom / real example / differentiation (#209)
- [x] One-line value prop in README, plugin.json, marketplace.json (#208)
- [x] Repo description + 12 topics set (#212)
- [x] CONTRIBUTING.md + issue/PR templates + `good first issue` label (#211)
- [x] CI green + review gate on every PR (#201)
- [x] LICENSE (MIT)
- [ ] **Social-preview image uploaded** — Settings → Social preview → upload `.github/assets/social-preview.png` (manual, #212)
- [x] **Demo GIF / asciinema** of a real `/board work` run in the README (#210) — `board-install.gif` + `board-loop.gif` in README
- [ ] 2–3 issues tagged `good first issue` for first-time contributors
- [ ] Cut a tagged release with notes generated from Done issues (`/board changelog`)
- [ ] Pin the repo on the profile; add it to the profile README

## Channels (in rough priority)

### GitHub-native
- [ ] Release with a clear changelog; announce in **Discussions** if enabled.
- [ ] Submit to **awesome lists**: `awesome-claude-code`, `awesome-agentic` / agent-orchestration
  lists — open a PR adding one line with the value prop. High-intent, long-lived traffic.

### Communities (match the room; read each community's self-promotion rules first)
- [ ] **Anthropic / Claude Code Discord** — the most on-target audience; share in the
  plugins/show-and-tell channel with the SHOWCASE link.
- [ ] **Reddit** — r/ClaudeAI (best fit), r/ChatGPTCoding, r/devtools. Lead with the problem, not
  the repo. Avoid r/programming unless the post is genuinely story-first.
- [ ] **Hacker News — Show HN.** Title: `Show HN: agentic-board – run coding agents off your real
  GitHub Projects board`. Post Tue–Thu ~8–10am ET. Write the first comment yourself: the itch, the
  dogfooding loop, what's honestly out of scope. Be around to answer for the first 2–3 hours.

### Written / long-form (highest-leverage, reusable)
- [ ] **Blog / Dev.to article** — the dogfooding narrative: "I let an agent run my roadmap board,
  and it shipped its own features." Link back to the repo; cross-post to the communities above.
- [ ] **LinkedIn / X** — short version of the article + the demo GIF. Tailor the LinkedIn post to
  the data/BI audience (BI GitOps is the roadmap), the X post to the coding-agent crowd.

### Optional
- [ ] **Product Hunt** — only with the demo GIF + a few screenshots ready; needs same-day presence.

## Launch day

- [ ] Everything above green (esp. social preview + demo GIF — they carry the first impression).
- [ ] Post to 1–2 channels first, watch for confusion, fix the README wording, then widen.
- [ ] Respond fast to every question the first day; log recurring ones as issues or README FAQ.

## After

- [ ] Turn the best questions into docs / good-first-issues.
- [ ] Note what landed (which channel drove stars/installs) for the next module launch.
