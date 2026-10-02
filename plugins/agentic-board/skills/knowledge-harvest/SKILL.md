---
name: knowledge-harvest
description: "Engine behind /knowledge harvest: sweep the current repo for uncatalogued research docs and links, and add the chosen ones to the knowledge registry. Triggers — \"cosecha las referencias\", \"harvest knowledge\"."
user-invocable: false
disable-model-invocation: true
---

# knowledge-harvest

Batch-capture references already scattered in the repo into `knowledge/registry.json`.

## Workflow
1. Scan for candidates (read-only, dedups against the registry):
   ```
   pwsh -File ${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-KnowledgeHarvest.ps1 -Root . -Json
   ```
2. Present the candidates grouped by kind. For each one the user wants to keep, ask which
   **domain** it belongs to (offer the registry's declared domains; `-NewDomain` to extend).
3. Add each chosen candidate via the registry engine:
   ```
   pwsh -File ${CLAUDE_PLUGIN_ROOT}/scripts/Add-KnowledgeRef.ps1 -Root . -Ref <ref> -Domain <Domain> -Title "<title>" -Note "<one line>"
   ```
4. Show the regenerated table (`Get-KnowledgeInventory.ps1`).

## When NOT to use
- A single known reference → use `knowledge-registry` (`/knowledge add`) directly.
