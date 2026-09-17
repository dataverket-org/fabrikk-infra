# 001: The cluster's SOPS key is generated in-cluster and never leaves it

Accepted 2026-09-17.

**Context.** Flux's kustomize-controller decrypts SOPS files with an age key read from a Secret. The key could be made
on a laptop and copied in, or made where it is used.

**Decision.** A one-shot Job (`bootstrap/sops-age-keygen.yaml`) runs `age-keygen` inside the cluster and writes the
private key straight into `flux-system/sops-age`. Only the recipient is published. The key is never backed up and
never copied. No separate SOPS operator: kustomize-controller is the decryptor.

**Consequences.** Every encrypted file also lists the attesters' YubiKeys as recipients, so losing the cluster loses
nothing: a new cluster gets a new key and `sops updatekeys` re-encrypts for it (`bootstrap.sh` stops at that step).
Read access to Secrets in `flux-system` equals read access to every secret, so `fabrikk-readers` never gets it. Omni's
etcd backups contain the key; their encryption is the real boundary.
