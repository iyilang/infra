# Contributing

Issues and pull requests are welcome. For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Checks

CI validates Terraform on every pull request. Same-repository pull requests also
run a cloud plan after the trust bootstrap; fork pull requests do not receive
cloud credentials. Maintainers perform plans and deployments in CI.

## Pull requests

1. Fork the repository and create a branch for the change.
2. Keep changes focused and describe how to verify them.
3. Open a pull request against the default branch. Describe the problem, the change, and the checks you ran.
4. Address review feedback and CI results in the pull request.

Never commit credentials, private keys, tokens, billing account identifiers, Terraform state, or sensitive plan output. Cloud plans and applies are maintainer operations performed through CI, not prerequisites for a contribution.
