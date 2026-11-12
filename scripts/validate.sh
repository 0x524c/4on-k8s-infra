#!/usr/bin/env bash
# Author: RL Robotics
# E-mail: rogerio@rlrobotics.com.br
# Licence: private use only, for RL Robotics and 4ON members.
#
# Checks the deploy tree. Run it before every commit; the Woodpecker workflow `validate` runs it on every push.
#
#   bash 4on-k8s-infra/scripts/validate.sh
#
# What it checks:
#   1. every overlay under apps/hml builds with kustomize, and so does the overlay with the translator component switched on
#   2. the built manifests are valid Kubernetes objects (kubeconform; the Argo CD kinds use the datree CRD catalog)
#   3. every one-shot Job of the stack is an Argo CD sync hook that is deleted before the next run
#   4. isolation of HML: images from our own sources come only from the repositories hyperswitch-hml-*; no Secret object,
#      no private key or access key, no source-code file and no rlrobotics.com.br host anywhere in the tree
#   5. one deploy repository URL in the Argo CD project and the applications
#   6. the base equals a fresh render of the chart (only when the chart is next to this tree, i.e. in the main repository)
#
# Environment: K8S_INFRA_TREE (the tree to check, default the one this script is in); VALIDATE_SKIP_SCHEMA=1 skips check 2.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=$(cd "${K8S_INFRA_TREE:-$HERE/..}" && pwd)
FAILS=0
ok() { printf 'ok       %s\n' "$*"; }
note() { printf 'note     %s\n' "$*"; }
bad() { printf 'FAILED   %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

if command -v kustomize >/dev/null 2>&1; then build() { kustomize build "$1"; }
elif command -v kubectl >/dev/null 2>&1; then build() { kubectl kustomize "$1"; }
else echo "FAILED   neither kustomize nor kubectl is installed" >&2; exit 1; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. builds
for dir in "$TREE"/apps/hml/*/; do
  [ -f "$dir/kustomization.yaml" ] || continue
  name=$(basename "$dir")
  if build "$dir" >"$WORK/$name.yaml" 2>"$WORK/$name.err"; then
    ok "apps/hml/$name builds ($(grep -c '^kind:' "$WORK/$name.yaml") objects)"
  else
    bad "apps/hml/$name does not build: $(head -3 "$WORK/$name.err")"
  fi
done
if [ -f "$WORK/hyperswitch.yaml" ]; then
  # The same overlay with the component switched on: a copy of the tree whose two commented lines are uncommented, so the
  # line the owner will uncomment is the one that is tested.
  mkdir -p "$WORK/tree" && cp -r "$TREE/apps" "$TREE/components" "$WORK/tree/"
  sed -i -e 's|^#components:|components:|' -e 's|^#  - \.\./\.\./\.\./components/translator|  - ../../../components/translator|' \
    "$WORK/tree/apps/hml/hyperswitch/kustomization.yaml"
  if build "$WORK/tree/apps/hml/hyperswitch" >"$WORK/with-translator.yaml" 2>"$WORK/wt.err"; then
    before=$(grep -c '^kind:' "$WORK/hyperswitch.yaml")
    after=$(grep -c '^kind:' "$WORK/with-translator.yaml")
    if [ "$((after - before))" = 4 ]; then ok "with the translator component switched on the overlay adds 4 objects (Deployment, Service, NetworkPolicy, Job)"
    else bad "the translator component adds $((after - before)) objects, expected 4"; fi
  else
    bad "the overlay does not build with the translator component switched on: $(head -3 "$WORK/wt.err")"
  fi
fi

# 2. schema
if [ "${VALIDATE_SKIP_SCHEMA:-0}" = 1 ]; then note "schema check skipped (VALIDATE_SKIP_SCHEMA=1)"
elif ! command -v kubeconform >/dev/null 2>&1; then note "kubeconform is not installed: schema check skipped"
else
  for f in "$WORK"/hyperswitch.yaml "$WORK"/argocd-apps.yaml; do
    [ -f "$f" ] || continue
    if kubeconform -strict -ignore-missing-schemas -summary -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$f" >"$WORK/kc.out" 2>&1; then ok "$(basename "$f" .yaml): $(tail -1 "$WORK/kc.out")"
    else bad "$(basename "$f" .yaml) fails the schema check: $(grep -v '^Summary' "$WORK/kc.out" | head -3)"; fi
  done
fi

# 3. Job hooks
if [ -f "$WORK/hyperswitch.yaml" ]; then
  if python3 -I - "$WORK/hyperswitch.yaml" >"$WORK/hooks.out" 2>&1 <<'PY'
import sys
import yaml
jobs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d['kind'] == 'Job']
wrong = [j['metadata']['name'] for j in jobs
         if j['metadata'].get('annotations', {}).get('argocd.argoproj.io/hook') != 'Sync'
         or j['metadata']['annotations'].get('argocd.argoproj.io/hook-delete-policy') != 'BeforeHookCreation']
if wrong:
    sys.exit('Jobs that are not Argo CD sync hooks with BeforeHookCreation: ' + ', '.join(wrong))
print('every one-shot Job (%d) is an Argo CD sync hook deleted before the next run' % len(jobs))
PY
  then ok "$(cat "$WORK/hooks.out")"; else bad "$(cat "$WORK/hooks.out")"; fi
fi

# 4. isolation
cat "$WORK"/hyperswitch.yaml "$WORK/with-translator.yaml" 2>/dev/null | grep -oE 'image: \S*dkr\.ecr\S*' | sort -u >"$WORK/ecr.txt" || true
foreign=$(grep -vE '/hyperswitch-hml-[a-z-]+:' "$WORK/ecr.txt" || true)
if [ -n "$foreign" ]; then bad "ECR images outside HML's own repositories: $(echo "$foreign" | tr '\n' ' ')"
else ok "every ECR image comes from a repository hyperswitch-hml-* ($(wc -l <"$WORK/ecr.txt") distinct)"; fi
if grep -rlE '^kind: Secret$' "$TREE/apps" "$TREE/components" 2>/dev/null | grep -q .; then bad "a Secret object is in the tree; secrets are made from Secrets Manager by scripts/hml-platform.sh"
else ok "no Secret object in the tree"; fi
if grep -rlE 'BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}' "$TREE" --exclude-dir=.git --exclude=validate.sh --exclude=test-k8s-infra.sh 2>/dev/null | grep -q .; then bad "a private key or an access key id is in the tree"
else ok "no private key or access key in the tree"; fi
if [ -n "$(find "$TREE" \( -name '*.rs' -o -name Cargo.toml -o -name Cargo.lock \) -not -path '*/.git/*' 2>/dev/null | head -1)" ]; then bad "a source-code file is in the tree"
else ok "no source-code file in the tree"; fi
if grep -rl 'rlrobotics\.com\.br' "$TREE" --exclude-dir=.git --exclude='*.sh' 2>/dev/null | grep -q .; then bad "a host under rlrobotics.com.br is named in the tree"
else ok "no rlrobotics.com.br host in the tree"; fi

# 5. one repository URL
urls=$(grep -rhoE 'git@github\.com:[A-Za-z0-9._/-]+\.git' "$TREE/apps/hml/argocd-apps" | sort -u)
if [ "$(echo "$urls" | grep -c .)" = 1 ]; then ok "one deploy repository in the Argo CD project and applications: $urls"
else bad "the Argo CD project and applications name $(echo "$urls" | grep -c .) repositories: $(echo "$urls" | tr '\n' ' ')"; fi

# 6. the base equals the chart
if [ -f "$TREE/../code/deploy/hyperswitch/hml/chart/Chart.yaml" ]; then
  if bash "$TREE/scripts/render-base.sh" --check >"$WORK/render.out" 2>&1; then ok "$(tail -1 "$WORK/render.out" | sed 's/^ok *//')"
  else bad "$(head -3 "$WORK/render.out")"; fi
else note "the chart is not next to this tree: the render check is skipped (it runs in the main repository)"; fi

if [ "$FAILS" = 0 ]; then echo "validate: all checks passed"; else echo "validate: $FAILS check(s) failed" >&2; exit 1; fi
