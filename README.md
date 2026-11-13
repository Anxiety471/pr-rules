# pr-rules

House rules for pull requests, as one composite action. Four checks, no token,
no write permission, no GitHub App:

| Check | Default | Blocks? |
|---|---|---|
| Only `staging` merges into `main` (same repo) | on | yes |
| Branch name is `<type>/<slug>` (`feat/`, `fix/`, `chore/`, `claude/`, `dependabot/`, `release/`) | on | yes |
| PR is ready for review, not a draft | on | yes |
| No credentials in added diff lines | on | yes |
| PR title within 72 characters | on | warning only |
| PR references an issue (`#123` or `HIT-123`) | off | opt-in |

Exit code 1 blocks the PR. `/vendor/`, `/node_modules/`, lockfiles, minified files and
source maps are skipped by the credential scan, and a line can opt out with
`pr-rules:allow` in a comment.

## Use it

Add one workflow file to the repo:

```yaml
name: PR rules

on:
  pull_request:
    types: [opened, reopened, synchronize, edited, ready_for_review, converted_to_draft]

concurrency:
  group: pr-rules-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  rules:
    name: PR rules
    runs-on: ubuntu-latest
    timeout-minutes: 3
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: Anxiety471/pr-rules/rules@v1
```

`fetch-depth: 0` is required: the credential scan diffs the pull request against
`origin/<base>`, and a shallow clone has no merge base.

Make `PR rules` a required status check under branch protection once it has run green
at least once, otherwise it only reports.

### Options

```yaml
      - uses: Anxiety471/pr-rules/rules@v1
        with:
          staging-branch: staging          # only branch allowed into main
          main-branch: main
          require-staging-flow: "false"    # repos without a staging branch
          branch-pattern: '^(main|staging|feat/.+)$'
          allow-draft: "false"
          scan-secrets: "true"
          require-issue-reference: "true"
          max-title-length: "72"
```

Pin to a commit for supply-chain safety: `Anxiety471/pr-rules/rules@<sha>`.

## Why no GitHub App

The action only reads the event payload and `git diff`. `GITHUB_TOKEN` with
`contents: read` is enough, so there is no private key to rotate, no installation to
maintain, and nothing that can write to your repositories. Referencing this action from
a *private* copy of the action repo would need a token; keeping it public removes that
requirement entirely.

## Test

```
bash test/run.sh
```

13 fixtures: a clean diff, an AWS key, a private key block, an allowlisted dummy, a
vendored file, a bad branch name, a draft, a direct-to-main PR, a staging promotion, a
hardcoded password, placeholders, a JWT and a GitHub token. The same suite runs in
`.github/workflows/test.yml` on every push.