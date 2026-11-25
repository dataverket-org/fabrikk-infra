# Plan: the members in the `dataverket` organization, with a passkey and nothing else

Written 2026-11-25, from a conversation on 2026-11-23 that began with two spam accounts on the forge. Two goals on the
upstream's Zitadel instance, `id.dataverket.org`: the organization `dataverket` of
`docs/plans/2026-11-zitadel-github-and-dataverket-org.md` (the GitHub plan below) admits a person with a passkey and
with no password, and the eight members who are not owners are made anew in it, each keeping their account on the
forge. The owners, the chart's admin and the machine users stay in `Operators`, untouched. Nothing is applied.

This plan changes three things the GitHub plan says, listed under "What this changes in the GitHub plan". It adds no
identity provider and proves nothing about what kind of device holds a passkey; "What a passkey does not prove" says
why that is left out.

## Status, 2026-11-25

**Not started.** One thing next to it is done: the forge's local registration form is closed
(`ALLOW_ONLY_EXTERNAL_REGISTRATION`, pull request 42, applied 2026-11-23), and the two accounts made there are deleted.
That form, not Zitadel, was how they got in.

## Where we are

Read 2026-11-23 with the reader key through `zitadel-user`, `zitadel-instance`, `zitadel-org`, `zitadel-grant` and
`zitadel-settings`, and from the source of Zitadel v4.15.3 and Forgejo 15.0.12:

| Fact | Value |
|---|---|
| Organizations | One, `Operators`, which is also the default. `dataverket` does not exist |
| Login settings | The instance default, never set per organization: password allowed, registration on, external providers on, `forceMfa` off, second factors TOTP and U2F, passkeys allowed (last stored read 2026-11-08) |
| Humans | Eleven: two owners, the chart's admin, eight members. One more member than when the GitHub plan was written |
| Roles | `IAM_OWNER`: both owners, the chart's admin, `iam-admin`. `ORG_OWNER`: one owner, the chart's admin, `iam-admin`. The eight members hold no instance role, no organization role and no project grant |
| How the eight log in | Five with a passkey (one or two each), two with a password and nothing else, one with a password and TOTP |
| Login names | `loginNameIncludesDomain` is false: a username is unique in the whole instance, and each person's username is their address |
| Moving a user | Not possible. No API moves a user between organizations (zitadel issue 8835, open), the v1 import carries no passkey, and the owner is stamped on every event of the user, so a change in the database is a change to the event log |
| Forgejo | Matches a login on the `sub` claim, which is Zitadel's numeric user id: first against the account's sign-in name, then against its linked logins. A new Zitadel account is a stranger to it |
| Zulip, zot | Match on the address (`artifacts/zulip/README.md`, `artifacts/zot/configmap.yaml`): a new Zitadel account with the same address is the same person |
| Kubernetes, incus | Not read yet (M0) |
| Creating a user | `AddHumanUser` and `CreateUser` take an optional `user_id`: the one who creates an account can choose its id. `ensureHuman` in `@dataverket/zitadel/user` has no such argument |

## What a passkey does not prove

The wish behind this plan was that no LLM agent registers. A passkey does not grant it, and the plan does not claim
it does.

- Zitadel asks for no attestation when a passkey is made (`internal/webauthn/webauthn.go`, `PreferNoAttestation`), so
  it cannot tell a YubiKey from a passkey in a password manager or one a scripted browser made up. The request to
  restrict devices is zitadel issue 12929, open and unanswered.
- An Apple passkey carries no attestation on a device nobody manages, so "a YubiKey or Touch ID" cannot be proven by
  any server. Only "a security key from these makers" can.
- What keeps a stranger's agent out is that nobody can register: an operator makes the account and mails the link.
  With registration closed, attestation adds nothing against strangers. It would only say something about a
  member's own device, and a member can hand an agent a forge token or an SSH key whatever the login demands.

So: closed registration and a passkey now; attestation is under "Not in this plan".

## What was weighed

| Way | Why not, or why |
|---|---|
| Leave the members in `Operators` | The GitHub plan's proposal (its C4). Then `Operators` keeps passwords for as long as one member has one, and the organization that holds the owners is the one with the weakest login |
| Move them | Zitadel cannot |
| Delete and import with the old id | The import carries password and TOTP, never a passkey, and whether a deleted user's id is accepted again is unknown. The old account has to be gone before the new one exists, so there is no way back |
| Rewrite the owner in the event log | Unsupported, and on the instance every other login depends on |
| Password plus a security key for everyone, in one organization | Forces the three without a passkey to enrol at their next login and still leaves a password on every account |
| **Make each member anew in `dataverket`, and point their forge account at the new id** | Chosen. The old account stays, renamed and deactivated, until the new one works, so every step has a way back |

## The shape

| Organization | Holds | Login settings |
|---|---|---|
| The instance default | Applies to `Operators`: the two owners, the chart's admin, the machine users | As the GitHub plan has it: registration off, external providers off. **The password stays allowed**, since the floor (`bin/zitadel-floor`) is the chart admin's password |
| `dataverket` | The eight members, and everyone after them | Its own: `allowUsernamePassword` false, passkeys allowed, no second factor to choose. Registration and external providers: question 1 |

| Account | Kind | Stays or moves |
|---|---|---|
| `beddari`, `Eskpil` on the forge | The two owners | Stay in `Operators`, with their passkeys and their forge links |
| The chart's admin | Human, password only | Stays; it is the floor |
| `iam-admin`, `fabrikk-infra-beddari-reader`, `fabrikk-infra-beddari-operator` | Machine | Stay |
| `bt`, `larssolem` on the forge | Members with a password only | Move first: they have no passkey to lose |
| `km` | Member with a password and TOTP | Moves; the TOTP is not carried |
| `elzapp`, `Chrisunes`, `lstrandos`, `MindTooth` | Members with a passkey | Move; each makes a new passkey |
| The eighth member | A passkey, and no forge account found under their Zitadel address | Moves; M0 finds out whether a forge account exists under another address |

People are named here by their forge login, which is public; `zitadel-user list` gives the Zitadel name of each.

## How one person is moved

One person per run, when they have said they are ready, as the passkey link is sent today.

| # | What | With | Way back |
|---|---|---|---|
| 1 | The old account's username and address get a `-temp` mark, the address marked verified so that no mail goes to it | `zitadel-user update` | The same call with the old values |
| 2 | The old account is deactivated | `zitadel-user setState inactive` | `setState active` |
| 3 | The account is made in `dataverket` with the username and the address the old one had | `zitadel-user ensureHuman` through a definition whose `orgId` is `dataverket` | Delete the new account |
| 4 | The person's forge account takes the new Zitadel id as its sign-in name | A site admin, or a new method on `@dataverket/forgejo` (question 4) | The old id put back |
| 5 | Zitadel mails the passkey link | `swamp workflow run zitadel-passkey-link` | A new link |
| 6 | The person logs in to the forge, to Zulip and to zot, and says so | The person | Steps 4 to 1 backwards |
| 7 | The old account is deleted | `zitadel-user delete`, with `confirm` | None: this is the step that waits |

Steps 1 to 5 run as the operator at the terminal (decision 033). Whether they become one swamp workflow,
`zitadel-member-move`, is decided after the pilot: five calls for eight people is little, and a workflow that
touches two systems is worth writing only if the pilot shows the steps are the same every time.

## Steps

| Step | Needs | Agent alone | Needs you |
|---|---|---|---|
| M0, what is not known | nothing | the reads, the throwaway | the merge |
| M1, the organization takes a passkey only | the GitHub plan's C2, M0 | the values in `identity.json`, the health assertions | the merge, the push |
| M2, the pilot | M1 applied | the commands, the checks afterwards | the run, the forge step, the one person |
| M3, the other seven | M2 | the same | the same, one sitting per person or one for all |
| M4, the old accounts and the records | every member logged in | the reads, the decision record, this plan's audit | the deletes |

### M0: what is not known

On the throwaway instance of the GitHub plan's G2, and the Forgejo that Homebrew installs, never on
`id.dataverket.org`:

| Question | Why it matters |
|---|---|
| Does an organization with no password let a person register a passkey from a mailed link and log in with it, in the login the chart runs? | It is the whole shape |
| Does a project in `Operators` admit a user of `dataverket` with nothing more? | The forge's, Zulip's and zot's projects stay in `Operators`. Also the GitHub plan's G0 |
| Does the passkey link workflow reach a user in another organization than the one who runs it? | Step 5 |
| Does a renamed address marked verified send no mail? | Step 1 |
| Does a forge account whose sign-in name is set to a new id take the next login from that id, and what becomes of its old linked login? | Step 4. Read from `routers/web/auth/oauth.go`, never run |
| What does the old login UI, which a device code still goes to (`README.md`), offer a person in `dataverket`? | A second way in that the settings may not cover |
| How do Kubernetes and incus name a person: by id, by address or by username? | Whether they need a step of their own |
| Does `CreateUser` take an id that a deleted user had? | If so, step 4 could go; the price is that the old account is deleted first, so the way back goes too. Recorded, not planned on |

Also here: `ensureHuman` gains `userId` in `@dataverket/zitadel/user` if the pilot is to choose an id, and the
eighth member's forge account is looked for by name.

Done when: each question has a line under Audit saying what was run and what came back.

### M1: the organization takes a passkey only

The organization and its login settings are part of `artifacts/zitadel/identity/identity.json`, applied by
`zitadel-seed`; this plan adds nothing that makes an organization, since `@dataverket/zitadel` has no method that
writes one and the GitHub plan says why desired state does not live in a swamp definition. What changes is the
values: `allowUsernamePassword` false for `dataverket`, and the instance default keeps the password.

Health gains two assertions beside the GitHub plan's: `dataverket` reports the password off as its own setting, and
the instance default reports it on.

Done when: health is green with them, and a private window at `id.dataverket.org` with a `dataverket` user's name
offers a passkey and no password field. Rollback: `allowUsernamePassword` true in the file.

### M2: the pilot

One of the two members with a password only, since nothing of theirs is lost, and not an owner. The table under
"How one person is moved", every step, with the person on the line.

Done when: the person is in the forge as themselves, with their repositories and keys; Zulip and zot know them;
`zitadel-user authFactorList` shows one passkey on the new account and the old one is inactive. Rollback: the
table's last column, bottom up.

### M3: the other seven

The second member with a password only, then the one with TOTP, then the five with a passkey, who are the ones
giving something up. Whatever the pilot changed in the steps is changed in the table first.

### M4: the old accounts and the records

The eight old accounts deleted, each after its person has logged in everywhere. A decision record: who is in which
organization and why, that a member is made by an operator with a passkey link, and that a passkey is not proof of
a device. `docs/runbooks/` gets one page: a member who lost their passkey gets a new link, and who may send it.

Done when: `zitadel-user list` shows no `-temp` name, and `Operators` holds two owners, the chart's admin and the
machine users.

## What this changes in the GitHub plan

| There | Here |
|---|---|
| C4: the seven members stay in `Operators`, and decision 036 says so | The eight are made anew in `dataverket`; the relink per person that C4 names is step 4 |
| `dataverket`: registration on, external providers on, GitHub active, and `forceMfa` left off | A password is not allowed in `dataverket`. With GitHub as it stands there, a GitHub login would be in with no passkey at all: question 1 |
| "An operator's account is reached with a passkey made at Zitadel and nothing else" | True of the two owners. The chart's admin keeps its password, so the instance default cannot switch the password off |

## To settle before M1

1. **Registration and GitHub in `dataverket`.** Three ways: closed, every member made by an operator, which is what
   keeps strangers out and is proposed here; open with a passkey, which a scripted browser passes; or GitHub with
   `forceMfa` and a security key as the only second factor, which is the GitHub plan with a key on top. An open
   door can also be guarded at the forge instead: a role on the forge's project that a person grants.
2. **Who makes the organization.** `zitadel-seed`, when the GitHub plan's C2 is there, which this plan waits for.
   If the members should move sooner, a person makes it in the console and `identity.json` adopts it later, since
   the program adds and corrects.
3. **The id of a new account.** Zitadel's own, read after step 3 and written to the forge in step 4, which needs
   nothing new; or one chosen beforehand, which needs `userId` on `ensureHuman` and lets the forge be set first.
4. **The forge step.** By hand in the site administration for eight people, or a method on `@dataverket/forgejo`.
   Either needs an admin: the stored token has no `read:admin`.
5. **Passkeys on the site alias.** A member needs one on `id.dataverket.org` only (decision 031); the alias is the
   operators'.

## Not in this plan

- Proof of the device. Zitadel issue 12929, or Actions on the registration calls that ask for attestation and check
  it; both were looked at on 2026-11-23, neither was run, and either means security keys only and a new passkey for
  everyone.
- The owners' accounts, the chart's admin and the floor.
- GitHub as a provider: the GitHub plan, once question 1 is answered.
- The site instance: `docs/plans/2026-11-site-names.md` R4.

## Audit

Nothing yet.
