# Contributing to Subjective Zero

Thanks for wanting to help build SubZ. Contributions of every size are welcome,
whether that's a bug fix, a new node, docs, or a feature.

## Before you start

- For a bug fix, docs, or a small improvement, just open a PR.
- For a larger feature, or anything that changes the UI or core behavior, open an
  issue first so we can agree on the approach before you invest the time.

## Ground rules

- Keep changes small and reviewable, with focused commits.
- `swift build` must stay clean (from `SubjectiveZero/Modules/`, plus the `SZApp`
  Xcode build for app-level changes).
- Match the style and conventions of the surrounding code.

## How contributions are licensed

Two quick things keep SubZ's open-source-plus-commercial model working. Neither
takes your work away from you.

**1. Sign-off (DCO).** Add a `Signed-off-by` line to your commits
(`git commit -s`). This certifies the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that
you wrote the change, or otherwise have the right to contribute it.

**2. License grant.** SubZ is offered to everyone under the AGPL-3.0, and SXP
Studio EURL also offers it commercially so the project can sustain itself (see
[`NOTICE`](NOTICE)). For that to work, contributions need to be usable under both
licenses. So by opening a PR, you give SXP Studio EURL permission to use, modify,
and relicense your contribution as part of SubZ, including under the AGPL-3.0 and
under commercial terms.

**You keep your copyright.** This is a license, not a transfer. You're free to use
your own contribution anywhere else, however you like. If any part of a PR isn't
yours to grant this way (for example, third-party code under another license),
just flag it in the PR so we can handle it properly.
