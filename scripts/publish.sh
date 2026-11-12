#!/usr/bin/env bash
# Author: RL Robotics
# E-mail: rogerio@rlrobotics.com.br
# Licence: private use only, for RL Robotics and 4ON members.
#
# Publishes this repository: validates it, commits what changed as one commit and pushes it to main of origin, the private GitHub
# repository Argo CD and Woodpecker read (the URL of apps/hml/argocd-apps/applications.yaml). The tree holds deployment
# configuration only; validate.sh runs first and refuses source code, a Secret object or a key.
#
#   bash 4on-k8s-infra/scripts/publish.sh            plan: what would be committed, nothing is changed or pushed
#   bash 4on-k8s-infra/scripts/publish.sh --apply    commit the changes (one line message) and push them to main
#
# The GitHub repository must already exist (the owner makes it, private); the push uses the owner's own SSH access. The script
# refuses when origin is not the URL named in applications.yaml (K8S_INFRA_REMOTE names the URL when it is another one on purpose,
# as the tests do with a local bare repository).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=$(cd "$HERE/.." && pwd)
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
say() { printf '%-9s %s\n' "$1" "$2"; }
die() { printf 'FAILED   %s\n' "$*" >&2; exit 1; }
g() { git -C "$TREE" "$@"; }

[ -d "$TREE/.git" ] || die "$TREE is not a git repository (git init -b main, then git remote add origin <the URL of applications.yaml>)"
WANT=$(grep -hoE 'git@github\.com:[A-Za-z0-9._/-]+\.git' "$TREE/apps/hml/argocd-apps/applications.yaml" | head -n 1)
HAVE=$(g remote get-url origin 2>/dev/null) || die "no remote origin; run: git -C $TREE remote add origin $WANT"
if [ "$HAVE" != "$WANT" ] && [ "${K8S_INFRA_REMOTE:-}" != "$HAVE" ]; then die "origin is $HAVE, not $WANT"; fi

K8S_INFRA_TREE=$TREE VALIDATE_SKIP_SCHEMA=${VALIDATE_SKIP_SCHEMA:-1} bash "$HERE/validate.sh" >/dev/null 2>&1 \
  || { K8S_INFRA_TREE=$TREE VALIDATE_SKIP_SCHEMA=1 bash "$HERE/validate.sh" >&2 || true; die "the tree does not validate; nothing was published"; }
say ok "the tree validates"

changed=$(g status --porcelain | head -n 1)
head=$(g rev-parse -q --verify HEAD || true)
remote=$(g ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
if [ -z "$changed" ] && [ -n "$head" ] && [ "$head" = "$remote" ]; then say ok "nothing to publish: origin already has this tree"; exit 0; fi
g status --short | head -n 20
if [ "$APPLY" != 1 ]; then say plan "would commit the changes above (if any) and push HEAD to main of $HAVE"; exit 0; fi
if [ -n "$changed" ]; then g add -A && g commit --quiet -m "deploy: update the HML deploy tree"; fi
g push --quiet origin HEAD:main || die "push to $HAVE"
say ok "pushed $(g rev-parse --short HEAD) to main of $HAVE"
