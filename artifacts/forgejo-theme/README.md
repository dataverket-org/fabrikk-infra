# The forgejo-theme artifact

The Dataverket theme for the forge at `git.dataverket.org`: four ConfigMaps that `apps/forgejo/release.yaml` mounts
over Forgejo's custom path. `forgejo-theme-css`, `-img` and `-fonts` are the theme repository's `public/assets/*` as
committed; `forgejo-theme-locale` is Forgejo's en-US locale with the landing page's copy patched in. Rendered here in
the factory (decision 028), pushed by `push.sh` into zot as `platform/forgejo-theme-config`, and applied by the
Kustomization in `apps/forgejo/theme.yaml`. Nothing in the cluster builds or writes any of it.

## Contents

| File | What |
|---|---|
| `recipe/source.env` | The theme repository and the commit of it that is built |
| `recipe/kustomization.yaml` | The four ConfigMaps, by file; `render.sh` runs it inside a checkout of the theme |
| `render.sh` | Writes `rendered/`; `--check` proves it true to the recipe and to the chart that runs |
| `rendered/` | The four ConfigMaps, one file each, and the kustomization that lists them. Written by `render.sh`, never by hand; this is the artifact |
| `push.sh` | Pushes `rendered/` into zot, signs it when the site key exists, tags it `current` |

## The locale without a Forgejo binary

The landing page's copy lives in Forgejo's locale strings, and Forgejo replaces its whole en-US file with ours, so
ours must be the one of the release that runs, with nine keys of `[startpage]` changed. `render.sh` reads the
release from the chart, the `appVersion` of the chart tag in `apps/forgejo/repo.yaml`, fetches
`options/locale/locale_en-US.ini` from Forgejo's source at that tag, and patches it with the theme's own
`locale_from()`. Forgejo embeds `options/` from its source tree as it is: on 2026-10-15 the file at `v15.0.7` and
the one `forgejo embedded extract` gave in the running pod had the same sha256, and the render's result matched the
ConfigMap the forge then served, byte for byte.

This replaced a CronJob that did the same in the cluster every fifteen minutes, as root, from the theme's `main`.

## Ship a change

```sh
$EDITOR artifacts/forgejo-theme/recipe/source.env     # a new theme commit
artifacts/forgejo-theme/render.sh                     # rewrites rendered/; review its diff
git commit ...                                        # the revision annotation names the commit, so commit first
artifacts/forgejo-theme/push.sh                       # PIN and one YubiKey touch for the fabrikk-ci credential
```

A Forgejo upgrade is the same without the first line: once the chart tag in `apps/forgejo/repo.yaml` moves,
`render.sh --check` fails until `rendered/` carries that release's locale, and `push.sh` refuses to ship. Render,
commit and push before the chart reaches the cluster, or in the same breath: a locale from the wrong release drops
or misnames the strings that changed.

CSS, images and fonts reach visitors within a reconcile, since a mounted ConfigMap is synced into the running pod.
The locale is read once at startup, so a copy change needs a restart of the forgejo pod.

## Rebuild

zot comes back empty (`docs/storage.md`, "Rebuild from git"), so run `push.sh` again from the checkout. Until then
the forge runs on Forgejo's built-in assets and copy: the four volumes are optional (`apps/forgejo/README.md`). There
is no from-git fallback, since nothing here is needed to bring anything else back; `kubectl apply -k
artifacts/forgejo-theme/rendered` is one, by hand, if the theme is wanted before zot serves.
