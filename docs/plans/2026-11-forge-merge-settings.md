# Plan: the forge never rewrites an attested commit

Written 2026-11-11 as a handoff from the fabrikk repository (`~/kode/fabrikk`), where the need was found. Nothing
here is built. The work is for an agent in this repository: fabrikk's forge token is scoped to its own pull
requests and must stay that way, and this repository's token is the one that may change a repository's settings
(decision 005).

## What happened

fabrikk attests a work item with a signed tag, `attestation/<commit>`, on the commit that was verified, reviewed
and approved. On 2026-11-11 its first product slice was merged as pull request
[dataverket/fabrikk#30](https://git.dataverket.org/dataverket/fabrikk/pulls/30):

- The attested, signed commit was `b8dfb8170a0708c6868e710d306ac057cdc26662`.
- Its branch was behind `main` by one merge commit. The forge rebased it at 18:28:09 UTC, which made a new commit,
  `f82010035d3d1d57ab33ec677633085e76745fa5`: the same tree, another hash, committed by the forge as the user and
  unsigned.
- That commit is what merged (`da96ddbc32e41557002d8bf95278c95f577e40ae`). The attested commit is not on `main`,
  and what is there carries neither its signature nor its tag.

A rebase on the forge can never keep an attestation: it makes a new commit, and the forge does not hold the
attester's key. fabrikk now notices after the fact (its factory compares the head the forge merged with the
attested commit and stops for a person). What is missing is prevention, and that is a repository setting.

## What is wanted

For `dataverket/fabrikk`, and for any later repository whose pull requests carry attestations:

| Setting (Forgejo API name, `EditRepoOption`) | Value | Why |
|---|---|---|
| `allow_merge_commits` | `true` | A merge commit leaves the branch's commits as they are |
| `default_merge_style` | `merge` | The button a person presses without choosing |
| `allow_rebase` | `false` | Rebase-merging makes new commits |
| `allow_rebase_explicit` | `false` | Rebase with a merge commit makes new commits too |
| `allow_squash_merge` | `false` | A squash is a new commit |
| `allow_rebase_update` | `false` | "Update branch by rebase" rewrites the pull request's head before the merge |

The names were read from this forge's own schema on 2026-11-11 (`https://git.dataverket.org/swagger.v1.json`,
definition `EditRepoOption`). The same definition has `allow_fast_forward_only_merge`, `allow_manual_merge`,
`default_update_style` (`rebase` or `merge`) and `default_delete_branch_after_merge`; the first three are for the
person to decide (see "Open"), the last is fine as it is.

Two branch-protection settings interact. fabrikk's token cannot read them, so check what `main` has today
(`branch_protection_list`):

- `blockOnOutdatedBranch` has to be off for `main`. On, it forces "Update branch" before every merge that follows
  another, which moves the head off the attested commit.
- `requireSignedCommits` cannot be on for `main` yet: the forge's own merge commits are unsigned.

## What to build

1. **A method on the forge model that converges a repository's pull-request settings.** Today `@dataverket/forgejo`
   (2026.11.09.1) has `repo_ensure` (visibility, description, default branch, wiki, issues, pull requests, releases)
   and `repo_units_ensure` (Actions, packages, projects). Neither reaches the merge settings, and the `repo-<owner>-
   <name>` record does not hold them, so they cannot even be read through the model.
   - Shape it like `repo_units_ensure` (`units.ts` in the extension's source): only the fields given are sent, it
     reads first and writes only when one differs, it reports `created`/`updated`/`unchanged`, and a change that
     did not apply is an error.
   - Record the settings it read, so the state can be queried afterwards.
   - The extension's source is `~/kode/swamp-extensions/forgejo`, and it is published. By decision 007 the method
     stays general: it takes the settings as inputs and holds no opinion on their values. Building it there means
     working in that repository and publishing a version; whether that is done in this piece of work, or as a local
     `export const extension` here first, is the person's call.
2. **The policy, here.** The values in the table are this organisation's rule, so they live in this repository: a
   workflow or a documented call that applies them to `dataverket/fabrikk`, run as the person at the terminal
   (decision 033). Verify first: read the repository's current settings and show them before changing anything.
3. **Make `validate-attestation` a required check on `main`, once it has reported on a real pull request.** The
   settings above stop the forge from rewriting a commit at merge. They do not stop "Update branch by merge" or a
   push after attesting; either leaves a head with no attestation tag, and only the check refuses that. It has
   never run on a real runner (pull requests 29 to 31 in fabrikk are the first it could have run on), so look at
   what it reported there first and read the context name the forge shows. Then `branch_protection_ensure` for
   `main` with `enableStatusCheck` and that context. fabrikk's own guide describes the call, but its token gets 403
   on branch protection, so it is this repository's to run.
4. **Tell fabrikk when it is done.** `contributing/forge.md` in fabrikk has a section "Merge a work item's pull
   request" that today says a repository administrator sets the settings by hand, and a section on the required
   check that tells the reader to run it from fabrikk. Both should then point here. That is a change in fabrikk,
   through a pull request there.

## Done when

- The forge model can read and converge the six settings, with tests in the style of the extension's other files.
- `dataverket/fabrikk` has the values in the table, shown by a read through the model after the write.
- A pull request in `dataverket/fabrikk` offers only "Create merge commit", and no button updates its branch by
  rebase. Check it on a throwaway pull request, not on one that carries an attestation.
- `validate-attestation` is a required check on `main`, or the reason it cannot be yet is written here.

## Not part of this

- fabrikk's token gets no new scope, and no model instance in fabrikk gains this method's reach. The boundary is the
  point: a workbench that runs an agent can open a pull request and nothing more.
- A pull request that is not a work item (a change to the factory itself) carries no attestation, so a required
  check refuses it. How such a change merges once the check is required is fabrikk's to decide, and is not decided.

## Open

- **`allow_rebase_update` off also removes a convenience.** A branch that conflicts with `main` then has to be
  rebased on the workbench, which is what fabrikk wants: the new commit goes back through its factory. Say so to the
  person before turning it off.
- **`default_update_style` and "Update branch by merge".** Updating by merge keeps the attested commit but still
  moves the head, so the attestation no longer matches the pull request. The API has no switch that removes that
  button alone; whether to leave it and rely on fabrikk's check is undecided.
- **`allow_fast_forward_only_merge` and `allow_manual_merge`.** Fast-forward keeps commits intact and would be safe;
  a manual merge marks a pull request merged without the forge doing it. Neither was asked for.
- **Other repositories.** Only `dataverket/fabrikk` attests today. Whether the same values become the default for
  every repository in the organisation is not decided.
