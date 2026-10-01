# Contributing

Thanks for your interest in contributing to this extension pack!

Whether it's a bug report, new feature, correction, or additional documentation, your feedback and contributions are appreciated.

Please read through this document before submitting any issues or pull requests to ensure all the necessary information is provided to effectively respond to your bug report or contribution.

Please note there is a code of conduct, please follow it in all your interactions with the project.

## Contributing via Pull Requests

If you have questions about how to submit a PR, I would be more than happy to walk you through the steps over in the [discussions](https://github.com/SamErde/PSPreworkout-VSCode-Extension-Pack/discussions)!

## Local Validation

The CI workflow runs the same checks you can run locally with Node.js (version in `.nvmrc`) and PowerShell 7:

```shell
npm ci --ignore-scripts
npm run validate            # markdownlint, cspell, package the VSIX, verify VSIX contents
npm run audit:dependencies  # npm audit at high severity, including development tools
```

Run the Pester tests with `Invoke-Pester -Path ./Tests`. If you change the files that should ship in the VSIX, update both `.vscodeignore` and the allow-list in `scripts/Test-VsixContent.ps1`.

Dependency lifecycle scripts are skipped (`--ignore-scripts`) because no dependency needs them to package or publish this extension pack.

## Releasing

Releases are published by the [Release workflow](workflows/release.yml). Publishing jobs run in the protected `release` environment, which requires approval from a maintainer.

### One-time setup

1. Create the `release` environment with a required reviewer and a deployment tag rule for `v*`. Protect `v*` tags with active tag rulesets: allow only repository admins to create them, and do not allow anyone to update or delete them. Use separate rulesets so the creation bypass cannot bypass the immutability rules.
2. Configure Visual Studio Marketplace authentication on the `release` environment. Use one of:
   - **Microsoft Entra ID (preferred):** set the `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` environment variables for an app registration with a federated credential for this repository's `release` environment, and add that identity to the `SamErde` Marketplace publisher.
   - **Personal access token:** set the `VSCE_PAT` environment secret to an Azure DevOps PAT scoped to *Marketplace (Manage)*.
3. Optional Open VSX publishing:
   1. Create an Open VSX account, sign the Eclipse Foundation publisher agreement, and create a token.
   2. Create the namespace once with `npx ovsx create-namespace SamErde -p <token>`.
   3. Set the `OVSX_PAT` secret on the `release` environment.
   4. Set the **repository** variable `PUBLISH_OPEN_VSX` to `true`. It must be a repository variable because it is evaluated before the environment is loaded.

### Publishing a release

1. Update `version` in `package.json` and move the `[Unreleased]` notes in `CHANGELOG.md` to the new version, then merge to `main`.
2. Do a dry run from `main` to build and verify the VSIX without publishing:

   ```shell
   gh workflow run release.yml --ref main -f dry_run=true
   ```

3. As a repository admin, tag the release commit and push the tag. The tag must match the `package.json` version and cannot be moved or deleted after creation:

   ```shell
   git tag v1.2.3
   git push origin v1.2.3
   ```

4. Approve the `release` deployment. The workflow publishes to the Visual Studio Marketplace, then Open VSX (if enabled), and then creates the GitHub release with the VSIX and its SHA-256 checksum.

Publishing uses `--skip-duplicate`, so if a later step fails you can safely rerun the failed jobs, or run the workflow manually from the tag with `dry_run` unchecked.

## Code of Conduct

This project has a [Code of Conduct](CODE_OF_CONDUCT.md).

## Licensing

See the [LICENSE](LICENSE) file for our project's licensing.
