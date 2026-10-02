---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:agentic-board:)?(projects-admin|board|gh-account)"'
min: 0
max: 0
---
A GitHub request that is not about a Projects board must not load the board skills.
