---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:agentic-board:)?(project-scan|board-expert)"'
min: 0
max: 0
---
project-scan and board-expert are disable-model-invocation engines: plain language must never load them through the Skill tool.
