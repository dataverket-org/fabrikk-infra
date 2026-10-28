# Runbooks

What a person does, step by step, when a job comes up that is done rarely enough to be forgotten between times and
carefully enough that the order matters. Decisions say why the repository is shaped as it is, plans say what is
being changed next, runbooks say how a known job is done on what exists now.

One file per job, named after the job, no number: `docs/runbooks/<job>.md`. A runbook is edited whenever the job
changes; its history is `git log` on the file. When a job stops existing, the file goes with it.

## Shape

| Part | What it holds |
|---|---|
| Title line | `# Runbook: <the job>`, then one line on when it was written and when it was last run for real |
| Why | Two or three sentences: what the job achieves and which decision it rests on |
| What it touches | A table: what is read, what is written, which key or login each step needs, what is never touched |
| Steps | Numbered, each with the exact command and what its output must say. A step that needs a YubiKey, a browser login or another person says so in its first line |
| Proof | The command whose output shows the job is done, and what a wrong result looks like |
| Not part of this | What a reader might expect here and must not do as part of this job |

A command is written to be pasted from the repository root. A value that differs per run is `<in angle brackets>`
and the text says where it comes from. No step carries a secret: a step that needs one names the file or the
environment variable, as the operator rules require.

## The runbooks

| Runbook | The job | Rests on |
|---|---|---|
| [swamp-host-key.md](swamp-host-key.md) | Give a host that runs swamp here its own process key for `vaults/infra/`, or take a host's key away | decisions 001, 002, 016 |

Procedures that live beside what they operate stay there for now: reading the osl1 gateway
(`artifacts/versitygw/README.md`), a restore of a database (`backup/README.md`), signing an artifact
(`vaults/operator/README.md`). A procedure moves here when it outgrows a section, or when a second place needs to
point at it.
