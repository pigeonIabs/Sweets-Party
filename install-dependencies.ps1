param(
  [switch]$NeedNode,
  [switch]$NeedTunnel,
  [switch]$ForceTunnelRepair,
  [switch]$Diagnose,
  [switch]$RunPreparedGame,
  [switch]$CheckSystemNode
)

$gameArguments = @($args)
if ($RunPreparedGame) { $NeedNode = [switch]$true }
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$minimumNodeVersion = [version]"20.19.0"
$productName = "Kirby's Sweets Party"
$installRoot = ""
$logPath = ""
$statusPath = ""
$errorPath = ""
if ($env:LOCALAPPDATA) {
  $installRoot = Join-Path $env:LOCALAPPDATA "$productName\dependencies"
  $logPath = Join-Path $installRoot "dependency-install.log"
  $statusPath = Join-Path $installRoot "dependency-status.json"
  $errorPath = Join-Path $installRoot "dependency-error.json"
}
$resolvedInstallRoot = $null
$incompatibleNodeMajors = @{}

function Write-InstallerLog([string]$Level, [string]$Message) {
  $line = "{0} [{1}] {2}" -f ([DateTime]::UtcNow.ToString("o")), $Level.ToUpperInvariant(), $Message
  Write-Host $line
  if ($resolvedInstallRoot) {
    try {
      Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
      # Console reporting remains available when the log cannot be written.
    }
  }
}

function New-DependencyException(
  [string]$Code,
  [string]$Summary,
  [string]$Explanation,
  [string[]]$Recovery
) {
  $exception = New-Object System.Exception($Summary)
  $exception.Data["KspCode"] = $Code
  $exception.Data["KspExplanation"] = $Explanation
  $exception.Data["KspRecovery"] = ($Recovery -join "|")
  return $exception
}

function Throw-DependencyError(
  [string]$Code,
  [string]$Summary,
  [string]$Explanation,
  [string[]]$Recovery
) {
  throw (New-DependencyException $Code $Summary $Explanation $Recovery)
}

function Get-ErrorDetails([System.Management.Automation.ErrorRecord]$Record) {
  $exception = $Record.Exception
  if ($exception.Data.Contains("KspCode")) {
    return @{
      code = [string]$exception.Data["KspCode"]
      summary = $exception.Message
      explanation = [string]$exception.Data["KspExplanation"]
      recovery = @(([string]$exception.Data["KspRecovery"]) -split "\|")
    }
  }

  $message = $exception.Message
  $code = "KSP-DEP-900"
  $summary = "Dependency setup encountered an unexpected Windows error."
  $explanation = $message
  $recovery = @("Launch the game again to run automatic repair.", "Review $logPath if the same error returns.")
  if ($exception -is [System.UnauthorizedAccessException] -or $message -match "access.+denied|unauthorized") {
    $code = "KSP-DEP-140"
    $summary = "Windows blocked access to the dependency folder."
    $explanation = "The current Windows account could not create or replace a managed game tool. $message"
    $recovery = @("Allow PowerShell and the game through security software.", "Launch the game again to retry the repair.")
  } elseif ($exception -is [System.Net.WebException] -or $message -match "name resolution|connect|connection|timed out|proxy|remote name|SSL|TLS") {
    $code = "KSP-DEP-110"
    $summary = "The official dependency service could not be reached."
    $explanation = "The download request failed before a verified tool was available. $message"
    $recovery = @("Confirm this computer can reach nodejs.org and github.com.", "Check VPN, proxy, firewall, and security filtering, then launch again.")
  } elseif ($exception -is [System.IO.IOException] -and $message -match "disk|space|full") {
    $code = "KSP-DEP-150"
    $summary = "The dependency drive needs more free space."
    $explanation = $message
    $recovery = @("Free space on the LocalAppData drive.", "Launch the game again to complete the repair.")
  } elseif ($exception -is [System.IO.InvalidDataException] -or $message -match "archive|central directory|compressed") {
    $code = "KSP-DEP-130"
    $summary = "The downloaded dependency archive could not be unpacked."
    $explanation = "The incomplete staging files were cleaned up. $message"
    $recovery = @("Launch the game again to download a fresh archive.", "Check security software if downloaded ZIP files are being modified.")
  }
  return @{ code = $code; summary = $summary; explanation = $explanation; recovery = $recovery }
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
  $temporary = Join-Path $resolvedInstallRoot ".$([IO.Path]::GetFileName($Path))-$([guid]::NewGuid().ToString('N')).tmp"
  $backup = Join-Path $resolvedInstallRoot ".$([IO.Path]::GetFileName($Path))-$([guid]::NewGuid().ToString('N')).backup"
  try {
    $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      [IO.File]::Replace($temporary, $Path, $backup)
      Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    } else {
      Move-Item -LiteralPath $temporary -Destination $Path
    }
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  }
}

function Test-SafeDependencyPath([string]$Path) {
  if (-not $Path -or -not $resolvedInstallRoot) {
    return $false
  }
  try {
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    return $resolvedPath.StartsWith("$resolvedInstallRoot\", [StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Invoke-WithRetry([string]$Operation, [scriptblock]$Action, [int]$Attempts = 3) {
  $lastError = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    try {
      if ($attempt -gt 1) {
        Write-InstallerLog "repair" "$Operation retry $attempt of $Attempts"
      }
      return & $Action $attempt
    } catch {
      $lastError = $_
      if ($_.Exception.Data["KspCode"] -eq "KSP-DEP-150") { throw }
      if ($attempt -lt $Attempts) {
        Write-InstallerLog "diagnostic" "$Operation attempt $attempt failed. $($_.Exception.Message)"
        Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
      }
    }
  }
  throw $lastError
}

function Get-WindowsArchitecture {
  $architecture = $env:PROCESSOR_ARCHITEW6432
  if (-not $architecture) {
    $architecture = $env:PROCESSOR_ARCHITECTURE
  }
  switch -Regex ($architecture) {
    "^(AMD64|x86_64)$" { return @{ node = "x64"; cloudflared = "amd64" } }
    "^(ARM64|AARCH64)$" { return @{ node = "arm64"; cloudflared = "arm64" } }
    "^x86$" { return @{ node = "x86"; cloudflared = "386" } }
    default {
      Throw-DependencyError "KSP-DEP-200" "This Windows processor architecture is unsupported." "Detected architecture '$architecture'." @("Use a 64 bit Intel, AMD, or ARM Windows computer.")
    }
  }
}

function Assert-FreeSpace([long]$RequiredBytes) {
  $root = [IO.Path]::GetPathRoot($resolvedInstallRoot)
  if ($root.StartsWith("\\")) { return } # DriveInfo cannot measure a redirected UNC profile.
  $drive = New-Object IO.DriveInfo($root)
  if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
    Throw-DependencyError "KSP-DEP-150" "The dependency drive needs more free space." "Setup needs at least $([Math]::Ceiling($RequiredBytes / 1MB)) MB free on $root." @("Free space on $root and launch the game again.")
  }
}

function Invoke-VersionProbe([string]$Path, [string]$Arguments) {
  $result = @{ exitCode = $null; stdout = ""; stderr = ""; failure = ""; incompatible = $false }
  $process = New-Object System.Diagnostics.Process
  try {
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    if (-not $process.Start()) {
      $result.failure = "Windows did not start the process."
      return $result
    }

    # Drain both streams without a PowerShell pipeline so the process can exit normally.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($process.WaitForExit(10000)) {
      $result.exitCode = $process.ExitCode
    } else {
      $result.failure = "The version process exceeded its 10 second time limit."
      try { $process.Kill() } catch { }
    }
    $streams = [Threading.Tasks.Task[]]@($stdout, $stderr)
    if (-not [Threading.Tasks.Task]::WaitAll($streams, 1000) -and -not $result.failure) {
      $result.failure = "The version process did not close its output streams."
    }
    if ($stdout.Status -eq "RanToCompletion") { $result.stdout = $stdout.Result }
    if ($stderr.Status -eq "RanToCompletion") { $result.stderr = $stderr.Result }
  } catch {
    $cause = $_.Exception.GetBaseException()
    $result.failure = $cause.Message
    $result.incompatible = $cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -in @(193, 216, 1150)
  } finally {
    $process.Dispose()
  }
  return $result
}

function Format-ProbeOutput([string]$Output) {
  $line = ($Output -replace "\s+", " ").Trim()
  if ($line.Length -gt 400) { return $line.Substring(0, 400) + "..." }
  if ($line) { return $line }
  return "(empty)"
}

function Get-VersionFailure([string]$Path, [string]$Tool) {
  $arguments = if ($Tool -eq "node") { "-p process.versions.node" } else { "version" }
  $probe = Invoke-VersionProbe $Path $arguments
  $exitCode = if ($null -eq $probe.exitCode) { "unavailable" } else { $probe.exitCode }
  $output = "Stdout [$(Format-ProbeOutput $probe.stdout)] Stderr [$(Format-ProbeOutput $probe.stderr)]"
  $diagnostic = "Process exit code $exitCode. $output"
  # Bad executable format, illegal CPU instruction, or an unavailable Windows entry point.
  if ($Tool -eq "node" -and ($probe.incompatible -or $probe.exitCode -in @(-1073741701, -1073741795, -1073741511))) {
    return @{ stage = "Windows compatibility"; detail = "$($probe.failure) $diagnostic"; keep = $true; incompatible = $true }
  }
  if ($probe.failure) {
    return @{ stage = "version process"; detail = "$($probe.failure) $diagnostic"; retry = $true; keep = $true }
  }
  if ($probe.exitCode -ne 0) {
    return @{ stage = "version exit code"; detail = $diagnostic; retry = $true; keep = $true }
  }
  if ($Tool -eq "node") {
    $version = $null
    $versionText = $probe.stdout.Trim()
    if ($versionText -notmatch "^\d+\.\d+\.\d+$" -or -not [version]::TryParse($versionText, [ref]$version)) {
      return @{ stage = "version response"; detail = "Expected a Node.js version number. $diagnostic"; keep = $true }
    }
    if ($version -lt $minimumNodeVersion) {
      return @{ stage = "minimum version"; detail = "Node.js $version is below the required $minimumNodeVersion. $diagnostic" }
    }
  } elseif ("$($probe.stdout)`n$($probe.stderr)" -notmatch "(?im)^\s*cloudflared version\s+\d") {
    return @{ stage = "version response"; detail = "Expected a Cloudflare Tunnel version. $diagnostic"; keep = $true }
  }
  Write-InstallerLog "diagnostic" "$Tool version check passed for $Path. $diagnostic"
  return $null
}

function Get-CloudflarePublisherFailure([string]$Path) {
  try {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $publisher = $signature.SignerCertificate.Subject
    if ($signature.Status -eq "Valid" -and $publisher -match "Cloudflare") { return $null }
    return @{
      stage = "publisher signature"
      detail = "Authenticode status $($signature.Status). Publisher [$(Format-ProbeOutput $publisher)]. $($signature.StatusMessage)"
      retry = $true
    }
  } catch {
    return @{ stage = "publisher signature"; detail = $_.Exception.Message; retry = $true }
  }
}

function Get-RuntimeFailure([string]$Path, [string]$Tool) {
  $attempts = 3
  for ($attempt = 1; $attempt -le $attempts; $attempt += 1) {
    if (-not (Test-SafeDependencyPath $Path)) {
      $failure = @{ stage = "path safety"; detail = "The executable is outside the managed dependency folder." }
    } elseif (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      $failure = @{ stage = "executable lookup"; detail = "The executable file is missing." }
    } elseif ($Tool -eq "node" -and (Test-Path -LiteralPath "$Path.sha256" -PathType Leaf) -and -not (Test-VerifiedNodeExecutable $Path)) {
      $failure = @{ stage = "cached executable integrity"; detail = "The executable differs from its installation checksum. Setup will look for a verified replacement." }
    } else {
      $failure = if ($Tool -eq "cloudflared") { Get-CloudflarePublisherFailure $Path }
      if (-not $failure) { $failure = Get-VersionFailure $Path $Tool }
    }
    if (-not $failure) { return $null }
    Write-InstallerLog "diagnostic" "$Tool $($failure.stage) failed for $Path on attempt $attempt of ${attempts}. $($failure.detail)"
    if (-not $failure.retry -or $attempt -eq $attempts) { return $failure }
    Start-Sleep -Milliseconds (200 * $attempt)
  }
}

function Throw-RuntimeFailure([string]$Tool, [hashtable]$Failure, [bool]$Retained) {
  $code = "KSP-DEP-131"
  $name = "Node.js"
  $recovery = @("See $logPath for the executable path and validation details.")
  if ($Tool -eq "cloudflared") {
    $name = "Cloudflare Tunnel"
    $code = if ($Failure.stage -eq "publisher signature") { "KSP-DEP-121" } else { "KSP-DEP-205" }
    if ($Failure.stage -eq "publisher signature") {
      $recovery += "Check Windows trusted root certificates and security software."
    }
  }
  $explanation = $Failure.detail
  if ($Retained) {
    $explanation += " Setup kept the verified executable for reuse."
  }
  Throw-DependencyError $code "$name failed the $($Failure.stage) check." $explanation $recovery
}

function Set-DependencyPointer([string]$Name, [string]$Path) {
  if (-not (Test-SafeDependencyPath $Path)) {
    Throw-DependencyError "KSP-DEP-160" "A dependency path failed its safety check." "The resolved tool path was outside the managed dependency folder." @("Launch the game again to rebuild its managed dependency pointers.")
  }
  $destination = Join-Path $resolvedInstallRoot $Name
  $temporary = Join-Path $resolvedInstallRoot ".$Name-$([guid]::NewGuid().ToString('N')).tmp"
  $backup = Join-Path $resolvedInstallRoot ".$Name-$([guid]::NewGuid().ToString('N')).backup"
  [IO.File]::WriteAllText($temporary, "$Path`r`n", (New-Object Text.UTF8Encoding($false)))
  try {
    for ($attempt = 1; $attempt -le 10; $attempt += 1) {
      try {
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
          [IO.File]::Replace($temporary, $destination, $backup)
          Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
          Move-Item -LiteralPath $temporary -Destination $destination
        }
        return
      } catch {
        if ($attempt -eq 10) { throw }
        Start-Sleep -Milliseconds (50 * $attempt)
      }
    }
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  }
}

function Get-PointerCandidate([string]$Name) {
  $pointer = Join-Path $resolvedInstallRoot $Name
  if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) {
    return $null
  }
  try {
    return [IO.File]::ReadAllText($pointer).Trim()
  } catch {
    Write-InstallerLog "repair" "Could not read $pointer. Installed tools will be rediscovered. $($_.Exception.Message)"
  }
  return $null
}

function Test-VerifiedNodeExecutable([string]$Path) {
  try {
    $checksumPath = "$Path.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { return $false }
    $checksum = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
    return $checksum -match "^[a-fA-F0-9]{64}$" -and (Get-Sha256 $Path) -eq $checksum
  } catch {
    Write-InstallerLog "diagnostic" "Could not read the cached Node.js integrity record for $Path. $($_.Exception.Message)"
    return $false
  }
}

function Remember-IncompatibleNode([string]$Path, [hashtable]$Failure) {
  if (-not $Failure.incompatible) { return $false }
  $relative = $Path.Substring($resolvedInstallRoot.Length + 1)
  if ($relative -match "^node-v(\d+)\.\d+\.\d+-$($architecture.node)(?:-repair-[a-f0-9]+)?\\") {
    $incompatibleNodeMajors[$Matches[1]] = $true
  }
  return $true
}

function Find-InstalledRuntime([string]$Tool, [bool]$Required) {
  $pointerName = "$Tool-path.txt"
  $pointerCandidate = Get-PointerCandidate $pointerName
  $verifiedFailure = $null
  if ($pointerCandidate) {
    $failure = Get-RuntimeFailure $pointerCandidate $Tool
    if (-not $failure) { return $pointerCandidate }
    if ($failure.keep -and ($Tool -eq "cloudflared" -or (Test-VerifiedNodeExecutable $pointerCandidate))) {
      if (-not (Remember-IncompatibleNode $pointerCandidate $failure)) { $verifiedFailure = $failure }
    }
  }

  $files = if ($Tool -eq "node") {
    Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter "node-*" -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter node.exe -Recurse -File -ErrorAction SilentlyContinue }
  } else {
    Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter "cloudflared-*.exe" -File -ErrorAction SilentlyContinue
  }
  foreach ($file in ($files | Sort-Object LastWriteTimeUtc -Descending)) {
    $candidate = $file.FullName
    if (-not $candidate -or $candidate -eq $pointerCandidate) { continue }
    $failure = Get-RuntimeFailure $candidate $Tool
    if (-not $failure) {
      Set-DependencyPointer $pointerName $candidate
      Write-InstallerLog "repair" "Recovered $Tool from an existing installation"
      return $candidate
    }
    if (-not $verifiedFailure -and $failure.keep -and ($Tool -eq "cloudflared" -or (Test-VerifiedNodeExecutable $candidate))) {
      if (-not (Remember-IncompatibleNode $candidate $failure)) { $verifiedFailure = $failure }
    }
  }
  if ($Required -and $verifiedFailure) { Throw-RuntimeFailure $Tool $verifiedFailure $true }
  return $null
}

function Get-Sha256([string]$Path) {
  $stream = $null
  $hasher = $null
  try {
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    $bytes = $hasher.ComputeHash($stream)
    $actual = [BitConverter]::ToString($bytes).Replace("-", "")
  } finally {
    if ($hasher) { $hasher.Dispose() }
    if ($stream) { $stream.Dispose() }
  }
  return $actual
}

function Assert-Sha256([string]$Path, [string]$Expected) {
  $actual = Get-Sha256 $Path
  if ($actual -ne $Expected.ToUpperInvariant()) {
    Throw-DependencyError "KSP-DEP-120" "A downloaded dependency failed its integrity check." "The SHA256 checksum differed from the publisher value. The untrusted file was removed." @("Launch the game again for a clean download.", "Check proxy and security software if downloads are being modified.")
  }
}

function Invoke-PublisherRequest([string]$Uri, [string]$Path, [int]$Attempt) {
  $timeout = if ($Path) { 120 } else { 30 }
  $curl = Join-Path ([Environment]::SystemDirectory) "curl.exe"
  $partial = $Path -and (Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -gt 0
  if (($Attempt -gt 1 -or $partial) -and (Test-Path -LiteralPath $curl -PathType Leaf)) {
    Write-InstallerLog "repair" "Retrying the publisher request with Windows curl"
    $options = @("--disable", "--silent", "--show-error", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "$timeout", "--user-agent", "Kirby-Sweets-Party-Installer")
    if ($Path) { $options += @("--output", $Path) }
    if ($partial) { $options += @("--continue-at", "-") }
    $lines = & $curl @options $Uri
    $code = $LASTEXITCODE
    if ($code -ne 0) {
      # Some proxies and publishers reject range requests. Restart the next attempt at byte zero.
      if ($partial -and $code -in @(22, 33, 36)) { Remove-Item -LiteralPath $Path -Force }
      throw "Windows curl returned exit code $code for $Uri."
    }
    if (-not $Path) { return ($lines -join "`n") }
    return
  }
  $options = @{ UseBasicParsing = $true; TimeoutSec = $timeout; Uri = $Uri; UserAgent = "Kirby-Sweets-Party-Installer" }
  if ($Path) {
    Invoke-WebRequest @options -OutFile $Path
    return
  }
  $content = (Invoke-WebRequest @options).Content
  if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
  return $content
}

function Save-DependencyDownload([string]$Operation, [string]$Uri, [string]$Path, [string]$Checksum) {
  Invoke-WithRetry $Operation {
    param($number)
    Invoke-PublisherRequest $Uri $Path $number
    if ($Checksum) {
      try { Assert-Sha256 $Path $Checksum } catch {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw
      }
    }
  }
}

function Install-NodeRuntime([hashtable]$Architecture) {
  Write-InstallerLog "setup" "Resolving the current official Node.js LTS release for Windows $($Architecture.node)"
  try {
    $releases = Invoke-WithRetry "Node.js release lookup" {
      param($number)
      $index = Invoke-PublisherRequest "https://nodejs.org/dist/index.json" "" $number
      ConvertFrom-Json -InputObject $index
    }
  } catch {
    Throw-DependencyError "KSP-DEP-101" "Node.js release information could not be downloaded." $_.Exception.Message @("Confirm access to nodejs.org.", "Launch the game again to retry automatically.")
  }
  $releasesForMachine = $releases | Where-Object {
    $_.lts -and $_.files -contains "win-$($Architecture.node)-zip" -and
      $_.version -match '^v\d+\.\d+\.\d+$' -and [version]($_.version.Substring(1)) -ge $minimumNodeVersion
  }
  foreach ($release in $releasesForMachine) {
    $major = ([version]($release.version.Substring(1))).Major.ToString()
    if ($incompatibleNodeMajors.ContainsKey($major)) { continue }
    try {
      return Install-NodeRelease $Architecture $release
    } catch {
      if ($_.Exception.Data["KspCode"] -ne "KSP-DEP-132") { throw }
      $incompatibleNodeMajors[$major] = $true
      Write-InstallerLog "repair" "Windows cannot run Node.js $($release.version). Trying the next compatible LTS line."
    }
  }
  Throw-DependencyError "KSP-DEP-102" "No usable Node.js LTS release was available for Windows $($Architecture.node)." "Setup checked the publisher's architecture list and requires at least $minimumNodeVersion." @("Use a Windows installation that can run a supported Node.js runtime.")
}

function Expand-NodeExecutable([string]$Archive, [string]$EntryName, [string]$Destination) {
  Invoke-WithRetry "Extracting the verified Node.js executable" {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
      $entry = $zip.GetEntry($EntryName)
      if (-not $entry) { throw "The publisher archive is missing $EntryName." }
      Assert-FreeSpace $entry.Length
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Destination, $true)
    } finally {
      $zip.Dispose()
    }
  }
}

function Install-NodeRelease([hashtable]$Architecture, $release) {
  $archiveName = "node-$($release.version)-win-$($Architecture.node).zip"
  $baseUrl = "https://nodejs.org/dist/$($release.version)"
  try {
    $checksums = Invoke-WithRetry "Node.js checksum lookup" {
      param($number)
      Invoke-PublisherRequest "$baseUrl/SHASUMS256.txt" "" $number
    }
  } catch {
    Throw-DependencyError "KSP-DEP-103" "Node.js checksum information could not be downloaded." $_.Exception.Message @("Confirm access to nodejs.org.", "Launch the game again to retry automatically.")
  }
  $checksumMatch = [regex]::Match($checksums, "(?im)^([a-f0-9]{64})[ \t]+$([regex]::Escape($archiveName))\r?$")
  $exeName = "win-$($Architecture.node)/node.exe"
  $exeChecksum = [regex]::Match($checksums, "(?im)^([a-f0-9]{64})[ \t]+$([regex]::Escape($exeName))\r?$")
  if (-not $checksumMatch.Success -and -not $exeChecksum.Success) {
    Throw-DependencyError "KSP-DEP-104" "The Node.js release has no verified Windows download for this processor." "Expected $archiveName or $exeName in the publisher checksum list." @("Launch again after the publisher has synchronized its release files.")
  }

  $operationId = [guid]::NewGuid().ToString('N')
  $download = Join-Path $resolvedInstallRoot $archiveName
  $stagedNode = Join-Path $resolvedInstallRoot ".node-install.pending.exe"
  try {
    $checksum = $checksumMatch.Groups[1].Value
    try {
      if (-not $checksumMatch.Success) { throw "The publisher lists only the standalone executable." }
      $haveArchive = (Test-Path -LiteralPath $download -PathType Leaf) -and (Get-Sha256 $download) -eq $checksum
      if ($haveArchive) {
        Write-InstallerLog "repair" "Resuming from the previously downloaded and verified $archiveName"
      } else {
        Write-InstallerLog "setup" "Downloading Node.js $($release.version)"
        Save-DependencyDownload "Node.js archive download and checksum" "$baseUrl/$archiveName" $download $checksum
      }
      $entryName = [IO.Path]::GetFileNameWithoutExtension($archiveName) + "/node.exe"
      Expand-NodeExecutable $download $entryName $stagedNode
    } catch {
      if (-not $exeChecksum.Success) { throw }
      Write-InstallerLog "repair" "ZIP setup failed. $($_.Exception.Message) Trying the publisher's separately checksummed executable."
      Remove-Item -LiteralPath $download,$stagedNode -Force -ErrorAction SilentlyContinue
      Save-DependencyDownload "Standalone Node.js download and checksum" "$baseUrl/$exeName" $stagedNode $exeChecksum.Groups[1].Value
    }
    $versionRoot = Join-Path $resolvedInstallRoot "node-$($release.version)-$($Architecture.node)"
    if (Test-Path -LiteralPath $versionRoot) {
      $versionRoot = Join-Path $resolvedInstallRoot "node-$($release.version)-$($Architecture.node)-repair-$operationId"
    }
    $failure = Get-RuntimeFailure $stagedNode "node"
    if ($failure -and -not $failure.keep) {
      Throw-RuntimeFailure "node" $failure $false
    }
    New-Item -ItemType Directory -Path $versionRoot | Out-Null
    $node = Join-Path $versionRoot "node.exe"
    Set-Content -LiteralPath "$node.sha256" -Value (Get-Sha256 $stagedNode) -Encoding ASCII
    Invoke-WithRetry "Installing the verified Node.js executable" {
      [IO.File]::Move($stagedNode, $node)
    }
    if ($failure.incompatible) {
      Throw-DependencyError "KSP-DEP-132" "Windows cannot run this Node.js release." $failure.detail @("Try another compatible LTS release.")
    }
    if ($failure) { Throw-RuntimeFailure "node" $failure $true }
    Set-DependencyPointer "node-path.txt" $node
    Write-InstallerLog "ready" "Node.js $($release.version) is verified and ready"
    return $node
  } finally {
    Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stagedNode -Force -ErrorAction SilentlyContinue
  }
}

function Install-Cloudflared([hashtable]$Architecture, [bool]$ForceRepair = $false) {
  if ($ForceRepair) {
    Write-InstallerLog "repair" "A failed launch requested a fresh verified Cloudflare Tunnel executable"
  }

  Write-InstallerLog "setup" "Resolving the current official Cloudflare Tunnel release for Windows $($Architecture.cloudflared)"
  $assetName = "cloudflared-windows-$($Architecture.cloudflared).exe"
  try {
    $release = Invoke-WithRetry "Cloudflare release lookup" {
      param($number)
      $metadata = Invoke-PublisherRequest "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" "" $number
      ConvertFrom-Json -InputObject $metadata
    }
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    $version = $release.tag_name -replace "[^0-9A-Za-z._-]", ""
  } catch {
    Write-InstallerLog "repair" "GitHub release metadata is unavailable. Trying Cloudflare's official latest release download with required Windows publisher verification."
    $asset = @{ browser_download_url = "https://github.com/cloudflare/cloudflared/releases/latest/download/$assetName" }
    $version = "latest"
  }
  if (-not $asset.browser_download_url) {
    Throw-DependencyError "KSP-DEP-202" "A compatible Cloudflare Tunnel download was not listed." "Expected the publisher release asset $assetName." @("Launch again later after the Cloudflare release files are synchronized.")
  }
  if ($asset.size -gt 0) { Assert-FreeSpace $asset.size }

  $operationId = [guid]::NewGuid().ToString('N')
  $cloudflared = Join-Path $resolvedInstallRoot "cloudflared-$version-$($Architecture.cloudflared).exe"
  if (Test-Path -LiteralPath $cloudflared) {
    $cloudflared = Join-Path $resolvedInstallRoot "cloudflared-$version-$($Architecture.cloudflared)-repair-$operationId.exe"
  }
  $stagingFile = Join-Path $resolvedInstallRoot ".cloudflared-stage-$operationId.exe"
  try {
    Write-InstallerLog "setup" "Downloading verified Cloudflare Tunnel $version"
    $checksum = if ($asset.digest -and $asset.digest.StartsWith("sha256:")) { $asset.digest.Substring(7) }
    if (-not $checksum) {
      Write-InstallerLog "diagnostic" "The release API omitted a SHA256 digest, so Windows publisher signature verification is authoritative"
    }
    try {
      Save-DependencyDownload "Cloudflare executable download and checksum" $asset.browser_download_url $stagingFile $checksum
    } catch {
      if ($_.Exception.Data["KspCode"]) { throw }
      Throw-DependencyError "KSP-DEP-203" "The Cloudflare Tunnel download did not complete." $_.Exception.Message @("Confirm access to github.com.", "Launch the game again to resume automatic setup.")
    }
    $failure = Get-RuntimeFailure $stagingFile "cloudflared"
    if ($failure -and -not $failure.keep) {
      Throw-RuntimeFailure "cloudflared" $failure $false
    }
    Invoke-WithRetry "Installing the verified Cloudflare Tunnel executable" {
      [IO.File]::Move($stagingFile, $cloudflared)
    }
    if ($failure) { Throw-RuntimeFailure "cloudflared" $failure $true }
    Set-DependencyPointer "cloudflared-path.txt" $cloudflared
    Write-InstallerLog "ready" "Cloudflare Tunnel $version is verified and ready"
    return $cloudflared
  } finally {
    Remove-Item -LiteralPath $stagingFile -Force -ErrorAction SilentlyContinue
  }
}

if ($CheckSystemNode) {
  $problem = Get-VersionFailure $env:KSP_NODE_CANDIDATE "node"
  if ($problem) { exit 37 }
  exit 0
}

try {
  if (-not $env:LOCALAPPDATA) {
    Throw-DependencyError "KSP-DEP-001" "Windows could not locate the LocalAppData folder." "The LOCALAPPDATA environment value is empty." @("Sign out of Windows and sign in again, then launch the game.")
  }
  $resolvedLocalAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd("\")
  $resolvedInstallRoot = [IO.Path]::GetFullPath($installRoot).TrimEnd("\")
  if (-not $resolvedInstallRoot.StartsWith("$resolvedLocalAppData\", [StringComparison]::OrdinalIgnoreCase)) {
    Throw-DependencyError "KSP-DEP-002" "The dependency folder failed its safety check." "The resolved dependency folder was outside the current Windows profile." @("Restore the standard LOCALAPPDATA value and launch again.")
  }
  New-Item -ItemType Directory -Path $resolvedInstallRoot -Force | Out-Null
  Write-InstallerLog "diagnostic" "Dependency setup started with PowerShell $($PSVersionTable.PSVersion)"
  $architecture = Get-WindowsArchitecture

  $account = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $installMutex = New-Object Threading.Mutex($false, "Global\KirbySweetsPartyDependencyInstaller-$account")
  $ownsMutex = $false
  try {
    try {
      $ownsMutex = $installMutex.WaitOne(0)
      if (-not $ownsMutex) {
        Write-InstallerLog "repair" "Another launcher is preparing dependencies. Waiting to reuse its result."
        $ownsMutex = $installMutex.WaitOne([TimeSpan]::FromMinutes(15))
      }
    } catch [Threading.AbandonedMutexException] {
      $ownsMutex = $true
      Write-InstallerLog "repair" "Recovered an interrupted dependency setup lock"
    }
    if (-not $ownsMutex) {
      Throw-DependencyError "KSP-DEP-010" "Another dependency repair is still running." "Setup waited fifteen minutes for the shared dependency lock." @("Check the other launcher and its dependency log.")
    }

    $inventory = -not ($NeedNode -or $NeedTunnel)
    $nodePath = if ($NeedNode -or $inventory) { Find-InstalledRuntime "node" $NeedNode.IsPresent }
    $tunnelPath = if (($NeedTunnel -or $inventory) -and -not $ForceTunnelRepair) { Find-InstalledRuntime "cloudflared" $NeedTunnel.IsPresent }
    if ($NeedNode -and -not $nodePath) { $nodePath = Install-NodeRuntime $architecture }
    if ($NeedTunnel -and -not $tunnelPath) { $tunnelPath = Install-Cloudflared $architecture $ForceTunnelRepair }

    $detectedArchitecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $detectedArchitecture) { $detectedArchitecture = $env:PROCESSOR_ARCHITECTURE }
    $status = [ordered]@{
      schemaVersion = 1
      checkedAtUtc = [DateTime]::UtcNow.ToString("o")
      architecture = $detectedArchitecture
      node = if ($nodePath) { [ordered]@{ state = "ready"; path = $nodePath } } else { [ordered]@{ state = "not-requested" } }
      tunnel = if ($tunnelPath) {
        [ordered]@{
          state = "ready"
          path = $tunnelPath
          sha256 = Get-Sha256 $tunnelPath
        }
      } else {
        [ordered]@{ state = "not-requested" }
      }
    }
    if (-not $inventory -and (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
      try {
        $previous = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
        if (-not $NeedTunnel -and $previous.tunnel) { $status.tunnel = $previous.tunnel }
        if (-not $NeedNode -and $previous.node) { $status.node = $previous.node }
      } catch {
        Write-InstallerLog "repair" "Rebuilding an unreadable dependency status record."
      }
    }
    try {
      Invoke-WithRetry "Saving dependency status" { Write-JsonAtomic $statusPath $status }
    } catch {
      if (-not $RunPreparedGame) { throw }
      Write-InstallerLog "repair" "The runtime is ready. Starting the game despite a status file write failure. $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    if ($Diagnose) {
      Write-Host ($status | ConvertTo-Json -Depth 6)
    }
    Write-InstallerLog "ready" "Dependency diagnosis and repair completed"
  } finally {
    if ($ownsMutex) { $installMutex.ReleaseMutex() }
    if ($installMutex) { $installMutex.Dispose() }
  }
} catch {
  $details = Get-ErrorDetails $_
  $failure = [ordered]@{
    schemaVersion = 1
    occurredAtUtc = [DateTime]::UtcNow.ToString("o")
    code = $details.code
    summary = $details.summary
    explanation = $details.explanation
    recovery = $details.recovery
    technical = $_.Exception.ToString()
    logPath = $logPath
  }
  if ($resolvedInstallRoot -and (Test-Path -LiteralPath $resolvedInstallRoot -PathType Container)) {
    try { Write-JsonAtomic $errorPath $failure } catch { }
  }
  Write-Host ""
  Write-Host "Dependency repair $($details.code)"
  Write-Host $details.summary
  Write-Host $details.explanation
  foreach ($step in $details.recovery) { Write-Host "  - $step" }
  if ($logPath) { Write-Host "Diagnostic log  $logPath" }
  if ($RunPreparedGame) { exit 79 }
  exit 1
}

if ($RunPreparedGame) {
  # Start after releasing the installer lock so the host can prepare a tunnel on demand.
  & $nodePath (Join-Path $PSScriptRoot "host.mjs") @gameArguments
  exit $LASTEXITCODE
}
exit 0
