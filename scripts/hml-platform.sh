#!/usr/bin/env bash
# Author: RL Robotics
# E-mail: rogerio@rlrobotics.com.br
# Licence: private use only, for RL Robotics and 4ON members.
#
# Installs the delivery platform of the HML cluster (hyperswitch-hml, account 405712027313): Argo CD, the Argo CD project and
# applications of this tree, and the secrets Woodpecker needs. Run it from any directory; commands below are shown from the
# repository root.
#
#   bash 4on-k8s-infra/scripts/hml-platform.sh                    plan, read-only: what each step would do, what is still missing
#   bash 4on-k8s-infra/scripts/hml-platform.sh --apply            do it; stops at the first error, the same command again continues
#   bash 4on-k8s-infra/scripts/hml-platform.sh set-github-oauth   asks for the client id and secret of the GitHub OAuth app of
#                                                                  Woodpecker (typed, never echoed) and stores them in Secrets Manager
#   bash 4on-k8s-infra/scripts/hml-platform.sh sync [APP]         asks Argo CD to sync an application (default hyperswitch-hml)
#                                                                  and waits until it is Synced and Healthy
#   bash 4on-k8s-infra/scripts/hml-platform.sh token              makes the project role token of the Woodpecker workflow
#   bash 4on-k8s-infra/scripts/hml-platform.sh status             read-only: the applications, sync and health
#
# Steps of --apply, in this order:
#   1. argo-cd       helm upgrade --install of the chart argo-cd (pinned) with apps/base and apps/hml values, namespace argocd
#   2. repo-key      the SSH deploy key Argo CD reads the deploy repository with: generated once into Secrets Manager
#                    (hyperswitch-hml/ARGOCD_DEPLOY_KEY), its public half printed for you to add as a READ-ONLY deploy key
#   3. namespaces    hyperswitch and woodpecker
#   4. woodpecker    the Secrets woodpecker-agent-secret (generated once) and woodpecker-github-secret (your OAuth app's values)
#   5. applications  the Argo CD project and applications of apps/hml/argocd-apps; no sync: the first sync is `sync`
#
# Secret values are read from and written to Secrets Manager (names hyperswitch-hml/*) through mode-600 files of a scratch
# directory that is removed on exit; none is printed. Nothing here touches production, the EC2 node or a resource outside
# HML's names. The cluster is reached with a private kubeconfig of the run, never ~/.kube/config.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=$(cd "$HERE/.." && pwd)
ACCOUNT=405712027313
PROFILE=${AWS_PROFILE:-rlr}
REGION=sa-east-1
CLUSTER=hyperswitch-hml
SMP=hyperswitch-hml
ARGO_CHART_VERSION=10.18.0
ARGO_CHART_REPO=https://argoproj.github.io/argo-helm
APPLY=0
CMD=plan
ARGS=()

say() { printf '%-9s %s\n' "$1" "$2"; }
die() { printf 'FAILED    %s\n' "$*" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    plan | set-github-oauth | sync | token | status) CMD=$a ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p' | head -n 30; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done

REPO_URL=$(grep -hoE 'git@github\.com:[A-Za-z0-9._/-]+\.git' "$TREE/apps/hml/argocd-apps/applications.yaml" | head -n 1)
[ -n "$REPO_URL" ] || die "no deploy repository URL in apps/hml/argocd-apps/applications.yaml"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hml-platform.XXXXXX")
chmod 700 "$TMP"
KC=$TMP/kubeconfig
PF_PID=""
cleanup() {
  [ -z "$PF_PID" ] || kill "$PF_PID" 2>/dev/null || true
  case "$TMP" in "${TMPDIR:-/tmp}"/hml-platform.?*) rm -rf -- "$TMP" ;; esac
}
trap cleanup EXIT

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
k() { KUBECONFIG=$KC command kubectl --kubeconfig "$KC" "$@"; }
h() { KUBECONFIG=$KC HELM_REPOSITORY_CONFIG=$TMP/helm-repos.yaml HELM_REPOSITORY_CACHE=$TMP/helm-cache command helm --kubeconfig "$KC" "$@"; }

guard() {
  local acct
  acct=$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null) || die "no AWS credentials for profile $PROFILE (run: aws sso login --profile $PROFILE)"
  [ "$acct" = "$ACCOUNT" ] || die "profile $PROFILE is account $acct, not $ACCOUNT"
  local st
  st=$(aws_ eks describe-cluster --name "$CLUSTER" --query cluster.status --output text 2>/dev/null) || die "cluster $CLUSTER not found"
  [ "$st" = ACTIVE ] || die "cluster $CLUSTER is $st, not ACTIVE"
  aws_ eks update-kubeconfig --name "$CLUSTER" --kubeconfig "$KC" >/dev/null || die "eks update-kubeconfig"
  chmod 600 "$KC"
}

# sm_state KEY: value | empty | absent. Never prints the value.
sm_state() {
  local v
  if ! v=$(aws_ secretsmanager get-secret-value --secret-id "$SMP/$1" --query SecretString --output text 2>"$TMP/sm.err"); then
    grep -q ResourceNotFoundException "$TMP/sm.err" && { echo absent; return 0; }
    die "secretsmanager get-secret-value $SMP/$1: $(tail -n 1 "$TMP/sm.err")"
  fi
  if [ -n "$v" ] && [ "$v" != None ]; then echo value; else echo empty; fi
}
# sm_put_file KEY FILE: stores the file's content; creates the secret when absent, otherwise puts a value into the empty one.
sm_put_file() {
  case "$(sm_state "$1")" in
    absent) aws_ secretsmanager create-secret --name "$SMP/$1" --description "HML delivery platform: $1" --secret-string "file://$2" >/dev/null || die "create-secret $SMP/$1" ;;
    empty) aws_ secretsmanager put-secret-value --secret-id "$SMP/$1" --secret-string "file://$2" >/dev/null || die "put-secret-value $SMP/$1" ;;
    value) die "secret $SMP/$1 already has a value; this tool never overwrites one" ;;
  esac
}
sm_get_file() { (umask 077 && aws_ secretsmanager get-secret-value --secret-id "$SMP/$1" --query SecretString --output text >"$2") || die "get-secret-value $SMP/$1"; }

# secret_apply NAMESPACE NAME KEY=SMKEY... : a Kubernetes Secret built from mode-600 files, applied server-side from stdin.
secret_apply() {
  local ns=$1 name=$2 pair args=() dir=$TMP/sv-$2
  shift 2
  mkdir -p "$dir" && chmod 700 "$dir"
  for pair in "$@"; do sm_get_file "${pair#*=}" "$dir/${pair%%=*}"; args+=("--from-file=${pair%%=*}=$dir/${pair%%=*}"); done
  k create secret generic "$name" --namespace "$ns" "${args[@]}" --dry-run=client -o json \
    | k apply --server-side --force-conflicts --field-manager=hml-platform -f - >/dev/null || die "kubectl apply of the Secret $ns/$name"
  rm -rf -- "$dir"
  say ok "Secret $ns/$name from Secrets Manager (values never printed)"
}

ensure_namespace() {
  if k get namespace "$1" >/dev/null 2>&1; then say exists "namespace $1"
  elif [ "$APPLY" = 1 ]; then k create namespace "$1" >/dev/null || die "create namespace $1"; say created "namespace $1"
  else say plan "would create namespace $1"; fi
}

step_argocd() {
  local rel
  rel=$(h list --namespace argocd --filter '^argocd$' --short 2>/dev/null || true)
  if [ "$APPLY" != 1 ]; then
    h template argocd argo-cd --repo "$ARGO_CHART_REPO" --version "$ARGO_CHART_VERSION" --namespace argocd \
      -f "$TREE/apps/base/argo-cd/values.yaml" -f "$TREE/apps/hml/argo-cd/values.yaml" >/dev/null 2>"$TMP/tpl.err" \
      || die "helm template of argo-cd $ARGO_CHART_VERSION with the tree's values: $(tail -n 2 "$TMP/tpl.err" | tr '\n' ' ')"
    say ok "helm template of argo-cd $ARGO_CHART_VERSION with apps/base and apps/hml values renders"
    if [ -n "$rel" ]; then say plan "would upgrade the Helm release argocd (chart $ARGO_CHART_VERSION)"; else say plan "would install the Helm release argocd (chart $ARGO_CHART_VERSION) in namespace argocd"; fi
    return 0
  fi
  h upgrade --install argocd argo-cd --repo "$ARGO_CHART_REPO" --version "$ARGO_CHART_VERSION" --namespace argocd --create-namespace \
    -f "$TREE/apps/base/argo-cd/values.yaml" -f "$TREE/apps/hml/argo-cd/values.yaml" --wait --timeout 10m >"$TMP/helm.txt" 2>&1 \
    || die "helm upgrade --install argocd: $(tail -n 4 "$TMP/helm.txt" | tr '\n' ' ')"
  say ok "Helm release argocd (chart $ARGO_CHART_VERSION): $(grep -E '^(STATUS|REVISION):' "$TMP/helm.txt" | tr '\n' ' ')"
}

step_repo_key() {
  local state
  state=$(sm_state ARGOCD_DEPLOY_KEY)
  if [ "$state" = value ]; then
    say exists "secret $SMP/ARGOCD_DEPLOY_KEY (has a value; never overwritten)"
  elif [ "$APPLY" != 1 ]; then
    say plan "would generate an ed25519 key pair, store the private key as $SMP/ARGOCD_DEPLOY_KEY and print the public key"
    say waiting "you add that public key as a READ-ONLY deploy key of $REPO_URL (GitHub: repository Settings > Deploy keys)"
    return 0
  else
    command -v ssh-keygen >/dev/null || die "ssh-keygen is not installed"
    (umask 077 && ssh-keygen -q -t ed25519 -N '' -C "argocd-hml-deploy-key" -f "$TMP/deploy-key") || die "ssh-keygen"
    sm_put_file ARGOCD_DEPLOY_KEY "$TMP/deploy-key"
    say created "secret $SMP/ARGOCD_DEPLOY_KEY (private key; never printed)"
    say action "add this public key as a READ-ONLY deploy key of $REPO_URL (GitHub: repository Settings > Deploy keys; leave 'Allow write access' off):"
    cat "$TMP/deploy-key.pub"
    rm -f "$TMP/deploy-key" "$TMP/deploy-key.pub"
  fi
  [ "$APPLY" = 1 ] || return 0
  sm_get_file ARGOCD_DEPLOY_KEY "$TMP/sshPrivateKey"
  k create secret generic repo-4on-k8s-infra --namespace argocd --from-literal=type=git --from-literal=url="$REPO_URL" \
    --from-file=sshPrivateKey="$TMP/sshPrivateKey" --dry-run=client -o json \
    | jq '.metadata.labels["argocd.argoproj.io/secret-type"]="repository"' \
    | k apply --server-side --force-conflicts --field-manager=hml-platform -f - >/dev/null || die "kubectl apply of the repository Secret"
  rm -f "$TMP/sshPrivateKey"
  say ok "Secret argocd/repo-4on-k8s-infra: the deploy repository $REPO_URL (private key from Secrets Manager, never printed)"
}

step_woodpecker() {
  local s
  s=$(sm_state WOODPECKER_AGENT_SECRET)
  if [ "$s" = value ]; then say exists "secret $SMP/WOODPECKER_AGENT_SECRET (has a value; never overwritten)"
  elif [ "$APPLY" = 1 ]; then
    command -v openssl >/dev/null || die "openssl is not installed"
    (umask 077 && openssl rand -hex 32 | tr -d '\n' >"$TMP/agent-secret")
    sm_put_file WOODPECKER_AGENT_SECRET "$TMP/agent-secret"; rm -f "$TMP/agent-secret"
    say created "secret $SMP/WOODPECKER_AGENT_SECRET (generated once)"
  else say plan "would generate secret $SMP/WOODPECKER_AGENT_SECRET (once)"; fi
  [ "$APPLY" != 1 ] || secret_apply woodpecker woodpecker-agent-secret WOODPECKER_AGENT_SECRET=WOODPECKER_AGENT_SECRET
  if [ "$(sm_state WOODPECKER_GITHUB_CLIENT)" = value ] && [ "$(sm_state WOODPECKER_GITHUB_SECRET)" = value ]; then
    say exists "secrets $SMP/WOODPECKER_GITHUB_CLIENT and WOODPECKER_GITHUB_SECRET (have values)"
    [ "$APPLY" != 1 ] || secret_apply woodpecker woodpecker-github-secret WOODPECKER_GITHUB_CLIENT=WOODPECKER_GITHUB_CLIENT WOODPECKER_GITHUB_SECRET=WOODPECKER_GITHUB_SECRET
  else
    say waiting "the GitHub OAuth app of Woodpecker (callback http://localhost:8000/authorize while the server is reached by port-forward): create it in GitHub (Settings > Developer settings > OAuth Apps), then run: bash $HERE/hml-platform.sh set-github-oauth"
  fi
}

step_applications() {
  if [ "$APPLY" != 1 ]; then
    k kustomize "$TREE/apps/hml/argocd-apps" >/dev/null 2>"$TMP/kz.err" || die "kustomize build of apps/hml/argocd-apps: $(head -n 2 "$TMP/kz.err")"
    say plan "would apply the Argo CD project hml and the applications hyperswitch-hml and woodpecker (no sync)"
    return 0
  fi
  k kustomize "$TREE/apps/hml/argocd-apps" | k apply --server-side --force-conflicts --field-manager=hml-platform -f - >/dev/null || die "apply of apps/hml/argocd-apps"
  say ok "Argo CD project hml and applications hyperswitch-hml and woodpecker applied (not synced)"
}

cmd_plan() {
  guard
  if [ "$APPLY" = 1 ]; then echo "mode      APPLY"; else echo "mode      PLAN: read-only, nothing is created"; fi
  say ok "account $ACCOUNT, profile $PROFILE, cluster $CLUSTER ACTIVE, deploy repository $REPO_URL"
  echo "== step 1 of 5: argo-cd"; step_argocd
  echo "== step 2 of 5: repo-key"; step_repo_key
  echo "== step 3 of 5: namespaces"; ensure_namespace hyperswitch; ensure_namespace woodpecker
  echo "== step 4 of 5: woodpecker"; step_woodpecker
  echo "== step 5 of 5: applications"; step_applications
  if [ "$APPLY" = 1 ]; then
    echo "hml-platform: done. Next: push the tree to $REPO_URL, then: bash $HERE/hml-platform.sh sync"
  else
    echo "hml-platform: plan only. Apply it with: bash $HERE/hml-platform.sh --apply"
  fi
}

cmd_set_github_oauth() {
  local id secret
  guard
  [ "$(sm_state WOODPECKER_GITHUB_CLIENT)" = value ] && die "secret $SMP/WOODPECKER_GITHUB_CLIENT already has a value; this tool never overwrites one"
  printf 'GitHub OAuth app client id: ' >&2; read -r id
  printf 'GitHub OAuth app client secret (not shown): ' >&2; read -rs secret; echo >&2
  [ -n "$id" ] && [ -n "$secret" ] || die "both values are required"
  (umask 077 && printf '%s' "$id" >"$TMP/gh-client" && printf '%s' "$secret" >"$TMP/gh-secret")
  sm_put_file WOODPECKER_GITHUB_CLIENT "$TMP/gh-client"; sm_put_file WOODPECKER_GITHUB_SECRET "$TMP/gh-secret"
  say created "secrets $SMP/WOODPECKER_GITHUB_CLIENT and WOODPECKER_GITHUB_SECRET (values never printed). Run: bash $HERE/hml-platform.sh --apply"
}

cmd_sync() {
  local app=${ARGS[0]:-hyperswitch-hml}
  guard
  k get application "$app" -n argocd >/dev/null 2>&1 || die "no Argo CD application $app (run --apply first)"
  k patch application "$app" -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"hml-platform"},"sync":{"revision":"HEAD"}}}' >/dev/null || die "could not start the sync of $app"
  say started "sync of $app; waiting for Synced and Healthy (up to 20 minutes)"
  k wait application "$app" -n argocd --for=jsonpath='{.status.sync.status}'=Synced --timeout=20m >/dev/null || die "$app did not become Synced: $(k get application "$app" -n argocd -o jsonpath='{.status.operationState.message}')"
  k wait application "$app" -n argocd --for=jsonpath='{.status.health.status}'=Healthy --timeout=20m >/dev/null || die "$app did not become Healthy"
  say ok "$app is Synced and Healthy"
}

cmd_token() {
  command -v argocd >/dev/null || die "the argocd CLI is not installed"
  guard
  local pw
  pw=$(k get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || die "argocd-initial-admin-secret not found"
  k port-forward svc/argocd-server -n argocd 18443:443 >"$TMP/pf.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 20); do grep -q 'Forwarding' "$TMP/pf.log" && break; sleep 1; done
  (umask 077 && ARGOCD_OPTS='' argocd login localhost:18443 --insecure --username admin --password "$pw" --config "$TMP/argocd-config" >/dev/null \
    && argocd proj role create-token hml deployer --config "$TMP/argocd-config" --insecure --server localhost:18443 --grpc-web 2>/dev/null | tr -d '\n' >"$TMP/token") || die "could not make the token"
  case "$(sm_state ARGOCD_DEPLOYER_TOKEN)" in value) die "secret $SMP/ARGOCD_DEPLOYER_TOKEN already has a value; delete the old token role first" ;; esac
  sm_put_file ARGOCD_DEPLOYER_TOKEN "$TMP/token"
  say created "secret $SMP/ARGOCD_DEPLOYER_TOKEN (never printed). Add it to Woodpecker as the secret argocd_token of the repository (Woodpecker UI > repository > Settings > Secrets)"
}

cmd_status() {
  guard
  k get applications.argoproj.io -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>&1
}

case "$CMD" in
  plan) cmd_plan ;;
  set-github-oauth) cmd_set_github_oauth ;;
  sync) cmd_sync ;;
  token) cmd_token ;;
  status) cmd_status ;;
esac
