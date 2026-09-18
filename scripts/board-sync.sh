#!/usr/bin/env bash
# board-sync.sh — Auto-fill all gaps in a GitHub Projects v2 board.
# Runs on: issue events, PR events, weekly schedule, manual dispatch.
# Requires: GH_TOKEN = classic PAT (PROJECTS_TOKEN secret) with minimal scopes:
#   - 'project'      → read/write the user-owned Project v2 (issues assign + Status field)
#   - 'public_repo'  → write to this PUBLIC repo's issues (do NOT use full 'repo')
# Fine-grained PATs can't manage user-owned Projects v2, so a classic PAT is required.
# 'public_repo' (not 'repo') keeps private repos out of the blast radius if the secret leaks.
# If this ever syncs a PRIVATE repo, swap 'public_repo' for full 'repo' — but never store
# such a token as a secret in a public repo.
set -euo pipefail

OWNER="${REPO_OWNER:-CSalcedoDataBI}"
REPO="${REPO_NAME:-agentic-board}"
PROJECT_NUM="${PROJECT_NUMBER:-13}"

echo "=== board-sync: $OWNER/$REPO project #$PROJECT_NUM ==="

# ── 1. Resolve project & field IDs ────────────────────────────────────────────
PROJECT=$(gh api graphql -f query='
query($owner:String!, $num:Int!) {
  user(login:$owner) {
    projectV2(number:$num) {
      id
      fields(first:30) {
        nodes {
          ... on ProjectV2SingleSelectField { id name options { id name } }
          ... on ProjectV2Field             { id name }
          ... on ProjectV2IterationField    { id name }
        }
      }
    }
  }
}' -F owner="$OWNER" -F num="$PROJECT_NUM")

PROJECT_ID=$(echo "$PROJECT" | jq -r '.data.user.projectV2.id')
STATUS_ID=$(echo "$PROJECT"  | jq -r '.data.user.projectV2.fields.nodes[] | select(.name=="Status") | .id')
DONE_OPT=$(echo "$PROJECT"   | jq -r '.data.user.projectV2.fields.nodes[] | select(.name=="Status") | .options[] | select(.name=="Done") | .id')
INPROG_OPT=$(echo "$PROJECT" | jq -r '.data.user.projectV2.fields.nodes[] | select(.name=="Status") | .options[] | select(.name=="In Progress") | .id')
TODO_OPT=$(echo "$PROJECT"   | jq -r '.data.user.projectV2.fields.nodes[] | select(.name=="Status") | .options[] | select(.name=="Todo") | .id')
# Boards use either name for the not-started option (the plugin's own presets ship 'Backlog'). Without
# this fallback the comparison further down is against an empty id and an issue with an open PR is
# never moved to In Progress (#679).
if [ -z "$TODO_OPT" ]; then
  TODO_OPT=$(echo "$PROJECT" | jq -r '.data.user.projectV2.fields.nodes[] | select(.name=="Status") | .options[] | select(.name=="Backlog") | .id')
fi

echo "Project ID : $PROJECT_ID"
echo "Status field: $STATUS_ID  (Done=$DONE_OPT  InProg=$INPROG_OPT  Todo=$TODO_OPT)"

# ── 2. Load all project items (small pages, retried) ──────────────────────────
# One items(first:100) query with three nested connections (fieldValues, assignees, timelineItems)
# began failing in CI on 2026-09-07 with a bare "Something went wrong while executing your query"
# and no cause (#679). Small pages keep each query cheap, a retry rides out a transient server-side
# failure, and a persistent failure now says WHICH part of the query breaks instead of a bare exit 1.
BACKOFF="${BOARD_SYNC_BACKOFF:-5}"
ERR_FILE="$(mktemp)"

ITEM_FIELDS_HEAD='
        nodes {
          id
          fieldValues(first:20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2SingleSelectField { name } } optionId }
            }
          }
          content {
            ... on Issue {
              number state'
ITEM_ASSIGNEES='assignees(first:5) { nodes { login } }'
ITEM_TIMELINE='timelineItems(first:20 itemTypes:[CROSS_REFERENCED_EVENT]) {
                nodes {
                  ... on CrossReferencedEvent {
                    willCloseTarget
                    source {
                      ... on PullRequest { number state merged }
                    }
                  }
                }
              }'
ITEM_TAIL='
            }
          }
        }'

# $1 = assignees fragment, $2 = timeline fragment, $3 = cursor ("" for the first page)
items_query() {
  printf '%s' "
query(\$proj:ID!, \$cursor:String) {
  node(id:\$proj) {
    ... on ProjectV2 {
      items(first:25, after:\$cursor) {
        pageInfo { hasNextPage endCursor }
${ITEM_FIELDS_HEAD} $1 $2 ${ITEM_TAIL}
      }
    }
  }
}"
}

# One page, up to 3 attempts. The cursor goes in as a variable, never spliced into the query text.
fetch_items_page() {
  local cursor="$1" attempt=1 out
  while [ "$attempt" -le 3 ]; do
    if [ -n "$cursor" ]; then
      out=$(gh api graphql -f query="$(items_query "$ITEM_ASSIGNEES" "$ITEM_TIMELINE")" -F proj="$PROJECT_ID" -F cursor="$cursor" 2>"$ERR_FILE") && { printf '%s' "$out"; return 0; }
    else
      out=$(gh api graphql -f query="$(items_query "$ITEM_ASSIGNEES" "$ITEM_TIMELINE")" -F proj="$PROJECT_ID" 2>"$ERR_FILE") && { printf '%s' "$out"; return 0; }
    fi
    echo "  items query failed (attempt $attempt/3): $(head -c 300 "$ERR_FILE")" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * BACKOFF))
    attempt=$((attempt + 1))
  done
  return 1
}

# The query kept failing: say which selection is the culprit, so the next step is a fix, not a guess.
diagnose_items_failure() {
  echo "::error::board-sync: the items query failed 3 times. Diagnosing which part breaks (gh $(gh --version | head -1))" >&2
  local label assignees timeline
  for variant in "full|$ITEM_ASSIGNEES|$ITEM_TIMELINE" "without timelineItems|$ITEM_ASSIGNEES|" "without assignees||$ITEM_TIMELINE" "without both||"; do
    label="${variant%%|*}"; rest="${variant#*|}"; assignees="${rest%%|*}"; timeline="${rest#*|}"
    if gh api graphql -f query="$(items_query "$assignees" "$timeline")" -F proj="$PROJECT_ID" >/dev/null 2>&1; then
      echo "  variant '$label': OK" >&2
    else
      echo "  variant '$label': FAILS" >&2
    fi
  done
}

ITEM_NODES='[]'
CURSOR=""
PAGES=0
while :; do
  PAGE=$(fetch_items_page "$CURSOR") || { diagnose_items_failure; exit 1; }
  ITEM_NODES=$(jq -c --argjson page "$(printf '%s' "$PAGE" | jq -c '.data.node.items.nodes')" '. + $page' <<<"$ITEM_NODES")
  PAGES=$((PAGES + 1))
  [ "$(printf '%s' "$PAGE" | jq -r '.data.node.items.pageInfo.hasNextPage')" = "true" ] || break
  CURSOR=$(printf '%s' "$PAGE" | jq -r '.data.node.items.pageInfo.endCursor')
  if [ -z "$CURSOR" ] || [ "$CURSOR" = "null" ] || [ "$PAGES" -ge 40 ]; then
    echo "::error::board-sync: pagination did not terminate (cursor='$CURSOR', pages=$PAGES)" >&2
    exit 1
  fi
done

ITEM_COUNT=$(printf '%s' "$ITEM_NODES" | jq 'length')
echo "Items found: $ITEM_COUNT  ($PAGES page(s))"

# ── 3. Process each item ───────────────────────────────────────────────────────
set_status() {
  local item_id="$1" opt_id="$2"
  gh api graphql -f query='
mutation($proj:ID!,$item:ID!,$field:ID!,$opt:String!) {
  updateProjectV2ItemFieldValue(input:{
    projectId:$proj, itemId:$item, fieldId:$field,
    value:{singleSelectOptionId:$opt}
  }) { projectV2Item { id } }
}' -F proj="$PROJECT_ID" -F item="$item_id" -F field="$STATUS_ID" -F opt="$opt_id" > /dev/null
}

assign_issue() {
  local issue_num="$1"
  gh api repos/"$OWNER"/"$REPO"/issues/"$issue_num"/assignees \
    -X POST -F "assignees[]=$OWNER" > /dev/null 2>&1 || true
}

printf '%s
' "$ITEM_NODES" | jq -c '.[]' | while read -r item; do
  ITEM_ID=$(echo "$item" | jq -r '.id')
  ISSUE_NUM=$(echo "$item" | jq -r '.content.number // empty')

  # Skip non-issue items (draft notes)
  [ -z "$ISSUE_NUM" ] && continue

  ISSUE_STATE=$(echo "$item" | jq -r '.content.state')
  ASSIGNEE_COUNT=$(echo "$item" | jq '.content.assignees.nodes | length')
  CURRENT_STATUS=$(echo "$item" | jq -r '
    .fieldValues.nodes[] |
    select(.field.name == "Status") |
    .optionId // empty' | head -1)

  # Count linked PRs by state — CLOSING references only (willCloseTarget). A textual "#<n>"
  # mention in a PR body is also a cross-reference; counting it falsely marks issues Done and
  # the board's "Done -> close issue" workflow then closes them for real (issue #48).
  MERGED_PRS=$(echo "$item" | jq '[.content.timelineItems.nodes[] | select(.willCloseTarget == true) | .source | select(.merged == true)] | length')
  OPEN_PRS=$(echo "$item"   | jq '[.content.timelineItems.nodes[] | select(.willCloseTarget == true) | .source | select(.state == "OPEN")] | length')

  echo "--- Issue #$ISSUE_NUM  state=$ISSUE_STATE  assignees=$ASSIGNEE_COUNT  merged_prs=$MERGED_PRS  open_prs=$OPEN_PRS  status=$CURRENT_STATUS"

  # ── Auto-assign if empty ─────────────────────────────────────────────────
  if [ "$ASSIGNEE_COUNT" -eq 0 ]; then
    echo "  → assigning $OWNER"
    assign_issue "$ISSUE_NUM"
  fi

  # ── Sync Status ───────────────────────────────────────────────────────────
  if [ "$ISSUE_STATE" = "CLOSED" ] && [ "$CURRENT_STATUS" != "$DONE_OPT" ]; then
    echo "  → Status: Done (issue closed)"
    set_status "$ITEM_ID" "$DONE_OPT"
  elif [ "$MERGED_PRS" -gt 0 ] && [ "$CURRENT_STATUS" != "$DONE_OPT" ]; then
    echo "  → Status: Done (PR merged)"
    set_status "$ITEM_ID" "$DONE_OPT"
  elif [ "$OPEN_PRS" -gt 0 ] && [ "$CURRENT_STATUS" = "$TODO_OPT" ]; then
    echo "  → Status: In Progress (open PR)"
    set_status "$ITEM_ID" "$INPROG_OPT"
  fi
done

echo "=== board-sync complete ==="
