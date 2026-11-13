#!/usr/bin/env bash
# Author: RL Robotics
# E-mail: rogerio@rlrobotics.com.br
# Licence: private use only, for RL Robotics and 4ON members.
#
# Tests of the deploy tree's scripts: validate.sh (it passes on the tree and each isolation rule fails on a mutated copy),
# render-base.sh (the drift check), bump-image.sh, and hml-platform.sh (plan and apply against fake aws, kubectl and helm that
# log every call; no AWS account or cluster is used).
#
#   bash 4on-k8s-infra/scripts/test-k8s-infra.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=$(cd "$HERE/.." && pwd)
REAL_KUBECTL=$(command -v kubectl >/dev/null 2>&1 && PATH=/usr/bin:/usr/local/bin command -v kubectl || echo /usr/bin/kubectl)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/k8s-infra-test.XXXXXX")
trap 'case "$SCRATCH" in "${TMPDIR:-/tmp}"/k8s-infra-test.?*) rm -rf -- "$SCRATCH" ;; esac' EXIT
passed=0 failed=0
check() { # <name> <bad text, empty when the test passed> [output]
  if [ -z "$2" ]; then passed=$((passed + 1)); printf 'pass  %s\n' "$1"
  else failed=$((failed + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; [ -z "${3:-}" ] || tail -n 12 <<<"$3" | sed 's/^/      | /'; fi
}
copy_tree() { rm -rf "$SCRATCH/t" && mkdir -p "$SCRATCH/t" && cp -r "$TREE/apps" "$TREE/components" "$TREE/scripts" "$SCRATCH/t/"; }
validate() { K8S_INFRA_TREE=$SCRATCH/t VALIDATE_SKIP_SCHEMA=1 bash "$TREE/scripts/validate.sh" 2>&1 || true; }

# ----------------------------------------------------------------------------- validate.sh

out=$(VALIDATE_SKIP_SCHEMA=1 bash "$TREE/scripts/validate.sh" 2>&1) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[rc $rc] "
grep -q '^validate: all checks passed' <<<"$out" || bad+="[no closing line] "
grep -q '^ok       with the translator component switched on the overlay adds 4 objects' <<<"$out" || bad+="[translator component not built] "
grep -q '^ok       the base and the translator component equal a fresh render of the chart' <<<"$out" || bad+="[render check not run] "
grep -q '^ok       the container logs go to SigNoz ' <<<"$out" || bad+="[SigNoz check not run] "
grep -q '^ok       apps/hml/signoz-network builds' <<<"$out" || bad+="[signoz-network not built] "
check "validate.sh passes on the tree: overlays and the translator component build, the Jobs are hooks, the isolation rules hold, the base equals the chart" "$bad" "$out"

mutate() { # <name> <expected message> <shell snippet run in the copy's root>
  copy_tree
  (cd "$SCRATCH/t" && eval "$3")
  out=$(validate)
  bad=""
  grep -q "^FAILED   .*$2" <<<"$out" || bad+="[not refused: $(grep '^FAILED' <<<"$out" | head -n 1)] "
  grep -q '^validate: .* check(s) failed' <<<"$out" || bad+="[no failure line] "
  check "validate.sh refuses $1" "$bad" "$out"
}
mutate "a Secret object in the tree" "a Secret object is in the tree" \
  "printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: x\n' >apps/base/hyperswitch/secret.yaml && printf '  - secret.yaml\n' >>apps/base/hyperswitch/kustomization.yaml"
mutate "an image from a production ECR repository" "ECR images outside HML's own repositories" \
  "printf -- '---\napiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  containers:\n    - name: c\n      image: 405712027313.dkr.ecr.sa-east-1.amazonaws.com/hyperswitch-router:1\n' >apps/base/hyperswitch/pod.yaml && printf '  - pod.yaml\n' >>apps/base/hyperswitch/kustomization.yaml"
mutate "a source-code file" "a source-code file is in the tree" "echo 'fn main() {}' >apps/base/main.rs"
mutate "a private key" "a private key or an access key id is in the tree" "echo '-----BEGIN OPENSSH PRIVATE KEY-----' >apps/hml/note.txt"
mutate "a host under rlrobotics.com.br" "a host under rlrobotics.com.br is named in the tree" "echo 'host: x.rlrobotics.com.br' >apps/hml/note.yaml"
mutate "a Job that is not an Argo CD hook" "Jobs that are not Argo CD sync hooks" \
  "sed -i '/^patches:/,/kind: Job/d' apps/hml/hyperswitch/kustomization.yaml"
mutate "an overlay without the Service postgres" "the overlay must define exactly one Service named postgres" \
  "sed -i '/postgres-rds.yaml/d' apps/hml/hyperswitch/kustomization.yaml"
mutate "a second deploy repository" "the Argo CD project and applications name 2 repositories" \
  "sed -i '0,/git@github.com:0x524c\\/4on-k8s-infra.git/s//git@github.com:0x524c\\/other.git/' apps/hml/argocd-apps/applications.yaml"
mutate "a SigNoz chart that is not pinned to a version" "must pin the chart to an exact version" \
  "sed -i 's/targetRevision: 0.149.0/targetRevision: \"*\"/' apps/hml/argocd-apps/applications.yaml"
mutate "an exposed SigNoz UI" "the SigNoz UI must stay unexposed" \
  "sed -i 's/^    type: ClusterIP/    type: LoadBalancer/' apps/base/signoz/values.yaml"
mutate "a log agent that collects another namespace" "the log agent must collect the namespace hyperswitch only" \
  "sed -i 's/^        - hyperswitch\$/        - kube-system/' apps/base/signoz/k8s-infra-values.yaml"
mutate "a log agent that sends out of the cluster" "the log agent must send to the SigNoz collector of this cluster" \
  "sed -i 's/^otelCollectorEndpoint: .*/otelCollectorEndpoint: ingest.eu.signoz.cloud:443/' apps/base/signoz/k8s-infra-values.yaml"
mutate "Fluent Bit back in the tree" "Fluent Bit or a CloudWatch log output is still in the tree" \
  "printf '# fluent-bit\n' >apps/hml/signoz/fluent.yaml"

# ----------------------------------------------------------------------------- render-base.sh

sed 's/^  tag: .*/&/' "$TREE/../code/deploy/hyperswitch/hml/chart/values-hml.yaml" | sed '0,/hyperswitch-hml-router/{n;s/tag: .*/tag: drifted-tag/}' >"$SCRATCH/values-drift.yaml"
tree_sum() { (cd "$TREE" && find apps components -type f | sort | xargs sha256sum | sha256sum); }
tree_before=$(tree_sum)
out=$(HML_CHART_VALUES=$SCRATCH/values-drift.yaml bash "$TREE/scripts/render-base.sh" --check 2>&1) && rc=0 || rc=$?
bad=""
[ "$rc" != 0 ] || bad+="[a drifted render passed] "
grep -q '^FAILED   the committed base differs from a fresh render of the chart' <<<"$out" || bad+="[no drift message] "
[ "$(tree_sum)" = "$tree_before" ] || bad+="[the check changed the tree] "
check "render-base.sh --check fails when the chart renders differently from the committed base, and writes nothing" "$bad" "$out"

# ----------------------------------------------------------------------------- bump-image.sh

copy_tree
export K8S_INFRA_OVERLAY=$SCRATCH/t/apps/hml/hyperswitch
out=$(bash "$TREE/scripts/bump-image.sh" router 2024.01.10.0-9999-gabcdef123 2>&1) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[rc $rc: $out] "
grep -A1 'hyperswitch-hml-router$' "$K8S_INFRA_OVERLAY/kustomization.yaml" | grep -q 'newTag: 2024.01.10.0-9999-gabcdef123' || bad+="[router tag not set] "
grep -A1 'hyperswitch-hml-scheduler$' "$K8S_INFRA_OVERLAY/kustomization.yaml" | grep -q 'newTag: 2024.01.10.0-6318-ge65f9eea4' || bad+="[scheduler tag changed] "
bash "$TREE/scripts/bump-image.sh" nonsense x >/dev/null 2>&1 && bad+="[a bad image name passed] "
bash "$TREE/scripts/bump-image.sh" router 'bad tag;rm' >/dev/null 2>&1 && bad+="[a bad tag passed] "
unset K8S_INFRA_OVERLAY
check "bump-image.sh sets one image tag of the overlay, leaves the others, and refuses an unknown image or a malformed tag" "$bad" "$out"

# ----------------------------------------------------------------------------- hml-platform.sh against fakes

FAKE=$SCRATCH/fake
mkdir -p "$FAKE/bin" "$FAKE/state/secrets"
for t in aws kubectl helm; do
  cat >"$FAKE/bin/$t" <<EOF
#!/usr/bin/env bash
echo "\$(basename \$0) \$*" >>"$FAKE/calls.log"
source "$FAKE/$t.sh"
EOF
  chmod +x "$FAKE/bin/$t"
done
cat >"$FAKE/aws.sh" <<EOF
a="\$*"
case "\$a" in
  *"sts get-caller-identity"*) echo 405712027313 ;;
  *"eks describe-cluster"*) echo ACTIVE ;;
  *"rds describe-db-instances"*) echo hyperswitch-hml-db.abc123xyz.sa-east-1.rds.amazonaws.com ;;
  *"eks update-kubeconfig"*) k=\${a##*--kubeconfig }; echo "apiVersion: v1" >"\${k%% *}" ;;
  *"secretsmanager get-secret-value"*) id=\$(sed -E 's/.*--secret-id hyperswitch-hml\/([A-Z_]+).*/\1/' <<<"\$a"); f="$FAKE/state/secrets/\$id"
     if [ -f "\$f" ]; then cat "\$f"; else echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation" >&2; exit 254; fi ;;
  *"secretsmanager create-secret"*|*"secretsmanager put-secret-value"*)
     id=\$(sed -E 's/.*(--name|--secret-id) hyperswitch-hml\/([A-Z_]+).*/\2/' <<<"\$a"); src=\$(sed -E 's/.*--secret-string file:\/\/([^ ]+).*/\1/' <<<"\$a")
     cp "\$src" "$FAKE/state/secrets/\$id"; echo "WRITE \$id mode \$(stat -c %a "\$src")" >>"$FAKE/writes.log" ;;
esac
EOF
cat >"$FAKE/kubectl.sh" <<EOF
a="\$*"
case "\$a" in
  *"kustomize "*) exec $REAL_KUBECTL kustomize "\${a##*kustomize }" ;;
  *"get service signoz"*) [ -f "$FAKE/state/signoz-synced" ] || exit 1 ;;
  *"get namespace"*) exit 1 ;;
  *"create secret generic"*) echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"fake"},"data":{}}' ;;
  *" apply "*) cat >/dev/null ;;
esac
EOF
cat >"$FAKE/helm.sh" <<'EOF'
case "$*" in
  *" upgrade "*) printf 'STATUS: deployed\nREVISION: 1\n' ;;
esac
EOF
plat() { PATH="$FAKE/bin:$PATH" AWS_PROFILE=rlr bash "$TREE/scripts/hml-platform.sh" "$@" 2>&1; }

: >"$FAKE/calls.log"; : >"$FAKE/writes.log"
out=$(plat) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[rc $rc] "
grep -q '^ok        helm template of argo-cd 10.18.0' <<<"$out" || bad+="[no helm template line] "
grep -q '^plan      would install the Helm release argocd (chart 10.18.0)' <<<"$out" || bad+="[no argo install plan] "
grep -q '^plan      would generate an ed25519 key pair' <<<"$out" || bad+="[no key plan] "
grep -q '^waiting   the GitHub OAuth app of Woodpecker' <<<"$out" || bad+="[OAuth not waiting] "
grep -q '^plan      would apply the Argo CD project hml and the applications hyperswitch-hml, woodpecker, signoz and signoz-k8s-infra' <<<"$out" || bad+="[no applications plan] "
grep -q '^hml-platform: plan only\. Apply it with: bash .*/hml-platform.sh --apply$' <<<"$out" || bad+="[no closing line] "
[ ! -s "$FAKE/writes.log" ] || bad+="[Secrets Manager writes in a plan] "
grep -E ' (upgrade|create|apply|patch|delete) ' "$FAKE/calls.log" | grep -v 'kubectl .*kustomize' | grep -q . && bad+="[a write call in a plan: $(grep -E ' (upgrade|create|apply|patch|delete) ' "$FAKE/calls.log" | head -n 1)] "
grep -q 'hyperswitch/' "$FAKE/calls.log" && bad+="[a production secret path] "
check "hml-platform.sh plan: Argo CD install, deploy key, namespaces, Woodpecker secrets (OAuth waiting) and applications each as a plan line; no helm upgrade, no kubectl write, no Secrets Manager write" "$bad" "$out"

out=$(plat --apply) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[rc $rc: $(grep '^FAILED' <<<"$out")] "
grep -q 'helm --kubeconfig .* upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.18.0 --namespace argocd --create-namespace' "$FAKE/calls.log" || bad+="[helm upgrade not pinned to 10.18.0] "
[ -s "$FAKE/state/secrets/ARGOCD_DEPLOY_KEY" ] && grep -q 'BEGIN OPENSSH PRIVATE KEY' "$FAKE/state/secrets/ARGOCD_DEPLOY_KEY" || bad+="[deploy key not stored] "
[ -s "$FAKE/state/secrets/WOODPECKER_AGENT_SECRET" ] && [[ "$(cat "$FAKE/state/secrets/WOODPECKER_AGENT_SECRET")" =~ ^[0-9a-f]{64}$ ]] || bad+="[agent secret not stored as 64 hex] "
grep -q '^ssh-ed25519 ' <<<"$out" || bad+="[public key not printed] "
grep -q 'BEGIN OPENSSH PRIVATE KEY' <<<"$out" && bad+="[the private key reached the output] "
grep -qE '^WRITE [A-Z_]+ mode [0-6][0]{2}$' "$FAKE/writes.log" || bad+="[a Secrets Manager source file not mode 600/400: $(cat "$FAKE/writes.log")] "
grep -q 'WOODPECKER_GITHUB' "$FAKE/writes.log" && bad+="[the OAuth values were invented] "
grep -q '^waiting   the GitHub OAuth app of Woodpecker' <<<"$out" || bad+="[OAuth not waiting] "
grep -q 'create namespace' "$FAKE/calls.log" || bad+="[namespaces not created] "
grep -q 'apply --server-side --force-conflicts --field-manager=hml-platform -f -' "$FAKE/calls.log" || bad+="[no server-side apply] "
grep -q '^hml-platform: done\. Next: push the tree to git@github.com:0x524c/4on-k8s-infra.git' <<<"$out" || bad+="[closing line] "
[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'hml-platform.*' 2>/dev/null | head -n 1)" ] || bad+="[scratch left] "
check "hml-platform.sh --apply: Argo CD installed from the pinned chart, the deploy key and the agent secret generated once into Secrets Manager from mode-600 files, the public key printed and the private one never, the OAuth values left for the owner, Secrets applied server-side" "$bad" "$out"

before=$(cat "$FAKE/state/secrets/ARGOCD_DEPLOY_KEY")
out=$(plat --apply) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[rc $rc] "
[ "$(cat "$FAKE/state/secrets/ARGOCD_DEPLOY_KEY")" = "$before" ] || bad+="[the deploy key was overwritten] "
grep -q '^exists    secret hyperswitch-hml/ARGOCD_DEPLOY_KEY (has a value; never overwritten)' <<<"$out" || bad+="[no exists line] "
check "hml-platform.sh --apply again: the stored deploy key and agent secret are kept, never overwritten" "$bad" "$out"

copy_tree
out=$(cd "$SCRATCH/t" && PATH="$FAKE/bin:$PATH" AWS_PROFILE=rlr bash "$SCRATCH/t/scripts/hml-platform.sh" db-host 2>&1) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[rc $rc: $out] "
grep -q '^  externalName: hyperswitch-hml-db.abc123xyz.sa-east-1.rds.amazonaws.com$' "$SCRATCH/t/apps/hml/hyperswitch/postgres-rds.yaml" || bad+="[endpoint not written] "
grep -q 'rds describe-db-instances --db-instance-identifier hyperswitch-hml-db ' "$FAKE/calls.log" || bad+="[not HML's own instance] "
grep -q 'rds describe-db-instances --db-instance-identifier hyperswitch-db' "$FAKE/calls.log" && bad+="[production instance named] "
out2=$(K8S_INFRA_TREE=$SCRATCH/t VALIDATE_SKIP_SCHEMA=1 bash "$TREE/scripts/validate.sh" 2>&1 || true)
grep -q '^ok       the Service postgres points at hyperswitch-hml-db.abc123xyz' <<<"$out2" || bad+="[validate does not accept the written endpoint] "
check "hml-platform.sh db-host: writes the endpoint of HML's own RDS instance (never production's) into the overlay's Service postgres, which validate.sh then accepts without the placeholder note" "$bad" "$out"

: >"$FAKE/calls.log"
out=$(plat signoz) && rc=0 || rc=$?
bad=""
[ "$rc" != 0 ] || bad+="[opened before the application was synced] "
grep -q '^FAILED    no service signoz in namespace signoz: sync it first' <<<"$out" || bad+="[no sync-first message: $out] "
grep -q 'port-forward' "$FAKE/calls.log" && bad+="[a port-forward before the application was synced] "
touch "$FAKE/state/signoz-synced"
out=$(plat signoz) && rc=0 || rc=$?
[ "$rc" = 0 ] || bad+="[rc $rc: $out] "
grep -q '^ok        SigNoz is at http://localhost:18080 until Ctrl+C closes this command' <<<"$out" || bad+="[no URL line] "
grep -q 'kubectl .*port-forward svc/signoz -n signoz 18080:8080' "$FAKE/calls.log" || bad+="[no port-forward of svc/signoz] "
grep -E ' (apply|patch|delete|create|edit) ' "$FAKE/calls.log" | grep -q . && bad+="[a write call] "
check "hml-platform.sh signoz: refuses until the Application is synced, then forwards localhost:18080 to the service signoz (read-only, no write call)" "$bad"

# ----------------------------------------------------------------------------- publish.sh

git init --quiet --bare -b main "$SCRATCH/remote.git"
rm -rf "$SCRATCH/repo" && mkdir -p "$SCRATCH/repo" && cp -r "$TREE/apps" "$TREE/components" "$TREE/scripts" "$TREE/.woodpecker" "$TREE/README.md" "$SCRATCH/repo/"
git -C "$SCRATCH/repo" init --quiet -b main && git -C "$SCRATCH/repo" remote add origin "$SCRATCH/remote.git"
git -C "$SCRATCH/repo" config user.name test && git -C "$SCRATCH/repo" config user.email test@example.invalid
pub() { K8S_INFRA_REMOTE=$SCRATCH/remote.git bash "$SCRATCH/repo/scripts/publish.sh" "$@" 2>&1; }
out=$(pub) && rc=0 || rc=$?
bad=""
[ "$rc" = 0 ] || bad+="[plan rc $rc: $out] "
grep -q '^plan      would commit the changes above' <<<"$out" || bad+="[no plan line] "
[ -z "$(git --git-dir="$SCRATCH/remote.git" rev-list --all 2>/dev/null)" ] || bad+="[the plan pushed] "
[ -z "$(git -C "$SCRATCH/repo" rev-parse -q --verify HEAD || true)" ] || bad+="[the plan committed] "
out=$(pub --apply) && rc=0 || rc=$?
[ "$rc" = 0 ] || bad+="[apply rc $rc: $out] "
[ "$(git --git-dir="$SCRATCH/remote.git" rev-list --count main 2>/dev/null)" = 1 ] || bad+="[not exactly one commit] "
[ "$(git --git-dir="$SCRATCH/remote.git" log -1 --format=%s main)" = "deploy: update the HML deploy tree" ] || bad+="[commit message] "
files=$(git --git-dir="$SCRATCH/remote.git" ls-tree -r --name-only main)
for f in apps/hml/hyperswitch/kustomization.yaml apps/hml/argocd-apps/applications.yaml .woodpecker/validate.yaml .woodpecker/deploy-hml.yaml scripts/validate.sh README.md; do
  grep -qx "$f" <<<"$files" || bad+="[$f missing] "
done
grep -qE '\.rs$|Secret' <<<"$files" && bad+="[source or Secret file published] "
out=$(pub --apply) || bad+="[second apply failed] "
grep -q '^ok        nothing to publish' <<<"$out" || bad+="[second run not a no-op: $out] "
[ "$(git --git-dir="$SCRATCH/remote.git" rev-list --count main)" = 1 ] || bad+="[a commit made by a no-op] "
echo "# a later change" >>"$SCRATCH/repo/apps/hml/hyperswitch/namespace.yaml"
out=$(pub --apply) && rc=0 || rc=$?
[ "$(git --git-dir="$SCRATCH/remote.git" rev-list --count main)" = 2 ] || bad+="[a changed file did not become a second commit: $out] "
git -C "$SCRATCH/repo" remote set-url origin git@github.com:someone/else.git
out=$(K8S_INFRA_REMOTE='' bash "$SCRATCH/repo/scripts/publish.sh" --apply 2>&1) && bad+="[a wrong origin passed] "
grep -q '^FAILED   origin is git@github.com:someone/else.git, not git@github.com:0x524c/4on-k8s-infra.git' <<<"$out" || bad+="[no wrong-origin message: $out] "
check "publish.sh: the plan commits and pushes nothing; --apply commits with a one-line message and pushes the tree and the workflows; a second run publishes nothing; a change becomes one more commit; an origin other than the repository named in applications.yaml is refused" "$bad" "$out"

echo
echo "test-k8s-infra: $passed passed, $failed failed"
[ "$failed" = 0 ]
