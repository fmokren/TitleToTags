#!/usr/bin/env bash
set -euo pipefail

# Create a GitHub repository and push the current repo to it.
# Usage:
#   REPO_NAME=TitleToTags VISIBILITY=public ./scripts/create_and_push_github.sh
# Environment:
#   - REPO_NAME: name of the repo to create (defaults to current directory name)
#   - VISIBILITY: public or private (defaults to public)
#   - OWNER: optional GitHub owner (user or org). If set and using REST API this will create under the org.
#   - GITHUB_TOKEN: personal access token with 'repo' scope (used if gh is not installed)

REPO_NAME=${REPO_NAME:-$(basename "$(pwd)")}
VISIBILITY=${VISIBILITY:-public}
OWNER=${OWNER:-}

if [[ "$VISIBILITY" != "public" && "$VISIBILITY" != "private" ]]; then
  echo "VISIBILITY must be 'public' or 'private'" >&2
  exit 2
fi

echo "Repo name: $REPO_NAME"
echo "Visibility: $VISIBILITY"
if [[ -n "$OWNER" ]]; then
  echo "Owner: $OWNER"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required but not found in PATH" >&2
  exit 3
fi

# Initialize repo if needed
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Initializing git repository..."
  git init
  git checkout -b main || git symbolic-ref HEAD refs/heads/main
fi

# Stage & commit if no commits exist
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "Creating initial commit..."
  git add --all || true
  git commit -m "Initial commit" || true
fi

set -o pipefail

if command -v gh >/dev/null 2>&1; then
  echo "Found gh CLI; using it to create and push the repo."
  GH_CMD=(gh repo create "$REPO_NAME" --"$VISIBILITY" --source=. --remote=origin --push --confirm)
  if [[ -n "$OWNER" ]]; then
    GH_CMD+=(--owner "$OWNER")
  fi
  echo "Running: ${GH_CMD[*]}"
  # shellcheck disable=SC2086
  eval "${GH_CMD[*]}"
  echo "Done (gh)."
  exit 0
fi

echo "gh CLI not found — falling back to GitHub REST API."

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  # Prompt for token
  echo -n "Enter a GitHub Personal Access Token (repo scope) or set GITHUB_TOKEN env var: "
  read -s GITHUB_TOKEN
  echo
  if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "No token provided; aborting." >&2
    exit 4
  fi
fi

API_URL="https://api.github.com"
if [[ -n "$OWNER" ]]; then
  CREATE_URL="$API_URL/orgs/$OWNER/repos"
else
  CREATE_URL="$API_URL/user/repos"
fi

private_flag=false
if [[ "$VISIBILITY" == "private" ]]; then
  private_flag=true
fi

payload=$(cat <<EOF
{ "name": "$REPO_NAME", "private": $private_flag }
EOF
)

echo "Creating repository via REST API..."
response=$(curl -sS -w "\n%{http_code}" -X POST "$CREATE_URL" \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "$payload")

http_code=$(printf "%s" "$response" | tail -n1)
body=$(printf "%s" "$response" | sed '$d')

if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
  echo "Repository created (HTTP $http_code)."
else
  echo "Failed to create repository (HTTP $http_code). Response body:" >&2
  printf '%s
' "$body" >&2
  # If repository already exists, try to continue
  if [[ "$http_code" -eq 422 ]]; then
    echo "Repository may already exist; attempting to set remote and push anyway."
  else
    exit 5
  fi
fi

# Extract push URL (prefer ssh_url then clone_url)
clone_url=""
if command -v jq >/dev/null 2>&1; then
  clone_url=$(printf '%s' "$body" | jq -r '.ssh_url // .clone_url // empty')
else
  # simple grep-based extraction
  clone_url=$(printf '%s' "$body" | grep -E '"(ssh_url|clone_url)"' | head -n1 | sed -E 's/.*: *"([^"]+)".*/\1/') || true
fi

if [[ -z "$clone_url" ]]; then
  echo "Could not determine repository URL from API response. Response body:" >&2
  printf '%s
' "$body" >&2
  exit 6
fi

echo "Using remote URL: $clone_url"

if git remote get-url origin >/dev/null 2>&1; then
  echo "Remote 'origin' already exists; updating its URL to $clone_url"
  git remote set-url origin "$clone_url"
else
  git remote add origin "$clone_url"
fi

echo "Pushing local 'main' branch to origin..."
git push -u origin main

echo "Repository pushed successfully."
