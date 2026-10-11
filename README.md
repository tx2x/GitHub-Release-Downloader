# GitHub Release Downloader

A small interactive PowerShell script for downloading release assets from GitHub repositories with [aria2](https://github.com/aria2/aria2). It is designed for Windows and keeps its repository list and default settings in a single `.ps1` file—no separate configuration file is required.

The script is useful when you regularly download binary builds from several projects and want to select the release channel, filter unwanted platforms, control parallel downloads, and resume interrupted transfers.

## Features

- **Download the newest release** for one or more repositories configured in the script.
- **Choose the release channel per repository:** `Stable` or `Pre-release`.
- **Download a specific published release** by pasting its GitHub release URL, for example `https://github.com/storytold/photocraft/releases/tag/v0.7.0`.
- **Filter assets before downloading:** optionally exclude or include platform-specific files and `.msi` installers.
- **Optionally download the release source ZIP** and the repository's `README.md` from its default branch.
- **Control parallelism:** select how many files aria2 downloads at once and how many connections it may use per file.
- **Download repositories one by one.** Within the current repository, multiple files may download in parallel; the next repository starts after the current repository's queue finishes.
- **Resume interrupted downloads** with aria2.
- **Skip files already downloaded** when a non-empty destination file exists without an aria2 control file.
- **Use GitHub API authentication automatically** from `GH_TOKEN`, `GITHUB_TOKEN`, or an existing GitHub CLI login, if available.
- **Keep everything in one script.** Edit the repository list and default concurrency settings directly in the `.ps1` file.

## Requirements

- Windows 10/11 or another environment with compatible PowerShell and aria2.
- **Windows PowerShell 5.1 or PowerShell 7+.** The script declares `#requires -Version 5.1`.
- **aria2 (`aria2c.exe`)** installed and available in `PATH`.
- Internet access to GitHub's API and release-download hosts.

### Install aria2

With Windows Package Manager (`winget`):

```powershell
winget install aria2.aria2
```

Open a new PowerShell window and verify the installation:

```powershell
aria2c --version
```

If `aria2c` is not recognized, make sure the directory containing `aria2c.exe` is in your `PATH`, then reopen PowerShell.

### Optional: GitHub CLI authentication

The script can use an existing GitHub CLI login to authenticate API requests. This is optional for public repositories, but authentication can help avoid the lower unauthenticated API rate limit.

```powershell
gh auth login
gh auth status
```

If `gh` is installed and authenticated, the script attempts to retrieve the token automatically. It also recognizes the `GH_TOKEN` and `GITHUB_TOKEN` environment variables. **Never commit a personal access token to this repository or hard-code it in the script.** For public repositories, use the minimum permissions possible; do not grant write access just for downloading releases.

## Quick start

1. Download `Download-GitHub-Releases.ps1` and save it to a directory where you want the downloads stored.
2. Install aria2 and verify that `aria2c --version` works.
3. Open PowerShell in the script's directory.
4. Run:

   ```powershell
   .\Download-GitHub-Releases.ps1
   ```

5. Choose an option from the main menu and follow the prompts.

If your PowerShell execution policy blocks a local script, review the script first and use your normal organization-approved policy. Avoid changing the machine-wide execution policy just to run this utility.

## Main menu

The script provides two download modes:

1. **Download the newest release for repositories in the list** — select one or more repositories from the configured list.
2. **Download a specific release using its GitHub URL** — paste a URL in this form:

   ```text
   https://github.com/OWNER/REPOSITORY/releases/tag/TAG
   ```

   Example:

   ```text
   https://github.com/storytold/photocraft/releases/tag/v0.7.0
   ```

The specific-release option downloads that published release tag; it does not replace or modify the configured channel for the repository list. Draft releases are not supported.

## Configure repositories

Open `Download-GitHub-Releases.ps1` in a text editor and find the **REPOSITORY LIST** section near the beginning of the file:

```powershell
$Repositories = @(
    [pscustomobject]@{ Owner = 'ggml-org';  Name = 'llama.cpp';  ReleaseChannel = 'Pre-release' }
    [pscustomobject]@{ Owner = 'anomalyco'; Name = 'opencode';   ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'can1357';   Name = 'oh-my-pi';   ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold'; Name = 'photocraft'; ReleaseChannel = 'Stable' }
    # Add more repositories by copying a line above.
)
```

Each entry has three properties:

- `Owner` — the GitHub user or organization that owns the repository.
- `Name` — the repository name, without `github.com/`.
- `ReleaseChannel` — either `Stable` or `Pre-release`.

To add a repository, copy an entry and change its values. To change its release channel, change the `ReleaseChannel` value. To remove a repository, delete its line.

### Release channel behavior

| Value | Behavior |
|---|---|
| `Stable` | Uses GitHub's latest-release endpoint, which excludes pre-releases. |
| `Pre-release` | Looks through the repository's published releases and selects the newest published pre-release returned by GitHub. Draft releases are excluded. |

A project may publish only stable releases or mostly pre-releases; set the channel separately for each repository. If the selected channel has no published release, the script reports that and continues to the next repository. It may still offer to download the repository README if that option is enabled.

## Download options and defaults

Before creating the download queue, the script asks whether to include each of these categories. Press **Enter** at a prompt to use its default.

| Option | Default | Behavior |
|---|---:|---|
| Platform-specific assets | **No** | Excludes asset names containing `arm64`, `aarch64`, `riscv`, `darwin`, or `.dmg` unless enabled. Matching is case-insensitive. |
| `.msi` installers | **Yes** | Includes assets whose names end in `.msi`. |
| Release source ZIP | **Yes** | Adds GitHub's automatically generated ZIP archive for the selected release/tag, saved as `source-code.zip`. |
| Repository README | **Yes** | Downloads the repository's `README.md` from its default branch into the release folder. |

The platform filter is based on **file names**, not on the archive contents. It is a convenience filter, not a complete CPU/OS compatibility detector. For example, assets whose names do not contain any of the listed strings will not be excluded by that rule.

The README is taken from the repository's current default branch, not from the historical contents of the selected release tag. It can therefore differ from the README that existed when that release was published.

## Download concurrency

The default values are set near the top of the script:

```powershell
$DefaultMaxConcurrentDownloads = 2  # Simultaneous files within one repository
$DefaultConnectionsPerFile     = 4  # Connections/segments per file
$MinSplitSize                  = '1M'
```

The script also asks for the maximum number of simultaneous file downloads and connections per file at startup. Press **Enter** to accept the displayed default.

Recommended starting point:

- **2 simultaneous files × 4 connections per file** for a moderate load.
- Try a higher value only if your connection and the GitHub download host benefit from it.
- If downloads slow down or fail, reduce parallelism. More connections do not guarantee higher speed, and servers may apply their own limits.

Concurrency applies to assets within one repository. Repositories are processed sequentially in the order selected; the script does not run multiple repository queues at the same time.

## Where files are saved

Files are saved beside the script in a folder named:

```text
<repository-name>-<release-tag>
```

Examples:

```text
llama.cpp-b11552/
photocraft-v0.7.0/
```

Release assets, `source-code.zip`, and the README are stored in the corresponding folder. If two selected repositories have the same repository name and release tag, their folder names can collide; use separate script directories or adjust the script if you need to download such repositories together.

## Resuming and duplicate handling

- If a download is interrupted, run the script again and choose the same repository/release. aria2 is configured to continue incomplete downloads when its control file is available.
- A non-empty destination file with no corresponding `.aria2` control file is treated as already downloaded and skipped.
- If an existing file is incomplete but has no aria2 control file, remove or rename that file before retrying.
- URLs for release assets can redirect to temporary signed download URLs. If a download fails with an authorization or expired-link error, run the script again to obtain fresh release information and URLs.

## Troubleshooting

### `aria2c.exe was not found`

Install aria2, check `aria2c --version`, and reopen PowerShell after changing `PATH`.

### GitHub API returns `403 Forbidden` or a rate-limit error

Authenticate with GitHub CLI:

```powershell
gh auth login
gh auth status
```

The script can reuse that login, or a token provided through `GH_TOKEN` / `GITHUB_TOKEN`. GitHub imposes API rate limits and secondary limits; do not repeatedly retry requests while rate-limited. Wait until the indicated reset time or retry later.

### No published release was found

Check the repository's `ReleaseChannel` setting. Use `Pre-release` for a project whose newest builds are published as pre-releases, and `Stable` for a project that publishes regular releases. Verify that the repository has a published GitHub Release; a Git tag on its own is not necessarily a release.

### A specific release URL is rejected

Use a published tag URL in this form:

```text
https://github.com/OWNER/REPOSITORY/releases/tag/TAG
```

The script does not support draft releases, arbitrary web pages, or non-GitHub release hosts.

### aria2 reports a download error

Review the URL, available disk space, network connection, and aria2 error details. Then rerun the script to retry or resume unfinished downloads. If GitHub is returning a rate-limit or access-denied response, reduce request frequency and try again later.

## Safety, licensing, and responsible use

- The script reads release metadata from the GitHub REST API and downloads files from the URLs returned for a selected release. It does not publish releases, modify repositories, delete content, star repositories, or collect GitHub user profiles.
- Downloaded executables and archives are third-party files. Review the upstream project, verify published checksums/signatures when available, and scan files according to your normal security practices before running them.
- Downloading a file does not grant permission to redistribute it. Follow the license and terms that apply to each upstream project and asset.
- Use moderate concurrency and respect GitHub API rate limits and bandwidth policies. Do not use the script for abusive or excessive automated bulk downloading.
- This project is not affiliated with or endorsed by GitHub or by the maintainers of the example repositories.

## License

MIT

## Useful links

- [GitHub REST API: Releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- [Best practices for using the GitHub REST API](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
- [GitHub Acceptable Use Policies](https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies)
- [aria2 project and releases](https://github.com/aria2/aria2)
