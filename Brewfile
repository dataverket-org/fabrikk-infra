# Everything bootstrap.sh and admin/*.sh need, for Homebrew on macOS and Linux:
#   brew bundle --file admin/Brewfile
# Supported: Apple silicon, Linux x86_64 and Linux arm64; every entry has a bottle or a prebuilt binary for all
# three. Intel Macs are not supported. Names to know: kubectl is kubernetes-cli, and flux must come from the fluxcd
# tap, since core "flux" is an unrelated project.
tap "siderolabs/tap"
tap "fluxcd/tap"

brew "siderolabs/tap/omnictl"
brew "talosctl"
brew "kubernetes-cli"
brew "kubectl-cnpg"             # kubectl cnpg: promote, status and backup for CloudNativePG clusters
brew "openstackclient"
brew "fluxcd/tap/flux"
brew "cosign"                   # signs an artifact at push.sh time with the site key in vaults/operator/<site>/
brew "helm"                     # inflates a chart when an artifact recipe is rendered; never run against a cluster
brew "sops"
brew "age"
brew "age-plugin-yubikey"
brew "jq"
brew "yq"
brew "git"
brew "shellcheck"
brew "gnupg"                    # gpg reads the expiry out of the Omni login key
brew "proton-pass-cli"          # pass-cli: the web logins behind tier 3 live in Proton Pass
