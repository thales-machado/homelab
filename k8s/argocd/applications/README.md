# Argo CD Applications

One file per component, watched by the root Application
(`k8s/argocd/root.yaml`). Each one points at a directory under `k8s/platform/`
or `k8s/apps/`; the manifests themselves live there, never here.

Adding a component is a file here plus its directory. Removing one is deleting
the file: the root Application has `prune: true`, so Argo uninstalls it.

This README also keeps the directory in Git while it is empty. Argo ignores
anything that is not YAML.
