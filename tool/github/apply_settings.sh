#!/usr/bin/env bash
# Applies the repository settings the CI, the security files and the contributing rules of this
# repository assume. The owner runs it once, with `gh` logged in as an administrator of the
# repository (gh auth login), after the pull request that adds those files is merged:
#
#   tool/github/apply_settings.sh --dry-run     print every change it would make; calls nothing
#   tool/github/apply_settings.sh               asks, then applies them
#   tool/github/apply_settings.sh --yes         applies them without asking
#
# Options:
#   --repo owner/name      default Arsslensoft/Kemlock
#   --no-admin-bypass      the ruleset has no bypass: the owner's own pull requests need an approving
#                          review from someone else too. With one maintainer they could never merge.
#   --no-tag-ruleset       don't protect the v* release tags
#
# What it sets, and where each part is explained:
#   - the repository: squash merge only (the pull request's title and description become the commit,
#     which release-please reads), auto-merge allowed, branches deleted after merge, the web editor
#     adds a DCO sign-off, no wiki or projects, a description and topics;
#   - private vulnerability reporting (.github/SECURITY.md), Dependabot alerts and security updates
#     (.github/dependabot.yml), secret scanning and push protection (.github/workflows/secret-scan.yml);
#   - GitHub Actions: the workflow token reads only by default, and Actions may approve pull requests
#     (the Dependabot auto-merge workflow approves the security updates it merges);
#   - a ruleset on main: a pull request with one approving review and the conversations resolved, the
#     required checks below passing on an up to date branch, linear history, squash only, no force
#     push, no deletion;
#   - a ruleset that stops the v* release tags from being moved or deleted.
#
# The required checks are the job names of the workflows, exactly (the check name is the job's `name:`):
#   CI gate                .github/workflows/ci.yml          every Dart, Android, iOS and wasm job (see its header)
#   DCO                    .github/workflows/dco.yml         every commit signed off by its author
#   Conventional Commits   .github/workflows/commits.yml     the commits and the pull request's title
#   Licences               .github/workflows/licences.yml    Dart dependencies' licences
#   REUSE                  .github/workflows/licences.yml    every file's licence is declared
#   Secret scan            .github/workflows/secret-scan.yml gitleaks
#   Dependency review      .github/workflows/dependency-review.yml
#   Analyze (actions) / (python) / (java-kotlin)   .github/workflows/codeql.yml
# A check skipped by its workflow (code scanning on a private repository without Advanced Security)
# counts as passing. Edit the list below if a job is renamed.
set -euo pipefail

repo="Arsslensoft/Kemlock"
dry=0
yes=0
admin_bypass=1
tag_ruleset=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --yes) yes=1 ;;
    --repo) repo="${2:?--repo needs owner/name}"; shift ;;
    --repo=*) repo="${1#--repo=}" ;;
    --no-admin-bypass) admin_bypass=0 ;;
    --no-tag-ruleset) tag_ruleset=0 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

description="Post-quantum encrypted authenticator and password manager for Android and iOS: local-first, ML-KEM-1024 and AES-256-GCM, free software."
topics='["authenticator","password-manager","totp","two-factor-authentication","passkeys","post-quantum","ml-kem","encryption","local-first","privacy","flutter","dart","android","ios","f-droid","reproducible-builds","free-software"]'

required_checks=(
  "CI gate"
  "DCO"
  "Conventional Commits"
  "Licences"
  "REUSE"
  "Secret scan"
  "Dependency review"
  "Analyze (actions)"
  "Analyze (python)"
  "Analyze (java-kotlin)"
)

if [ "$dry" = 0 ]; then
  command -v gh >/dev/null || { echo "gh is not installed (https://cli.github.com)" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run gh auth login" >&2; exit 1; }
fi

failures=0

# api <method> <endpoint> [json body]: prints the call, and makes it unless this is a dry run. A call
# that fails is reported and the rest still run; the exit status says whether any did.
api() {
  local method="$1" endpoint="$2" body="${3:-}"
  echo "  $method $endpoint"
  if [ -n "$body" ]; then
    printf '%s\n' "$body" | sed 's/^/      /'
  fi
  [ "$dry" = 1 ] && return 0
  local ok=0
  if [ -n "$body" ]; then
    printf '%s' "$body" | gh api -X "$method" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" "$endpoint" --input - >/dev/null && ok=1
  else
    gh api -X "$method" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$endpoint" >/dev/null && ok=1
  fi
  if [ "$ok" = 0 ]; then
    echo "      FAILED (see the message above)" >&2
    failures=$((failures + 1))
  fi
}

section() { printf '\n== %s\n' "$1"; }

contexts=""
for check in "${required_checks[@]}"; do
  contexts="${contexts:+$contexts,}{\"context\":\"$check\"}"
done

bypass='[]'
if [ "$admin_bypass" = 1 ]; then
  # Repository role 5 is Admin. "pull_request" lets an admin merge a pull request without the review
  # and the checks being satisfied, but never push to main directly.
  bypass='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]'
fi

main_ruleset=$(
  cat <<JSON
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": $bypass,
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [$contexts]
      }
    }
  ]
}
JSON
)

tag_rules=$(
  cat <<JSON
{
  "name": "Protect release tags",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" }, { "type": "update" } ]
}
JSON
)

echo "Repository: $repo"
[ "$dry" = 1 ] && echo "DRY RUN: nothing below is sent to GitHub."

if [ "$dry" = 0 ] && [ "$yes" = 0 ]; then
  read -r -p "Apply these settings to $repo? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing changed."; exit 0; }
fi

section "Repository: merge settings, description"
api PATCH "repos/$repo" "$(
  cat <<JSON
{
  "description": "$description",
  "has_issues": true,
  "has_wiki": false,
  "has_projects": false,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "allow_auto_merge": true,
  "allow_update_branch": true,
  "delete_branch_on_merge": true,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY",
  "web_commit_signoff_required": true
}
JSON
)"

section "Topics"
api PUT "repos/$repo/topics" "{\"names\": $topics}"

section "Security: private vulnerability reporting"
api PUT "repos/$repo/private-vulnerability-reporting"

section "Security: Dependabot alerts and security updates"
api PUT "repos/$repo/vulnerability-alerts"
api PUT "repos/$repo/automated-security-fixes"

section "Security: secret scanning and push protection"
api PATCH "repos/$repo" '{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}'

section "GitHub Actions: read-only token by default; Actions may approve pull requests"
api PUT "repos/$repo/actions/permissions/workflow" '{
  "default_workflow_permissions": "read",
  "can_approve_pull_request_reviews": true
}'

# A ruleset is created, or updated if one of that name exists (a re-run changes nothing else).
apply_ruleset() {
  local name="$1" body="$2" id=""
  if [ "$dry" = 1 ]; then
    echo "  (creates the ruleset \"$name\", or updates it if it exists)"
    api POST "repos/$repo/rulesets" "$body"
    return
  fi
  id="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null | head -n 1 || true)"
  if [ -n "$id" ]; then
    api PUT "repos/$repo/rulesets/$id" "$body"
  else
    api POST "repos/$repo/rulesets" "$body"
  fi
}

section "Ruleset on main"
apply_ruleset "Protect main" "$main_ruleset"

if [ "$tag_ruleset" = 1 ]; then
  section "Ruleset on v* tags"
  apply_ruleset "Protect release tags" "$tag_rules"
fi

echo
if [ "$dry" = 1 ]; then
  echo "Dry run done: run again without --dry-run to apply."
elif [ "$failures" -gt 0 ]; then
  echo "$failures call(s) failed. Private vulnerability reporting, secret scanning and the like are only" >&2
  echo "available for a public repository, or one with GitHub Advanced Security: run this again after" >&2
  echo "the repository is public. Nothing that succeeded is undone." >&2
  exit 1
else
  echo "All settings applied."
fi
