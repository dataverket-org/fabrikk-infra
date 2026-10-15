# The forge

`git.dataverket.org`: Forgejo from the upstream chart (`release.yaml`, `repo.yaml`), its database (`postgres.yaml`,
`backup.yaml`, `docs/storage.md`, `backup/README.md`), the Dataverket theme, and the actions org the forge keeps as a
mirror (decisions 022 and 023). Its admin, mailer and OAuth Secrets are `*.enc.yaml` here since 2026-10-05.

## Settings in the release

- `DEFAULT_ACTIONS_URL: self`: a workflow's `uses: actions/<name>` resolves on this forge's actions org, not on
  data.forgejo.org. An action from elsewhere needs its full address in the workflow.
- `SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET` and `LFS_JWT_SECRET` come from `forgejo-security.enc.yaml`. Forgejo
  generated them into `app.ini` on the volume at first start; pinned here, a restore onto an empty volume can still
  read what the database holds encrypted with them (`backup/README.md`, "Needed for any restore").
- The forge refuses basic authentication, so the admin credential is of no use over the API. Anything that needs
  a user or a token without a password runs the `forgejo` CLI inside the forgejo pod.

## The theme

Four ConfigMaps, `forgejo-theme-css`, `-img`, `-fonts` and `-locale`, rendered in the factory from the theme
repository `git.dataverket.org/dataverket/forgejo-theme` and Forgejo's own en-US locale, and delivered as the
artifact `platform/forgejo-theme-config` (`artifacts/forgejo-theme/README.md`, decision 028). `theme.yaml` is its
`OCIRepository` and Kustomization. `release.yaml` mounts the first three over Forgejo's `public/assets/{css,img,fonts}`
and the locale over `options/locale`. A theme change is a new pin in `artifacts/forgejo-theme/recipe/source.env`,
rendered and pushed; a Forgejo upgrade is the same render against the new chart, which `render.sh --check` enforces.

CSS, images and fonts are served within a reconcile, since a mounted ConfigMap is synced into the running pod.
Forgejo loads locale strings at startup, so a copy change reaches visitors after the pod's next restart, which a
person does.

The site name in the page title and header is `APP_NAME` in `release.yaml`, not a locale string; the chart's default
is "Forgejo: Beyond coding. We forge."

All four theme volumes are `optional`. A rebuilt cluster starts with an empty zot, so the forge starts on its
built-in assets and copy, and takes the theme once `artifacts/forgejo-theme/push.sh` has run again, the locale
after one restart.

## The actions mirror

`actions-mirror.yaml` is two pieces.

**The Job `actions-mirror-bootstrap`** runs once per cluster: it makes the bot user `actions-mirror` through the
`forgejo` CLI in the forgejo pod, a token for it, written straight into Secret `actions-mirror-token` and nowhere
else, and the org `actions` with the bot as owner, through the API with that token, since Forgejo has no CLI for
orgs. The token carries `write:organization`, `write:repository` and `read:organization`. A rerun while the Secret
exists is a no-op, so Flux may recreate the Job; the force annotation lets it replace an immutable Job on change.
The Role allows `exec` on the namespace's pods, since `exec` cannot be limited to one pod by name. The Job is
applied with the release, so it waits for the forge to answer. The bot's password is random and kept by nobody.

A lost Secret while the token lives is a state a person resolves: delete the token in the bot's settings on the
forge, then let the Job rerun. A second token of the same name is refused.

**The CronJob `actions-mirror`** runs daily and keeps the org a frozen copy of `code.forgejo.org/actions`,
promoted after a quarantine (decision 023). No mirror has a sync interval of its own. A repository is created here,
or synced, only when the source's newest change is `QUARANTINE_DAYS` old, read from the source repository's
`updated_at`, which moves on a push or a tag and not on the source's own mirror syncs; a sync takes every ref at
once. Nothing is deleted. The org's name, description, avatar and website follow the source org on every run; the
avatar is a few kilobytes, sent whole, and the forge keeps one copy. The log names what was promoted, with the date
of the change it carries, and what still waits; a failed Job is the signal. A person promotes early by running the
Job with `QUARANTINE_DAYS=0`. The forge's "never" timestamp, year 1, counts as long ago.

Both pods run curl's image pinned by digest as its unprivileged user; jq and kubectl are release binaries fetched
by pinned version and verified by sha256, so neither needs root or a package manager.
