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

# ── 2. Load all project items (paged, retried, and salvaged item by item) ─────
# One items(first:100) query with three nested connections (fieldValues, assignees, timelineItems)
# began failing in CI on 2026-09-07 with a bare "Something went wrong while executing your query"
# and no cause (#679). Reading the board in pages of 25 showed WHY it fails as a whole: the error is
# not transient and not about the query shape - one page holds an item the CI token cannot read, and
# a single unreadable item fails the entire page. So a page that keeps failing is re-read ONE item at
# a time, an item that only fails with its linked PRs is kept without them, and an item that cannot
# be read at all is skipped with a warning that names it. One bad item no longer stops the sync.
BACKOFF="${BOARD_SYNC_BACKOFF:-5}"
ATTEMPTS="${BOARD_SYNC_ATTEMPTS:-3}"
PAGE_SIZE="${BOARD_SYNC_PAGE_SIZE:-25}"
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

# $1 = how many items, $2 = assignees fragment, $3 = timeline fragment
items_query() {
  printf '%s' "
query(\$proj:ID!, \$cursor:String) {
  node(id:\$proj) {
    ... on ProjectV2 {
      items(first:$1, after:\$cursor) {
        pageInfo { hasNextPage endCursor }
${ITEM_FIELDS_HEAD} $2 $3 ${ITEM_TAIL}
      }
    }
  }
}"
}

# Just the cursor and the item id: the last resort that lets us step past an unreadable item.
minimal_query() {
  printf '%s' "
query(\$proj:ID!, \$cursor:String) {
  node(id:\$proj) {
    ... on ProjectV2 {
      items(first:1, after:\$cursor) { pageInfo { hasNextPage endCursor } nodes { id } }
    }
  }
}"
}

# ONE place that runs a query, so every path (normal, salvage, diagnosis) sends it the same way.
# $1 = query text, $2 = cursor ("" for the first page). The cursor is a variable, never spliced into
# the query text. stderr lands in $ERR_FILE.
run_query() {
  if [ -n "$2" ]; then
    gh api graphql -f query="$1" -F proj="$PROJECT_ID" -F cursor="$2" 2>"$ERR_FILE"
  else
    gh api graphql -f query="$1" -F proj="$PROJECT_ID" 2>"$ERR_FILE"
  fi
}

# Read one page at $CURSOR, retrying a few times. Sets PAGE and returns 0, or returns 1.
read_page() {
  local attempt=1 rc started
  while [ "$attempt" -le "$ATTEMPTS" ]; do
    started=$SECONDS; rc=0
    PAGE=$(run_query "$(items_query "$PAGE_SIZE" "$ITEM_ASSIGNEES" "$ITEM_TIMELINE")" "$CURSOR") || rc=$?
    [ "$rc" -eq 0 ] && return 0
    echo "  items page failed (cursor='${CURSOR:-start}', attempt $attempt/$ATTEMPTS, $((SECONDS - started))s): $(head -c 200 "$ERR_FILE")" >&2
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep $((attempt * BACKOFF))
    attempt=$((attempt + 1))
  done
  return 1
}

# The page kept failing: read it one item at a time. Prints a page-shaped JSON document.
# Per item, in order of decreasing fidelity: full, without its linked PRs, then just enough to step
# past it. Anything below "full" is reported with ::warning:: naming the item.
salvage_page() {
  local cursor="$CURSOR" got=0 nodes='[]' has_next=true one rc num
  while [ "$got" -lt "$PAGE_SIZE" ] && [ "$has_next" = "true" ]; do
    rc=0; one=$(run_query "$(items_query 1 "$ITEM_ASSIGNEES" "$ITEM_TIMELINE")" "$cursor") || rc=$?
    if [ "$rc" -ne 0 ]; then
      rc=0; one=$(run_query "$(items_query 1 "$ITEM_ASSIGNEES" "")" "$cursor") || rc=$?
      if [ "$rc" -eq 0 ]; then
        num=$(printf '%s' "$one" | jq -r '.data.node.items.nodes[0].content.number // "?"')
        echo "::warning::board-sync: item #$num was read WITHOUT its linked PRs (its timelineItems fail for this token); its Status is only synced from its own state" >&2
      else
        rc=0; one=$(run_query "$(minimal_query)" "$cursor") || rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "::error::board-sync: cannot even step past the item after cursor '${cursor:-start}': $(head -c 200 "$ERR_FILE")" >&2
          return 1
        fi
        echo "::warning::board-sync: skipped an item that could not be read at all (id $(printf '%s' "$one" | jq -r '.data.node.items.nodes[0].id // "?"'))" >&2
        one=$(printf '%s' "$one" | jq -c '.data.node.items.nodes |= []')
      fi
    fi
    nodes=$(jq -c --argjson add "$(printf '%s' "$one" | jq -c '.data.node.items.nodes')" '. + $add' <<<"$nodes")
    has_next=$(printf '%s' "$one" | jq -r '.data.node.items.pageInfo.hasNextPage')
    cursor=$(printf '%s' "$one" | jq -r '.data.node.items.pageInfo.endCursor')
    got=$((got + 1))
  done
  jq -cn --argjson nodes "$nodes" --arg more "$has_next" --arg end "$cursor" \
    '{data:{node:{items:{pageInfo:{hasNextPage:($more=="true"),endCursor:$end},nodes:$nodes}}}}'
}

ITEM_NODES='[]'
CURSOR=""
PAGES=0
while :; do
  if ! read_page; then
    echo "  page at cursor '${CURSOR:-start}' keeps failing: reading it item by item" >&2
    PAGE=$(salvage_page) || { echo "::error::board-sync: the items query failed and could not be salvaged (gh $(gh --version | head -1))" >&2; exit 1; }
  fi
  ITEM_NODES=$(jq -c --argjson page "$(printf '%s' "$PAGE" | jq -c '.data.node.items.nodes')" '. + $page' <<<"$ITEM_NODES")
  PAGES=$((PAGES + 1))
  echo "  page $PAGES read: $(printf '%s' "$PAGE" | jq '.data.node.items.nodes | length') item(s)" >&2
  [ "$(printf '%s' "$PAGE" | jq -r '.data.node.items.pageInfo.hasNextPage')" = "true" ] || break
  CURSOR=$(printf '%s' "$PAGE" | jq -r '.data.node.items.pageInfo.endCursor')
  if [ -z "$CURSOR" ] || [ "$CURSOR" = "null" ] || [ "$PAGES" -ge 100 ]; then
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
  ASSIGNEE_COUNT=$(echo "$item" | jq '(.content.assignees.nodes // []) | length')
  CURRENT_STATUS=$(echo "$item" | jq -r '
    .fieldValues.nodes[] |
    select(.field.name == "Status") |
    .optionId // empty' | head -1)

  # Count linked PRs by state — CLOSING references only (willCloseTarget). A textual "#<n>"
  # mention in a PR body is also a cross-reference; counting it falsely marks issues Done and
  # the board's "Done -> close issue" workflow then closes them for real (issue #48).
  MERGED_PRS=$(echo "$item" | jq '[(.content.timelineItems.nodes // [])[] | select(.willCloseTarget == true) | .source | select(.merged == true)] | length')
  OPEN_PRS=$(echo "$item"   | jq '[(.content.timelineItems.nodes // [])[] | select(.willCloseTarget == true) | .source | select(.state == "OPEN")] | length')

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
