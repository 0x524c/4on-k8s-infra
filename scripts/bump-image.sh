#!/usr/bin/env bash
# Author: RL Robotics
# E-mail: rogerio@rlrobotics.com.br
# Licence: private use only, for RL Robotics and 4ON members.
#
# Sets the tag of one image of the HML overlay (apps/hml/hyperswitch/kustomization.yaml), after the image was pushed to HML's own
# ECR repository. Commit the change: the workflow `deploy-hml` then syncs the Application, or sync it by hand.
#
#   bash 4on-k8s-infra/scripts/bump-image.sh router 2024.01.10.0-6318-ge65f9eea4
#
# NAME is router, scheduler, migrate, seed, analytics-init, dashboard or saq-proxy; the tag must exist in the repository
# hyperswitch-hml-NAME (the script does not check the registry).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OVERLAY=${K8S_INFRA_OVERLAY:-$HERE/../apps/hml/hyperswitch}
NAME=${1:-}
TAG=${2:-}
case "$NAME" in router | scheduler | migrate | seed | analytics-init | dashboard | saq-proxy) ;; *)
  echo "FAILED   usage: bump-image.sh {router|scheduler|migrate|seed|analytics-init|dashboard|saq-proxy} TAG" >&2
  exit 2
  ;; esac
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || { echo "FAILED   not a valid image tag: $TAG" >&2; exit 2; }
command -v kustomize >/dev/null || { echo "FAILED   kustomize is not installed" >&2; exit 1; }
REPO=$(awk -v n="hyperswitch-hml-$NAME" '$1 == "-" && $2 == "name:" && $3 ~ ("/" n "$") {print $3}' "$OVERLAY/kustomization.yaml")
[ -n "$REPO" ] || { echo "FAILED   no image hyperswitch-hml-$NAME in $OVERLAY/kustomization.yaml" >&2; exit 1; }
(cd "$OVERLAY" && kustomize edit set image "$REPO=$REPO:$TAG")
echo "ok       $NAME -> $TAG in apps/hml/hyperswitch/kustomization.yaml"
