# Contributing

Issues and pull requests are welcome. For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Local checks

Install Terraform 1.10 or later. From the repository root, run:

```sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

No cloud credentials are needed. The init command skips the remote backend but may download providers over the network.

If ShellCheck is installed, check the shell scripts:

```sh
shellcheck bootstrap/*.sh scripts/*.sh
```

If actionlint is installed, check the GitHub Actions workflows:

```sh
actionlint
```

## Pull requests

1. Fork the repository and create a branch for the change.
2. Keep changes focused and run the applicable local checks.
3. Open a pull request against the default branch. Describe the problem, the change, and the checks you ran.
4. Address review feedback and CI results in the pull request.

Never commit credentials, private keys, tokens, billing account identifiers, Terraform state, or sensitive plan output. Cloud plans and applies are maintainer operations performed through CI, not prerequisites for a contribution.
