#requires -Version 5.1
<#
Download-GitHub-Releases.ps1

Downloads assets from the selected release channel for each chosen GitHub repository.
All repository settings are stored in this file; no extra config files are required.

How to edit the repository list:
  Add:    copy a [pscustomobject] line and change Owner, Name, and ReleaseChannel.
  Edit:   change the values on the corresponding line.
  Remove: delete the corresponding line.

ReleaseChannel values:
  'Stable'      - latest full/stable release (excludes pre-releases).
  'Pre-release' - newest published pre-release.

Each repository is saved to a folder named: repository-name-release-tag
Repositories are downloaded one by one, in the order selected in the menu.
The main menu also supports downloading a single release by pasting its GitHub tag URL.
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
# REPOSITORY LIST: EDIT THIS SECTION. No extra config files are required.
# ReleaseChannel must be 'Stable' or 'Pre-release'.
# ============================================================================
$Repositories = @(
    [pscustomobject]@{ Owner = 'ggml-org';      Name = 'llama.cpp';  ReleaseChannel = 'Pre-release' }
    [pscustomobject]@{ Owner = 'earendil-works'; Name = 'pi';         ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'anomalyco';     Name = 'opencode';   ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'can1357';       Name = 'oh-my-pi';   ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'photocraft'; ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'lightcraft'; ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'filmcraft';  ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'effectcraft'; ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'soundcraft'; ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'designcraft'; ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'vectorcraft'; ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'pdfcraft';   ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'wordcraft';  ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'gridcraft';  ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'deckcraft';  ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'storytold';     Name = 'cadcraft';   ReleaseChannel = 'Stable' }
    [pscustomobject]@{ Owner = 'Comfy-Org';     Name = 'ComfyUI';    ReleaseChannel = 'Stable' }
    # Add more repositories by copying a line above.
)

# Filename exclusion filters. Add or remove entries as needed.
# Each entry is a literal substring matched case-insensitively against RELEASE ASSET names.
# These are not regular expressions. For example, 'openvino' excludes any asset name containing it.
$ExcludedNamePatterns = @(
    'arm64'
    'aarch64'
    'riscv'
    'darwin'
    '.dmg'
    # Add more exclusions below, one pattern per line, for example:
    # 'openvino'
    # 'debug'
)

# Default aria2 settings. They can also be changed when the script starts.
$DefaultMaxConcurrentDownloads = 2  # Simultaneous files within one repository
$DefaultConnectionsPerFile     = 4  # Connections/segments per file
$MinSplitSize                  = '1M'

# Download error handling: change this value to 1, 2, or 3.
# 1 = log/notify, skip the failed task, and continue.
# 2 = pause new tasks and ask: retry, skip, or stop after a failure.
# 3 = log/notify, retry the task once, then skip after 2 failed task attempts (default).
$DefaultErrorHandlingMode = 3

$GitHubHeaders = @{
    'User-Agent' = 'PowerShell-GitHub-Release-Downloader'
    'Accept' = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# Prefer explicit environment tokens, then reuse an existing GitHub CLI login.
$GitHubToken = $null
if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $GitHubToken = $env:GH_TOKEN.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $GitHubToken = $env:GITHUB_TOKEN.Trim()
} else {
    $ghCommand = Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue
    if ($ghCommand) {
        try {
            $tokenOutput = & $ghCommand.Source auth token --hostname github.com 2>$null
            if ($LASTEXITCODE -eq 0) {
                $candidateToken = (@($tokenOutput) -join '').Trim()
                if (-not [string]::IsNullOrWhiteSpace($candidateToken)) {
                    $GitHubToken = $candidateToken
                }
            }
        } catch {
            # GitHub CLI may be installed but not authenticated; continue without a token.
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $GitHubHeaders['Authorization'] = "Bearer $GitHubToken"
    Write-Host 'GitHub API authentication: enabled.' -ForegroundColor Green
} else {
    Write-Host 'GitHub API authentication: not available; unauthenticated rate limits may apply.' -ForegroundColor Yellow
}

# Use TLS 1.2 with Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-HttpErrorDetails {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $ErrorRecord.Exception.Message
    }

    $statusCode = 0
    $statusDescription = ''
    $bodyText = ''
    $remaining = $null
    $reset = $null

    try { $statusCode = [int]$response.StatusCode } catch {}
    try { $statusDescription = [string]$response.StatusDescription } catch {}
    try { $remaining = $response.Headers['X-RateLimit-Remaining'] } catch {}
    try { $reset = $response.Headers['X-RateLimit-Reset'] } catch {}

    try {
        if ($response -is [System.Net.HttpWebResponse]) {
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $bodyText = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } elseif ($null -ne $response.Content) {
            $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    } catch {}

    $detail = "HTTP $statusCode $statusDescription".Trim()
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
        try {
            $bodyJson = $bodyText | ConvertFrom-Json -ErrorAction Stop
            if ($bodyJson.message) { $detail += ": $($bodyJson.message)" }
            else { $detail += ": $bodyText" }
        } catch { $detail += ": $bodyText" }
    }

    if ($null -ne $remaining -and [string]$remaining -eq '0' -and $null -ne $reset) {
        try {
            $resetTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).ToLocalTime()
            $detail += " API rate limit exhausted; reset time: $($resetTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))."
        } catch { $detail += ' API rate limit exhausted.' }
    }

    return $detail
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $GitHubHeaders -ErrorAction Stop
    } catch {
        $details = Get-HttpErrorDetails -ErrorRecord $_
        throw "GitHub API request failed for '$Uri': $details"
    }
}

function Get-SelectedRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Stable', 'Pre-release')][string]$ReleaseChannel
    )

    $repoPath = "repos/$Owner/$Name"

    if ($ReleaseChannel -eq 'Stable') {
        # GitHub's /latest endpoint returns the latest published non-prerelease.
        $uri = "https://api.github.com/$repoPath/releases/latest"
        try {
            $stableRelease = Invoke-GitHubApi -Uri $uri
            if ($null -ne $stableRelease -and $stableRelease.draft -ne $true -and $stableRelease.prerelease -ne $true) {
                return $stableRelease
            }
            return $null
        } catch {
            # A 404 here means this repository has no published stable release.
            if ($_.Exception.Message -match '(?i)HTTP\s+404\b|Not Found') { return $null }
            throw
        }
    }

    # Search release pages in GitHub's newest-first order and RETURN IMMEDIATELY
    # with the first published pre-release. This function must emit one release object,
    # never the entire list (otherwise PowerShell can join many tag_name values).
    for ($page = 1; $page -le 10; $page++) {
        $uri = "https://api.github.com/$repoPath/releases?per_page=100&page=$page"
        $releaseItems = @(Invoke-GitHubApi -Uri $uri)
        if ($releaseItems.Count -eq 0) { break }

        foreach ($candidate in $releaseItems) {
            if ($null -ne $candidate -and
                $candidate.draft -eq $false -and
                $candidate.prerelease -eq $true -and
                -not [string]::IsNullOrWhiteSpace([string]$candidate.tag_name)) {
                return $candidate
            }
        }
    }

    return $null
}

function ConvertFrom-GitHubReleaseUrl {
    param([Parameter(Mandatory = $true)][string]$ReleaseUrl)

    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($ReleaseUrl.Trim(), [System.UriKind]::Absolute, [ref]$parsedUri)) {
        throw 'The URL is not valid. Expected: https://github.com/OWNER/REPOSITORY/releases/tag/TAG'
    }
    if ($parsedUri.Host -notin @('github.com', 'www.github.com')) {
        throw 'Only release URLs hosted on github.com are supported.'
    }

    $path = [System.Uri]::UnescapeDataString($parsedUri.AbsolutePath.Trim('/'))
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $path,
        '^(?<owner>[^/]+)/(?<repo>[^/]+)/releases/tag/(?<tag>.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw 'Unsupported URL. Paste a specific release URL such as https://github.com/storytold/photocraft/releases/tag/v0.7.0'
    }

    $owner = $match.Groups['owner'].Value
    $name = $match.Groups['repo'].Value -replace '\.git$', ''
    $tag = $match.Groups['tag'].Value.Trim('/')
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($tag)) {
        throw 'Could not extract owner, repository, and tag from the release URL.'
    }

    return [pscustomobject]@{ Owner = $owner; Name = $name; Tag = $tag }
}

function Get-ReleaseByTag {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $encodedTag = [System.Uri]::EscapeDataString($Tag)
    $uri = "https://api.github.com/repos/$Owner/$Name/releases/tags/$encodedTag"
    $release = Invoke-GitHubApi -Uri $uri
    if ($null -eq $release -or $release.draft -eq $true) {
        throw "The requested release tag '$Tag' was not found or is not published."
    }
    return $release
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][bool]$Default
    )

    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $hint").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -match '^(?i:n|no)$') { return $false }
        Write-Host 'Enter Y or N, or press Enter to use the default.' -ForegroundColor Yellow
    }
}

function Read-PositiveInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][int]$Default
    )

    while ($true) {
        $answer = (Read-Host "$Prompt [$Default]").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le 64) { return $number }
        Write-Host 'Enter a whole number from 1 to 64.' -ForegroundColor Yellow
    }
}

function Select-Repositories {
    param([Parameter(Mandatory = $true)][object[]]$RepoList)

    if ($RepoList.Count -eq 0) { throw 'The $Repositories list is empty. Add at least one repository near the top of this script.' }

    # Start with nothing selected by default.
    $selected = @()

    while ($true) {
        Write-Host ''
        Write-Host '========== Select GitHub repositories ==========' -ForegroundColor Cyan
        for ($i = 0; $i -lt $RepoList.Count; $i++) {
            $mark = if ($selected -contains $i) { 'x' } else { ' ' }
            $channel = [string]$RepoList[$i].ReleaseChannel
            Write-Host (' [{0}] {1}. {2}/{3} ({4})' -f $mark, ($i + 1), $RepoList[$i].Owner, $RepoList[$i].Name, $channel)
        }
        Write-Host ''
        Write-Host 'Enter numbers/ranges (e.g. 1, 2, 5-16). Prefix numbers/ranges with - to remove (e.g. -3, -7-9).'
        Write-Host 'A = select all; N = clear all; Enter = confirm; Q = quit.'
        $answer = (Read-Host 'Selection').Trim()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($selected.Count -eq 0) {
                Write-Host 'Nothing is selected. Enter numbers/ranges, A to select all, or Q to quit.' -ForegroundColor Yellow
                continue
            }
            return [pscustomobject]@{ Cancelled = $false; Indices = @($selected | Sort-Object -Unique) }
        }
        if ($answer -match '^(?i:a|all)$') {
            $selected = @(for ($i = 0; $i -lt $RepoList.Count; $i++) { $i })
            continue
        }
        if ($answer -match '^(?i:n|none|clear)$') { $selected = @(); continue }
        if ($answer -match '^(?i:q|quit)$') { return [pscustomobject]@{ Cancelled = $true; Indices = @() } }

        # Parse every token before changing the current selection, so invalid
        # input never leaves the menu in a partially modified state.
        $tokens = @($answer -split '[,;\s]+' | Where-Object { $_ -ne '' })
        $parsedTokens = New-Object 'System.Collections.Generic.List[object]'
        $valid = ($tokens.Count -gt 0)
        foreach ($token in $tokens) {
            if ($token -notmatch '^(?<exclude>[-!]?)(?<start>\d+)(?:-(?<end>\d+))?$') {
                $valid = $false
                break
            }

            $exclude = -not [string]::IsNullOrEmpty($Matches.exclude)
            $startNumber = [int]$Matches.start
            $endNumber = if ([string]::IsNullOrEmpty($Matches.end)) { $startNumber } else { [int]$Matches.end }

            if ($startNumber -lt 1 -or $endNumber -lt 1 -or
                $startNumber -gt $RepoList.Count -or $endNumber -gt $RepoList.Count -or
                $startNumber -gt $endNumber) {
                $valid = $false
                break
            }

            $indices = @($startNumber..$endNumber | ForEach-Object { $_ - 1 })
            $parsedTokens.Add([pscustomobject]@{ Exclude = $exclude; Indices = $indices })
        }

        if (-not $valid) {
            Write-Host ("Invalid selection. Use numbers/ranges from 1 to {0}, e.g. 1, 2, 5-8, -3, or -6-9." -f $RepoList.Count) -ForegroundColor Yellow
            continue
        }

        $includeTokens = @($parsedTokens | Where-Object { -not $_.Exclude })
        $excludeTokens = @($parsedTokens | Where-Object { $_.Exclude })

        if ($includeTokens.Count -gt 0) {
            # When inclusions are present, they define a fresh selection.
            # Exclusions in the same input are then removed from that selection.
            $workingSelection = @($includeTokens | ForEach-Object { $_.Indices } | Sort-Object -Unique)
        } else {
            # Exclusion-only input edits the current selection in place.
            $workingSelection = @($selected)
        }

        foreach ($exclusion in $excludeTokens) {
            foreach ($indexToRemove in $exclusion.Indices) {
                $workingSelection = @($workingSelection | Where-Object { $_ -ne $indexToRemove })
            }
        }

        $selected = @($workingSelection | Sort-Object -Unique)
    }
}

function Add-DownloadTask {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$TaskList,
        [Parameter(Mandatory = $true)][hashtable]$UsedNames,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-Host "Skipping item without a URL: $FileName" -ForegroundColor Yellow
        return
    }

    $candidate = [System.IO.Path]::GetFileName($FileName) -replace '[\r\n]', '_'
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = 'download.bin' }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($candidate)
    $extension = [System.IO.Path]::GetExtension($candidate)
    $number = 2
    while ($UsedNames.ContainsKey($candidate)) {
        $candidate = "$baseName-$number$extension"
        $number++
    }
    $UsedNames[$candidate] = $true

    [void]$TaskList.Add([pscustomobject]@{
        Repository = $Repository
        Folder     = $Folder
        Url        = $Url
        FileName   = $candidate
        Kind       = $Kind
    })
}

function Protect-LogText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    # GitHub release download URLs may contain temporary signed query strings.
    # Redact query strings so the log does not retain signed URL tokens.
    $safe = [System.Text.RegularExpressions.Regex]::Replace(
        $Text,
        '(?i)(https?://[^\s?]+)\?[^\s]+',
        '$1?[query redacted]'
    )
    $safe = [System.Text.RegularExpressions.Regex]::Replace(
        $safe,
        '(?i)(Authorization\s*:\s*Bearer\s+)\S+',
        '$1[redacted]'
    )
    return $safe
}

function Write-DownloaderLog {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Repository = '',
        [string]$FileName = '',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace([string]$script:ErrorLogPath)) { return }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $context = ''
    if (-not [string]::IsNullOrWhiteSpace($Repository)) { $context += " [$Repository]" }
    if (-not [string]::IsNullOrWhiteSpace($FileName)) { $context += " [$FileName]" }

    $safeMessage = Protect-LogText -Text $Message
    $messageLines = @($safeMessage -split '\r?\n')
    $logLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($messageLine in $messageLines) {
        $logLines.Add("[$timestamp] [$Level]$context $messageLine")
    }

    try {
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::AppendAllText($script:ErrorLogPath, (($logLines -join [Environment]::NewLine) + [Environment]::NewLine), $encoding)
    } catch {
        Write-Host "Could not write the download log '$($script:ErrorLogPath)': $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-Aria2ErrorLines {
    param([string]$LogPath)

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return @()
    }

    try {
        $allLines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop)
        $errorLines = @($allLines | Where-Object {
            $_ -match '(?i)error|exception|failed|aborted|cannot|could not|denied|no space|warn|errorcode|errormessage'
        })
        if ($errorLines.Count -eq 0) { $errorLines = @($allLines | Select-Object -Last 12) }
        return @($errorLines | Select-Object -Last 20 | ForEach-Object { Protect-LogText -Text ([string]$_) })
    } catch {
        return @("Could not read aria2 log: $($_.Exception.Message)")
    }
}

function Start-Aria2DownloadTask {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Aria2Path,
        [Parameter(Mandatory = $true)][int]$ConnectionsPerFile,
        [Parameter(Mandatory = $true)][string]$MinSplitSize
    )

    $taskId = [guid]::NewGuid().ToString('N')
    $tempRoot = [System.IO.Path]::GetTempPath()
    $inputFile = Join-Path $tempRoot "aria2-github-release-$taskId.txt"
    $aria2Log = Join-Path $tempRoot "aria2-github-release-$taskId.log"
    $outputFolderForAria2 = ([string]$Task.Folder) -replace '\\', '/'
    $inputLines = @(
        [string]$Task.Url
        "  dir=$outputFolderForAria2"
        "  out=$($Task.FileName)"
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllLines($inputFile, $inputLines, $utf8NoBom)
        $arguments = @(
            ('"--input-file={0}"' -f $inputFile)
            '--max-concurrent-downloads=1'
            "--max-connection-per-server=$ConnectionsPerFile"
            "--split=$ConnectionsPerFile"
            "--min-split-size=$MinSplitSize"
            '--continue=true'
            '--auto-file-renaming=false'
            '--allow-overwrite=false'
            '--retry-wait=5'
            '--max-tries=2'
            '--console-log-level=warn'
            '--summary-interval=5'
            ('"--log={0}"' -f $aria2Log)
            '--log-level=warn'
        )
        $process = Start-Process -FilePath $Aria2Path -ArgumentList $arguments -PassThru -NoNewWindow -ErrorAction Stop
        return [pscustomobject]@{
            Task = $Task
            Process = $process
            Attempt = [int]$Task.FailedAttempts + 1
            InputFile = $inputFile
            LogFile = $aria2Log
            StartError = $null
        }
    } catch {
        return [pscustomobject]@{
            Task = $Task
            Process = $null
            Attempt = [int]$Task.FailedAttempts + 1
            InputFile = $inputFile
            LogFile = $aria2Log
            StartError = $_.Exception.Message
        }
    }
}

function Remove-Aria2TaskTemporaryFiles {
    param($Job)

    foreach ($path in @($Job.InputFile, $Job.LogFile)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

# Check aria2 before making API requests.
$aria2Command = Get-Command 'aria2c' -CommandType Application -ErrorAction SilentlyContinue
if (-not $aria2Command) {
    Write-Host 'aria2c.exe was not found.' -ForegroundColor Red
    Write-Host 'Install it with: winget install aria2.aria2'
    Write-Host 'Then reopen PowerShell and run this script again.'
    exit 1
}
$aria2Path = $aria2Command.Source
$OutputRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
$script:ErrorLogPath = Join-Path $OutputRoot 'Download-GitHub-Releases.log'
if ($DefaultErrorHandlingMode -notin @(1, 2, 3)) {
    Write-Host 'Invalid $DefaultErrorHandlingMode value. Falling back to mode 3.' -ForegroundColor Yellow
    $DefaultErrorHandlingMode = 3
}
Write-DownloaderLog -Level INFO -Message 'Run started.'

Write-Host ''
Write-Host '========== GitHub Release Downloader ==========' -ForegroundColor Cyan
Write-Host '1. Download the newest release for repositories in the list'
Write-Host '2. Download a specific release using its GitHub URL'
Write-Host 'Q. Quit'
$mainChoice = (Read-Host 'Choose an option').Trim()

$selectedRepos = @()
if ($mainChoice -match '^(?i:1|latest)$') {
    try { $selection = Select-Repositories -RepoList $Repositories }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
    if ($selection.Cancelled) { Write-Host 'Cancelled.'; exit 0 }

    foreach ($index in $selection.Indices) {
        $selectedRepos += $Repositories[[int]$index]
    }
} elseif ($mainChoice -match '^(?i:2|url|specific)$') {
    while ($true) {
        $releaseUrl = (Read-Host 'Paste the specific GitHub release URL (or Q to cancel)').Trim()
        if ($releaseUrl -match '^(?i:q|quit)$') { Write-Host 'Cancelled.'; exit 0 }
        try {
            $releaseDetails = ConvertFrom-GitHubReleaseUrl -ReleaseUrl $releaseUrl
            $selectedRepos = @([pscustomobject]@{
                Owner = $releaseDetails.Owner
                Name = $releaseDetails.Name
                ReleaseChannel = 'Specific'
                SpecificTag = $releaseDetails.Tag
            })
            break
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
} elseif ($mainChoice -match '^(?i:q|quit)$') {
    Write-Host 'Cancelled.'
    exit 0
} else {
    Write-Host 'Invalid menu selection.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host '========== Download options ==========' -ForegroundColor Cyan
Write-Host 'Default mode downloads all release assets without filename filters, plus Source ZIP and README.md.' -ForegroundColor DarkGray

# Keep the default path simple: one filter question, with filtering disabled by default.
# If the user opts into filters, offer the advanced filtering and download-category options.
$applyFilters = Read-YesNo 'Apply filters and optional download restrictions for this run?' $false

$usableExcludedPatterns = @($ExcludedNamePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$activeExcludedPatterns = @()
$useExcludedNamePatterns = $false
$useOnlyMatchingNames = $false
$includeOnlyNamePatterns = @()
$includeMsi = $true
$includeSourceZip = $true
$includeReadme = $true

if ($applyFilters) {
    Write-Host ''
    Write-Host '========== Advanced filters and download options ==========' -ForegroundColor Cyan
    Write-Host 'Filename filters apply to release assets only. Source ZIP and README are controlled separately.' -ForegroundColor DarkGray

    $useConfiguredExclusions = $false
    if ($usableExcludedPatterns.Count -gt 0) {
        $excludedPatternsLabel = $usableExcludedPatterns -join ', '
        $useConfiguredExclusions = Read-YesNo "Apply configured filename exclusions ($excludedPatternsLabel)?" $true
    } else {
        Write-Host 'No default filename exclusion patterns are configured.' -ForegroundColor DarkGray
    }

    $extraExcludedPatterns = @()
    $addExtraExclusions = Read-YesNo 'Add extra filename exclusion keywords for this run?' $false
    if ($addExtraExclusions) {
        while ($extraExcludedPatterns.Count -eq 0) {
            $extraExcludeInput = Read-Host 'Enter extra exclusion keywords separated by commas or semicolons (e.g. openvino, debug)'
            $extraExcludedPatterns = @($extraExcludeInput -split '[,;]' | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            if ($extraExcludedPatterns.Count -eq 0) {
                Write-Host 'Enter at least one non-empty keyword.' -ForegroundColor Yellow
            }
        }
    }

    if ($useConfiguredExclusions) { $activeExcludedPatterns += $usableExcludedPatterns }
    if ($extraExcludedPatterns.Count -gt 0) { $activeExcludedPatterns += $extraExcludedPatterns }
    $activeExcludedPatterns = @($activeExcludedPatterns | Select-Object -Unique)
    $useExcludedNamePatterns = ($activeExcludedPatterns.Count -gt 0)

    $useOnlyMatchingNames = Read-YesNo 'Download only release assets whose names contain at least one keyword you specify?' $false
    if ($useOnlyMatchingNames) {
        while ($includeOnlyNamePatterns.Count -eq 0) {
            $patternInput = Read-Host 'Enter filename keywords separated by commas or semicolons (e.g. cuda, vulkan, win-cuda)'
            $includeOnlyNamePatterns = @($patternInput -split '[,;]' | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            if ($includeOnlyNamePatterns.Count -eq 0) {
                Write-Host 'Enter at least one non-empty keyword.' -ForegroundColor Yellow
            }
        }
    }

    $includeMsi = Read-YesNo 'Download .msi files?' $true
    $includeSourceZip = Read-YesNo 'Download the release source code ZIP?' $true
    $includeReadme = Read-YesNo 'Download README.md from the repository default branch?' $true
} else {
    Write-Host 'Filters are disabled. All release assets, including .msi files, are eligible for download.' -ForegroundColor Green
    Write-Host 'Source ZIP and README.md downloads are enabled.' -ForegroundColor Green
}

Write-Host ''
Write-Host '========== aria2 settings ==========' -ForegroundColor Cyan
$MaxConcurrentDownloads = Read-PositiveInteger 'Maximum simultaneous file downloads per repository' $DefaultMaxConcurrentDownloads
$ConnectionsPerFile = Read-PositiveInteger 'Connections per file' $DefaultConnectionsPerFile

Write-Host ''
Write-Host 'Retrieving release information and preparing download queues...' -ForegroundColor Cyan
$repositoryPlans = New-Object 'System.Collections.Generic.List[object]'

foreach ($repo in $selectedRepos) {
    $fullName = "$($repo.Owner)/$($repo.Name)"
    $channel = [string]$repo.ReleaseChannel
    if ([string]::IsNullOrWhiteSpace($channel)) { $channel = 'Stable' }
    if ($channel -notin @('Stable', 'Pre-release', 'Specific')) {
        Write-Host "[$fullName] Invalid ReleaseChannel '$channel'. Use 'Stable' or 'Pre-release' in the repository list." -ForegroundColor Red
        continue
    }

    if ($channel -eq 'Specific') {
        Write-Host "`n[$fullName] (specific tag: $($repo.SpecificTag))" -ForegroundColor Cyan
    } else {
        Write-Host "`n[$fullName] (channel: $channel)" -ForegroundColor Cyan
    }
    $release = $null
    try {
        if ($channel -eq 'Specific') {
            $release = Get-ReleaseByTag -Owner ([string]$repo.Owner) -Name ([string]$repo.Name) -Tag ([string]$repo.SpecificTag)
        } else {
            # Always normalize the helper result to ONE release object.
            # This guards against PowerShell pipeline enumeration accidentally returning
            # an array of releases, which would otherwise turn the folder name into
            # a space-separated list of every release tag.
            $releaseCandidates = @(Get-SelectedRelease -Owner ([string]$repo.Owner) -Name ([string]$repo.Name) -ReleaseChannel $channel | Where-Object {
                $null -ne $_ -and
                -not [string]::IsNullOrWhiteSpace([string]$_.tag_name) -and
                $_.draft -ne $true -and
                ([bool]$_.prerelease -eq ($channel -eq 'Pre-release'))
            })

            if ($releaseCandidates.Count -gt 0) {
                # If more than one object was emitted, choose the newest published one.
                $releaseCandidates = @($releaseCandidates | Sort-Object -Property @{
                    Expression = {
                        $dateText = [string]$_.published_at
                        if ([string]::IsNullOrWhiteSpace($dateText)) { $dateText = [string]$_.created_at }
                        try { [DateTimeOffset]::Parse($dateText) } catch { [DateTimeOffset]::MinValue }
                    }
                    Descending = $true
                })
                $release = $releaseCandidates[0]
                if ($releaseCandidates.Count -gt 1) {
                    Write-Host "  Notice: multiple release objects were returned; using only the newest: $($release.tag_name)" -ForegroundColor Yellow
                }
            }
        }
    } catch {
        Write-Host "Could not retrieve release information: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-DownloaderLog -Level ERROR -Repository $fullName -Message "Could not retrieve release information: $($_.Exception.Message)"
        if ($_.Exception.Message -match '(?i)403|rate limit') {
            if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
                Write-Host '  Fix: run gh auth login, then rerun this script. A saved gh token is used automatically.' -ForegroundColor Yellow
                Write-Host '  You can also set GH_TOKEN or GITHUB_TOKEN in the environment.' -ForegroundColor Yellow
            } else {
                Write-Host '  A token was found, but GitHub still denied the request. Check gh auth status and token permissions.' -ForegroundColor Yellow
            }
        }
    }

    if ($null -ne $release) {
        $tag = [string]$release.tag_name
        if ($channel -eq 'Specific') {
            Write-Host "Selected specific release: $tag"
        } else {
            Write-Host "Selected newest $channel release: $tag"
        }
    } else {
        if ($channel -eq 'Specific') {
            $tag = [string]$repo.SpecificTag
            Write-Host "The requested release '$tag' could not be retrieved." -ForegroundColor Yellow
        } else {
            $tag = 'no-release'
            Write-Host "No published $channel release was found or release information could not be retrieved." -ForegroundColor Yellow
        }
    }

    # Release tags should be a single non-empty string. Refuse to create a folder
    # if a malformed/multi-value tag somehow slips through.
    if ($null -ne $release -and ($tag -match '\s' -or [string]::IsNullOrWhiteSpace($tag))) {
        Write-Host "Invalid release tag returned by GitHub ('$tag'); skipping $fullName to avoid an invalid output folder." -ForegroundColor Red
        continue
    }

    $safeTag = $tag -replace '[\\/:*?"<>|]', '_'
    $folderName = "$($repo.Name)-$safeTag"
    $folder = Join-Path $OutputRoot $folderName
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $usedNames = @{}
    $tasks = New-Object 'System.Collections.Generic.List[object]'

    if ($null -ne $release) {
        foreach ($asset in @($release.assets)) {
            $assetName = [string]$asset.name
            if ([string]::IsNullOrWhiteSpace($assetName)) { continue }

            # Exclusion patterns are literal, case-insensitive substrings.
            # Exclusions take priority over the optional include-only filter.
            if ($useExcludedNamePatterns) {
                $matchedExclusionPattern = $null
                foreach ($pattern in $activeExcludedPatterns) {
                    if ($assetName.IndexOf([string]$pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchedExclusionPattern = [string]$pattern
                        break
                    }
                }
                if ($null -ne $matchedExclusionPattern) {
                    Write-Host "  Excluded by filename pattern '$matchedExclusionPattern': $assetName" -ForegroundColor DarkGray
                    continue
                }
            }

            if (-not $includeMsi -and $assetName -match '(?i)\.msi$') {
                Write-Host "  Excluded by MSI filter: $assetName" -ForegroundColor DarkGray
                continue
            }

            if ($useOnlyMatchingNames) {
                $matchedIncludePattern = $null
                foreach ($pattern in $includeOnlyNamePatterns) {
                    if ($assetName.IndexOf([string]$pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchedIncludePattern = [string]$pattern
                        break
                    }
                }
                if ($null -eq $matchedIncludePattern) {
                    Write-Host "  Excluded by include-only filename filter: $assetName" -ForegroundColor DarkGray
                    continue
                }
            }

            Add-DownloadTask -TaskList $tasks -UsedNames $usedNames -Repository $fullName -Folder $folder `
                -Url ([string]$asset.browser_download_url) -FileName $assetName -Kind 'Asset'
        }

        if ($includeSourceZip) {
            Add-DownloadTask -TaskList $tasks -UsedNames $usedNames -Repository $fullName -Folder $folder `
                -Url ([string]$release.zipball_url) -FileName 'source-code.zip' -Kind 'Source ZIP'
        }
    }

    if ($includeReadme) {
        try {
            # The /readme endpoint resolves the repository's default README path and branch.
            $readmeInfo = Invoke-GitHubApi -Uri "https://api.github.com/repos/$fullName/readme"
            if (-not [string]::IsNullOrWhiteSpace([string]$readmeInfo.download_url)) {
                Add-DownloadTask -TaskList $tasks -UsedNames $usedNames -Repository $fullName -Folder $folder `
                    -Url ([string]$readmeInfo.download_url) -FileName 'README.md' -Kind 'README'
            } else {
                Write-Host '  README endpoint returned no download URL.' -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  README.md could not be retrieved: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-DownloaderLog -Level WARN -Repository $fullName -FileName 'README.md' -Message "Could not retrieve README.md: $($_.Exception.Message)"
            Write-Host '  Continuing without README.md.' -ForegroundColor DarkYellow
        }
    }

    [void]$repositoryPlans.Add([pscustomobject]@{
        Repository   = $fullName
        Tag          = $tag
        Channel      = $channel
        Folder       = $folder
        Tasks        = $tasks
        PendingTasks = $null
    })
}

if ($repositoryPlans.Count -eq 0) {
    Write-Host 'No repositories could be prepared. Check repository names and ReleaseChannel values.' -ForegroundColor Yellow
    exit 1
}

$totalPending = 0
$alreadyPresent = 0
foreach ($plan in $repositoryPlans) {
    $pendingTasks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($task in $plan.Tasks) {
        $destination = Join-Path $task.Folder $task.FileName
        $controlFile = "$destination.aria2"
        if ((Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $controlFile)) {
            $existing = Get-Item -LiteralPath $destination
            if ($existing.Length -gt 0) {
                Write-Host "Already exists, skipping: $($plan.Repository) / $($task.FileName)" -ForegroundColor DarkGray
                $alreadyPresent++
                continue
            }
            Remove-Item -LiteralPath $destination -Force
        }
        [void]$pendingTasks.Add($task)
    }
    $plan.PendingTasks = $pendingTasks
    $totalPending += $pendingTasks.Count
}

Write-Host ''
Write-Host '========== Download plan ==========' -ForegroundColor Cyan
foreach ($plan in $repositoryPlans) {
    Write-Host ('{0} [{1}; {2}]: {3} file(s) queued' -f $plan.Repository, $plan.Channel, $plan.Tag, $plan.PendingTasks.Count)
}
Write-Host "Files queued: $totalPending; already present: $alreadyPresent"
Write-Host "Per repository: up to $MaxConcurrentDownloads simultaneous file(s), $ConnectionsPerFile connection(s) per file"
Write-Host "Active filename exclusions: $(if ($useExcludedNamePatterns) { $activeExcludedPatterns -join ', ' } else { 'None' })"
if ($useOnlyMatchingNames) {
    Write-Host "Include-only filename patterns: $($includeOnlyNamePatterns -join ', ')"
} else {
    Write-Host 'Include-only filename filter: Disabled'
}
Write-Host "MSI: $(if ($includeMsi) { 'Yes' } else { 'No' }); Source ZIP: $(if ($includeSourceZip) { 'Yes' } else { 'No' }); README.md: $(if ($includeReadme) { 'Yes' } else { 'No' })"
Write-Host 'Filename filters affect release assets only; source ZIP and README follow their own options.'
Write-Host 'Repositories will be downloaded one by one, in repository-list order.'

if ($totalPending -eq 0) {
    Write-Host 'No files are queued. See the messages above for repositories with missing releases or README files.' -ForegroundColor Yellow
    exit 0
}
if (-not (Read-YesNo 'Start downloading now?' $true)) { Write-Host 'Download cancelled.'; exit 0 }

$failedTasks = New-Object 'System.Collections.Generic.List[string]'
$successfulTasks = 0
$skippedAfterErrors = 0
$failedAttemptsTotal = 0
$stoppedByUser = $false
$errorModeText = switch ($DefaultErrorHandlingMode) {
    1 { 'Mode 1: log/notify, skip a failed task, and continue.' }
    2 { 'Mode 2: pause new tasks after an error and ask whether to retry, skip, or stop.' }
    3 { 'Mode 3: retry a failed task once; skip after 2 failed task attempts (default).' }
}
Write-Host "Error handling: $errorModeText" -ForegroundColor Cyan
Write-Host "Error log: $script:ErrorLogPath" -ForegroundColor DarkGray
Write-DownloaderLog -Level INFO -Message "Error handling selected: $errorModeText"

foreach ($plan in $repositoryPlans) {
    if ($stoppedByUser) { break }
    if ($plan.PendingTasks.Count -eq 0) { continue }

    Write-Host "`n========== Downloading $($plan.Repository) [$($plan.Channel); $($plan.Tag)] ==========" -ForegroundColor Cyan
    Write-DownloaderLog -Level INFO -Repository $plan.Repository -Message "Starting release queue for tag '$($plan.Tag)' with $($plan.PendingTasks.Count) task(s)."

    $pendingTasks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($task in $plan.PendingTasks) {
        if (-not ($task.PSObject.Properties.Name -contains 'FailedAttempts')) {
            $task | Add-Member -MemberType NoteProperty -Name FailedAttempts -Value 0
        }
        $pendingTasks.Add($task)
    }
    $activeJobs = New-Object 'System.Collections.Generic.List[object]'
    $decisionQueue = New-Object 'System.Collections.Generic.List[object]'

    while (($pendingTasks.Count -gt 0) -or ($activeJobs.Count -gt 0) -or ($decisionQueue.Count -gt 0)) {
        if ($stoppedByUser) { break }

        # In interactive mode, wait for all in-flight downloads to finish before asking.
        # Do not schedule additional files while an error decision is pending.
        if ($DefaultErrorHandlingMode -eq 2 -and $activeJobs.Count -eq 0 -and $decisionQueue.Count -gt 0) {
            $failedJob = $decisionQueue[0]
            $decisionQueue.RemoveAt(0)
            $failedTask = $failedJob.Task
            Write-Host ''
            Write-Host "A download failed: $($failedTask.Repository) / $($failedTask.FileName)" -ForegroundColor Red
            Write-Host 'R = retry this task; S = skip this task and continue; Q = stop the remaining downloads.'
            while ($true) {
                $action = (Read-Host 'Action [R/S/Q]').Trim()
                if ($action -match '^(?i:r|retry)$') {
                    Write-DownloaderLog -Level WARN -Repository $failedTask.Repository -FileName $failedTask.FileName -Message 'User selected retry after a failed attempt.'
                    $pendingTasks.Insert(0, $failedTask)
                    break
                } elseif ($action -match '^(?i:s|skip)$') {
                    $skippedAfterErrors++
                    [void]$failedTasks.Add("$($failedTask.Repository) / $($failedTask.FileName)")
                    Write-DownloaderLog -Level WARN -Repository $failedTask.Repository -FileName $failedTask.FileName -Message 'User chose to skip this failed task and continue.'
                    Write-Host 'Skipping this task and continuing.' -ForegroundColor Yellow
                    break
                } elseif ($action -match '^(?i:q|quit|stop)$') {
                    $stoppedByUser = $true
                    Write-DownloaderLog -Level WARN -Repository $failedTask.Repository -FileName $failedTask.FileName -Message 'User stopped the download run after an error.'
                    Write-Host 'Stopping the remaining downloads.' -ForegroundColor Yellow
                    break
                }
                Write-Host 'Enter R, S, or Q.' -ForegroundColor Yellow
            }
            continue
        }

        while (($activeJobs.Count -lt $MaxConcurrentDownloads) -and ($pendingTasks.Count -gt 0) -and
               -not ($DefaultErrorHandlingMode -eq 2 -and $decisionQueue.Count -gt 0) -and -not $stoppedByUser) {
            $task = $pendingTasks[0]
            $pendingTasks.RemoveAt(0)
            $attemptNumber = [int]$task.FailedAttempts + 1
            Write-Host ("Starting: {0} / {1} (attempt {2})" -f $task.Repository, $task.FileName, $attemptNumber) -ForegroundColor DarkGray
            $job = Start-Aria2DownloadTask -Task $task -Aria2Path $aria2Path -ConnectionsPerFile $ConnectionsPerFile -MinSplitSize $MinSplitSize
            $activeJobs.Add($job)
            if ($null -ne $job.StartError) {
                Write-Host "Could not start aria2: $($job.StartError)" -ForegroundColor Red
            }
        }

        $completedJobs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($job in @($activeJobs.ToArray())) {
            $finished = $false
            if ($null -eq $job.Process) {
                $finished = $true
            } else {
                try { $finished = $job.Process.HasExited } catch { $finished = $true }
            }
            if ($finished) { $completedJobs.Add($job) }
        }

        foreach ($job in $completedJobs) {
            [void]$activeJobs.Remove($job)
            $task = $job.Task
            $destination = Join-Path $task.Folder $task.FileName
            $aria2ControlFile = "$destination.aria2"
            $exitCode = -1
            if ($null -ne $job.Process) {
                try { $exitCode = [int]$job.Process.ExitCode } catch { $exitCode = -1 }
            }

            $fileIsPresent = Test-Path -LiteralPath $destination
            $fileHasContent = $false
            if ($fileIsPresent) {
                try { $fileHasContent = ((Get-Item -LiteralPath $destination -ErrorAction Stop).Length -gt 0) } catch { $fileHasContent = $false }
            }
            $taskSucceeded = ($null -eq $job.StartError) -and ($exitCode -eq 0) -and $fileHasContent -and -not (Test-Path -LiteralPath $aria2ControlFile)

            if ($taskSucceeded) {
                $successfulTasks++
                Write-Host "Completed: $($task.Repository) / $($task.FileName)" -ForegroundColor Green
                Remove-Aria2TaskTemporaryFiles -Job $job
                continue
            }

            $task.FailedAttempts = [int]$task.FailedAttempts + 1
            $failedAttemptsTotal++
            $detailLines = @(Get-Aria2ErrorLines -LogPath $job.LogFile)
            if (-not [string]::IsNullOrWhiteSpace([string]$job.StartError)) {
                $detailLines = @("Could not start aria2: $($job.StartError)") + $detailLines
            }
            if ($detailLines.Count -eq 0) {
                $detailLines = @("aria2 exit code: $exitCode; destination file was not confirmed complete.", 'Check disk space, write permissions, network access, and the aria2 log output.')
            }

            Write-Host ''
            Write-Host ("[DOWNLOAD ERROR] {0} / {1} (failed task attempt {2})." -f $task.Repository, $task.FileName, $task.FailedAttempts) -ForegroundColor Red
            foreach ($detailLine in $detailLines) {
                Write-Host ("  {0}" -f (Protect-LogText -Text ([string]$detailLine))) -ForegroundColor DarkYellow
            }
            Write-Host "  Details are being saved to: $script:ErrorLogPath" -ForegroundColor Yellow

            $detailText = "Failed task attempt $($task.FailedAttempts); aria2 exit code $exitCode.`n" + ($detailLines -join "`n")
            Write-DownloaderLog -Level ERROR -Repository $task.Repository -FileName $task.FileName -Message $detailText
            Remove-Aria2TaskTemporaryFiles -Job $job

            # If aria2 left an output file without its control file, it cannot be
            # resumed safely. Remove this known-failed partial file so a retry or
            # the next script run is not blocked by the duplicate-file check.
            if ((Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $aria2ControlFile)) {
                try {
                    Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
                    Write-DownloaderLog -Level WARN -Repository $task.Repository -FileName $task.FileName -Message 'Removed incomplete output because no aria2 control file was available for resuming.'
                } catch {
                    Write-DownloaderLog -Level WARN -Repository $task.Repository -FileName $task.FileName -Message "Could not remove incomplete output file: $($_.Exception.Message)"
                }
            }

            if ($DefaultErrorHandlingMode -eq 1) {
                $skippedAfterErrors++
                [void]$failedTasks.Add("$($task.Repository) / $($task.FileName)")
                Write-DownloaderLog -Level WARN -Repository $task.Repository -FileName $task.FileName -Message 'Skipping failed task as configured (mode 1).'
                Write-Host 'Mode 1: skipping this task and continuing with the next file.' -ForegroundColor Yellow
            } elseif ($DefaultErrorHandlingMode -eq 2) {
                $decisionQueue.Add([pscustomobject]@{ Task = $task; DetailLines = $detailLines })
                Write-Host 'Mode 2: waiting for other active downloads to finish, then asking for the next action.' -ForegroundColor Yellow
            } else {
                if ([int]$task.FailedAttempts -lt 2) {
                    Write-DownloaderLog -Level WARN -Repository $task.Repository -FileName $task.FileName -Message 'Automatic retry scheduled after the first failed task attempt (mode 3).'
                    Write-Host 'Mode 3: retrying this task once.' -ForegroundColor Yellow
                    $pendingTasks.Insert(0, $task)
                } else {
                    $skippedAfterErrors++
                    [void]$failedTasks.Add("$($task.Repository) / $($task.FileName)")
                    Write-DownloaderLog -Level WARN -Repository $task.Repository -FileName $task.FileName -Message 'Task failed twice; skipping it and continuing (mode 3).'
                    Write-Host 'The task failed twice. Skipping it and continuing with the next file.' -ForegroundColor Yellow
                }
            }
        }

        if ($activeJobs.Count -gt 0 -and $completedJobs.Count -eq 0) {
            Start-Sleep -Milliseconds 300
        }
    }

    if (-not $stoppedByUser) {
        Write-Host "Finished queue for $($plan.Repository)." -ForegroundColor Cyan
        Write-DownloaderLog -Level INFO -Repository $plan.Repository -Message "Finished processing release queue '$($plan.Tag)'."
    }
}

Write-Host ''
Write-Host '========== Download summary ==========' -ForegroundColor Cyan
Write-Host "Successfully downloaded tasks: $successfulTasks"
Write-Host "Tasks skipped after errors: $skippedAfterErrors"
Write-Host "Failed task attempts: $failedAttemptsTotal"
Write-Host "Error log: $script:ErrorLogPath"
if ($failedTasks.Count -gt 0) {
    Write-Host 'Tasks that were skipped after errors:' -ForegroundColor Yellow
    foreach ($failedTaskName in $failedTasks) { Write-Host "  - $failedTaskName" -ForegroundColor Yellow }
}
if ($stoppedByUser) {
    Write-Host 'Download run stopped at your request. Remaining tasks were not started.' -ForegroundColor Yellow
    Write-DownloaderLog -Level WARN -Message 'Run stopped by user before all queued tasks were processed.'
    exit 1
}
if ($skippedAfterErrors -gt 0) {
    Write-Host 'Some downloads failed. Review the error log and rerun the script to resume unfinished tasks.' -ForegroundColor Yellow
    exit 1
}
Write-Host 'All queued downloads finished successfully.' -ForegroundColor Green
Write-DownloaderLog -Level INFO -Message "Run completed. Successful tasks: $successfulTasks; failed attempts: $failedAttemptsTotal; skipped tasks: $skippedAfterErrors."
exit 0
