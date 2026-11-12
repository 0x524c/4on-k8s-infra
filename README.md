# 4ON HML deploy tree

Deployment configuration of the HML environment on EKS (cluster `hyperswitch-hml`): Kustomize base and overlays for the
Hyperswitch stack, the Argo CD project and applications, Woodpecker's values and workflows. No source code, no Secret objects.
Argo CD applies `apps/hml/*`; the Woodpecker workflows in `.woodpecker/` validate this tree and ask Argo CD to sync.

This is a git repository of its own (origin: the private GitHub repository named in `apps/hml/argocd-apps`), kept in the 4ON project
folder as `4on-k8s-infra/` and ignored by the main repository. `scripts/publish.sh` validates, commits and pushes it.
`apps/base/hyperswitch` is rendered from the HML chart of the main repository by `scripts/render-base.sh`.
# 4on-k8s-infra
# 4on-k8s-infra
