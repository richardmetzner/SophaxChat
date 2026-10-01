#!/usr/bin/env bash
# setup-github.sh
# One-shot script to configure the SophaxChat GitHub repository:
#   1. GitHub Project v2 (public roadmap with 4 milestones)
#   2. Branch protection ruleset for main
#   3. GitHub wiki (Home, Protocol, Cryptography pages)
#
# Prerequisites:
#   brew install gh
#   gh auth login          (needs repo + project + admin:org scopes)
#
# Usage:
#   bash scripts/setup-github.sh

set -euo pipefail

REPO="richardmetzner/SophaxChat"
OWNER="richardmetzner"
REPO_NAME="SophaxChat"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIKI_DIR="$SCRIPT_DIR/../wiki"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }
step() { echo -e "\n${YELLOW}▶ $*${NC}"; }

# ── 0. Preflight ─────────────────────────────────────────────────────────────
step "Preflight checks"

command -v gh  >/dev/null 2>&1 || die "gh not found. Install: brew install gh"
command -v git >/dev/null 2>&1 || die "git not found."

gh auth status 2>/dev/null | grep -q "Logged in" \
  || die "Not authenticated. Run: gh auth login --scopes repo,project,admin:org"

ok "gh authenticated"

# Verify required scopes (project scope needed for Projects v2)
SCOPES=$(gh auth status 2>&1 | grep "Token scopes" || true)
echo "   Token scopes: $SCOPES"

# ── 1. GitHub Project v2 ─────────────────────────────────────────────────────
step "Creating GitHub Project v2 — SophaxChat Roadmap"

# Get owner node ID (works for both user and org)
OWNER_ID=$(gh api graphql -f query='
  query($login: String!) {
    repositoryOwner(login: $login) { id }
  }
' -f login="$OWNER" --jq '.data.repositoryOwner.id')

[[ -n "$OWNER_ID" ]] || die "Could not resolve owner node ID for '$OWNER'"
ok "Owner ID: $OWNER_ID"

# Check if project already exists
EXISTING_PROJECT=$(gh api graphql -f query='
  query($login: String!) {
    repositoryOwner(login: $login) {
      ... on Organization { projectsV2(first: 10) { nodes { id url title } } }
      ... on User         { projectsV2(first: 10) { nodes { id url title } } }
    }
  }
' -f login="$OWNER" --jq '[.data.repositoryOwner.projectsV2.nodes[] | select(.title == "SophaxChat Roadmap")] | first' 2>/dev/null || true)

if [[ -n "$EXISTING_PROJECT" && "$EXISTING_PROJECT" != "null" ]]; then
  PROJECT_ID=$(echo "$EXISTING_PROJECT"  | jq -r '.id')
  PROJECT_URL=$(echo "$EXISTING_PROJECT" | jq -r '.url')
  warn "Project already exists: $PROJECT_URL"
else
  PROJECT_DATA=$(gh api graphql -f query='
    mutation($ownerId: ID!, $title: String!) {
      createProjectV2(input: { ownerId: $ownerId, title: $title }) {
        projectV2 { id number url }
      }
    }
  ' -f ownerId="$OWNER_ID" -f title="SophaxChat Roadmap")

  PROJECT_ID=$(echo "$PROJECT_DATA"  | jq -r '.data.createProjectV2.projectV2.id')
  PROJECT_URL=$(echo "$PROJECT_DATA" | jq -r '.data.createProjectV2.projectV2.url')

  [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "null" ]] \
    || die "Project creation failed: $(echo "$PROJECT_DATA" | jq -r '.errors')"

  ok "Project created: $PROJECT_URL"
fi

# Note: custom field creation is not available in the public Projects v2 API.
# Add the "Phase" single-select field manually:
# Project → + (add field) → Single select → options: v0.1 Alpha / TestFlight Beta / Independent Audit / v1.0
warn "Phase field must be added manually in the project UI (GitHub API limitation)"

# Add draft items for each milestone
declare -a MILESTONES=(
  "v0.1 Alpha — crypto complete, first tagged release"
  "TestFlight Beta — obtain Apple Developer account"
  "Independent Audit — engage third-party security auditor (required before v1.0)"
  "v1.0 — MLS stable, DHT peer discovery, post-audit hardening"
)

REPO_NODE_ID=$(gh api "repos/$REPO" --jq '.node_id')

for TITLE in "${MILESTONES[@]}"; do
  gh api graphql -f query='
    mutation($projectId: ID!, $title: String!) {
      addProjectV2DraftIssue(input: { projectId: $projectId, title: $title }) {
        projectItem { id }
      }
    }
  ' -f projectId="$PROJECT_ID" -f title="$TITLE" >/dev/null
  ok "  Draft item: $TITLE"
done

# Make project public
gh api graphql -f query='
  mutation($projectId: ID!) {
    updateProjectV2(input: { projectId: $projectId, public: true }) {
      projectV2 { public }
    }
  }
' -f projectId="$PROJECT_ID" >/dev/null && ok "Project set to public"

echo "   → $PROJECT_URL"

# ── 2. Branch protection ruleset ─────────────────────────────────────────────
step "Configuring branch protection ruleset for 'main'"

# Check if ruleset already exists
EXISTING=$(gh api "repos/$REPO/rulesets" --jq '[.[] | select(.name == "Protect main")] | length' 2>/dev/null || echo "0")
if [[ "$EXISTING" -gt 0 ]]; then
  warn "Ruleset 'Protect main' already exists — skipping"
else
  gh api "repos/$REPO/rulesets" \
    --method POST \
    --header "Accept: application/vnd.github+json" \
    --input - <<'JSON' >/dev/null
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "Build SophaxChatCore" },
          { "context": "Build Android debug APK" }
        ]
      }
    }
  ]
}
JSON
  ok "Branch ruleset 'Protect main' created"
  ok "  • Blocks direct push to main"
  ok "  • Blocks force push and branch deletion"
  ok "  • Requires Swift + Android CI to pass"
fi

# ── 3. Wiki ───────────────────────────────────────────────────────────────────
step "Pushing wiki pages"

[[ -d "$WIKI_DIR" ]] || die "wiki/ directory not found at $WIKI_DIR"

WIKI_REPO="https://github.com/${REPO}.wiki.git"
TMP_WIKI=$(mktemp -d)
trap 'rm -rf "$TMP_WIKI"' EXIT

# Clone or init the wiki repo
if git clone "$WIKI_REPO" "$TMP_WIKI" 2>/dev/null; then
  ok "Cloned existing wiki"
else
  warn "Wiki not yet initialised — creating fresh"
  git init "$TMP_WIKI"
  git -C "$TMP_WIKI" checkout -b main 2>/dev/null || true
fi

# Copy pages (wiki filenames = page titles with spaces as hyphens)
cp "$WIKI_DIR/Home.md"          "$TMP_WIKI/Home.md"
cp "$WIKI_DIR/Protocol.md"      "$TMP_WIKI/Protocol.md"
cp "$WIKI_DIR/Cryptography.md"  "$TMP_WIKI/Cryptography.md"

git -C "$TMP_WIKI" add .
git -C "$TMP_WIKI" diff --cached --quiet \
  && warn "Wiki already up to date — no changes to push" \
  || {
    git -C "$TMP_WIKI" \
      -c user.name="$(git config user.name)" \
      -c user.email="$(git config user.email)" \
      commit -m "docs(wiki): initial pages — Home, Protocol, Cryptography"
    git -C "$TMP_WIKI" push "$WIKI_REPO" HEAD:master 2>/dev/null \
      || git -C "$TMP_WIKI" push "$WIKI_REPO" HEAD:main
    ok "Wiki pages pushed (Home, Protocol, Cryptography)"
  }

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Project (roadmap):  $PROJECT_URL"
echo "  Wiki:               https://github.com/$REPO/wiki"
echo "  Branch rules:       https://github.com/$REPO/settings/rules"
echo ""
