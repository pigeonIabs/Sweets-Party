param(
  [switch]$NeedNode,
  [switch]$NeedTunnel,
  [switch]$ForceTunnelRepair,
  [switch]$Diagnose
)

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
      return & $Action
    } catch {
      $lastError = $_
      if ($attempt -lt $Attempts) {
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
  $drive = New-Object IO.DriveInfo($root)
  if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
    Throw-DependencyError "KSP-DEP-150" "The dependency drive needs more free space." "Setup needs at least $([Math]::Ceiling($RequiredBytes / 1MB)) MB free on $root." @("Free space on $root and launch the game again.")
  }
}

function Test-NodeRuntime([string]$Path) {
  if (-not (Test-SafeDependencyPath $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }
  try {
    $versionText = (& $Path -p "process.versions.node" 2>$null | Select-Object -First 1)
    return ($LASTEXITCODE -eq 0 -and $versionText -and [version]$versionText -ge $minimumNodeVersion)
  } catch {
    return $false
  }
}

function Test-CloudflaredRuntime([string]$Path) {
  if (-not (Test-SafeDependencyPath $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }
  for ($attempt = 1; $attempt -le 3; $attempt += 1) {
    try {
      $signature = Get-AuthenticodeSignature -LiteralPath $Path
      $versionText = (& $Path version 2>$null | Select-Object -First 1)
      if (
        $signature.Status -eq "Valid" -and
        $signature.SignerCertificate.Subject -match "Cloudflare" -and
        $LASTEXITCODE -eq 0 -and
        $versionText -match "cloudflared version"
      ) {
        return $true
      }
    } catch {
      # Windows signature services can be briefly unavailable while a new executable is scanned.
    }
    if ($attempt -lt 3) {
      Start-Sleep -Milliseconds (200 * $attempt)
    }
  }
  return $false
}

function Set-DependencyPointer([string]$Name, [string]$Path) {
  if (-not (Test-SafeDependencyPath $Path)) {
    Throw-DependencyError "KSP-DEP-160" "A dependency path failed its safety check." "The resolved tool path was outside the managed dependency folder." @("Launch the game again to rebuild its managed dependency pointers.")
  }
  $destination = Join-Path $resolvedInstallRoot $Name
  $temporary = Join-Path $resolvedInstallRoot ".$Name-$([guid]::NewGuid().ToString('N')).tmp"
  $backup = Join-Path $resolvedInstallRoot ".$Name-$([guid]::NewGuid().ToString('N')).backup"
  [IO.File]::WriteAllText($temporary, "$Path`r`n", [Text.Encoding]::ASCII)
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

function Get-PointerCandidate([string]$Name, [scriptblock]$Validator) {
  $pointer = Join-Path $resolvedInstallRoot $Name
  if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) {
    return $null
  }
  try {
    $candidate = (Get-Content -LiteralPath $pointer -Raw).Trim()
    if (& $Validator $candidate) {
      return $candidate
    }
  } catch {
    # Discovery below can recover another verified runtime.
  }
  Write-InstallerLog "repair" "The saved $Name target needs validation, so installed tools are being rediscovered"
  return $null
}

function Find-InstalledNodeRuntime {
  $pointerCandidate = Get-PointerCandidate "node-path.txt" ${function:Test-NodeRuntime}
  if ($pointerCandidate) { return $pointerCandidate }
  $candidates = Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter node.exe -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -ExpandProperty FullName
  foreach ($candidate in $candidates) {
    if (Test-NodeRuntime $candidate) {
      Set-DependencyPointer "node-path.txt" $candidate
      Write-InstallerLog "repair" "Recovered Node.js from an existing verified installation"
      return $candidate
    }
  }
  return $null
}

function Find-InstalledCloudflaredRuntime {
  $pointerCandidate = Get-PointerCandidate "cloudflared-path.txt" ${function:Test-CloudflaredRuntime}
  if ($pointerCandidate) { return $pointerCandidate }
  $candidates = Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter "cloudflared-*.exe" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -ExpandProperty FullName
  foreach ($candidate in $candidates) {
    if (Test-CloudflaredRuntime $candidate) {
      Set-DependencyPointer "cloudflared-path.txt" $candidate
      Write-InstallerLog "repair" "Recovered Cloudflare Tunnel from an existing verified installation"
      return $candidate
    }
  }
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

function Install-NodeRuntime([hashtable]$Architecture) {
  $installed = Find-InstalledNodeRuntime
  if ($installed) { return $installed }

  Assert-FreeSpace 250MB
  Write-InstallerLog "setup" "Resolving the current official Node.js LTS release for Windows $($Architecture.node)"
  try {
    $releases = Invoke-WithRetry "Node.js release lookup" { Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Uri "https://nodejs.org/dist/index.json" }
  } catch {
    Throw-DependencyError "KSP-DEP-101" "Node.js release information could not be downloaded." $_.Exception.Message @("Confirm access to nodejs.org.", "Launch the game again to retry automatically.")
  }
  $release = $releases | Where-Object { $_.lts -and [version]($_.version.TrimStart("v")) -ge $minimumNodeVersion } | Select-Object -First 1
  if (-not $release.version) {
    Throw-DependencyError "KSP-DEP-102" "A compatible Node.js LTS release was not listed." "The publisher response contained no Windows release at or above $minimumNodeVersion." @("Launch again later after the Node.js release service is available.")
  }

  $archiveName = "node-$($release.version)-win-$($Architecture.node).zip"
  $baseUrl = "https://nodejs.org/dist/$($release.version)"
  try {
    $checksums = Invoke-WithRetry "Node.js checksum lookup" { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri "$baseUrl/SHASUMS256.txt").Content }
  } catch {
    Throw-DependencyError "KSP-DEP-103" "Node.js checksum information could not be downloaded." $_.Exception.Message @("Confirm access to nodejs.org.", "Launch the game again to retry automatically.")
  }
  $checksumMatch = [regex]::Match($checksums, "(?im)^([a-f0-9]{64})\s+$([regex]::Escape($archiveName))$")
  if (-not $checksumMatch.Success) {
    Throw-DependencyError "KSP-DEP-104" "The compatible Node.js archive was missing from its signed release list." "Expected $archiveName in the publisher checksum list." @("Launch again later after the Node.js release files are synchronized.")
  }

  $operationId = [guid]::NewGuid().ToString('N')
  $download = Join-Path $env:TEMP "$archiveName-$operationId.zip"
  $stagingRoot = Join-Path $resolvedInstallRoot ".node-stage-$operationId"
  try {
    Write-InstallerLog "setup" "Downloading verified Node.js $($release.version)"
    try {
      Invoke-WithRetry "Node.js archive download" { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri "$baseUrl/$archiveName" -OutFile $download }
    } catch {
      Throw-DependencyError "KSP-DEP-105" "The Node.js archive download did not complete." $_.Exception.Message @("Confirm access to nodejs.org.", "Launch the game again to resume automatic setup.")
    }
    Assert-Sha256 $download $checksumMatch.Groups[1].Value
    $versionRoot = Join-Path $resolvedInstallRoot "node-$($release.version)-$($Architecture.node)"
    if (Test-Path -LiteralPath $versionRoot) {
      $versionRoot = Join-Path $resolvedInstallRoot "node-$($release.version)-$($Architecture.node)-repair-$operationId"
    }
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    Expand-Archive -LiteralPath $download -DestinationPath $stagingRoot
    $stagedNode = Get-ChildItem -LiteralPath $stagingRoot -Filter node.exe -Recurse -File | Select-Object -First 1
    if (-not $stagedNode -or -not (Test-NodeRuntime $stagedNode.FullName)) {
      Throw-DependencyError "KSP-DEP-131" "The Node.js archive did not produce a compatible runtime." "The extracted node.exe was missing or older than $minimumNodeVersion." @("Launch the game again for a clean verified download.")
    }
    $relativeNode = $stagedNode.FullName.Substring($stagingRoot.Length).TrimStart("\")
    Move-Item -LiteralPath $stagingRoot -Destination $versionRoot
    $node = Join-Path $versionRoot $relativeNode
    Set-DependencyPointer "node-path.txt" $node
    Write-InstallerLog "ready" "Node.js $($release.version) is verified and ready"
    return $node
  } finally {
    Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Install-Cloudflared([hashtable]$Architecture, [bool]$ForceRepair = $false) {
  if (-not $ForceRepair) {
    $installed = Find-InstalledCloudflaredRuntime
    if ($installed) { return $installed }
  } else {
    Write-InstallerLog "repair" "A failed launch requested a fresh verified Cloudflare Tunnel executable"
  }

  Assert-FreeSpace 100MB
  Write-InstallerLog "setup" "Resolving the current official Cloudflare Tunnel release for Windows $($Architecture.cloudflared)"
  $headers = @{ Accept = "application/vnd.github+json"; "User-Agent" = "Kirby-Sweets-Party-Installer" }
  try {
    $release = Invoke-WithRetry "Cloudflare release lookup" { Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Headers $headers -Uri "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" }
  } catch {
    Throw-DependencyError "KSP-DEP-201" "Cloudflare release information could not be downloaded." $_.Exception.Message @("Confirm access to api.github.com.", "Launch the game again to retry automatically.")
  }
  $assetName = "cloudflared-windows-$($Architecture.cloudflared).exe"
  $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
  if (-not $asset.browser_download_url) {
    Throw-DependencyError "KSP-DEP-202" "A compatible Cloudflare Tunnel download was not listed." "Expected the publisher release asset $assetName." @("Launch again later after the Cloudflare release files are synchronized.")
  }

  $version = $release.tag_name -replace "[^0-9A-Za-z._-]", ""
  $operationId = [guid]::NewGuid().ToString('N')
  $cloudflared = Join-Path $resolvedInstallRoot "cloudflared-$version-$($Architecture.cloudflared).exe"
  if (Test-Path -LiteralPath $cloudflared) {
    $cloudflared = Join-Path $resolvedInstallRoot "cloudflared-$version-$($Architecture.cloudflared)-repair-$operationId.exe"
  }
  $stagingFile = Join-Path $resolvedInstallRoot ".cloudflared-stage-$operationId.exe"
  try {
    Write-InstallerLog "setup" "Downloading verified Cloudflare Tunnel $version"
    try {
      Invoke-WithRetry "Cloudflare executable download" { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $asset.browser_download_url -OutFile $stagingFile }
    } catch {
      Throw-DependencyError "KSP-DEP-203" "The Cloudflare Tunnel download did not complete." $_.Exception.Message @("Confirm access to github.com.", "Launch the game again to resume automatic setup.")
    }
    if ($asset.digest -and $asset.digest.StartsWith("sha256:")) {
      Assert-Sha256 $stagingFile $asset.digest.Substring(7)
    } else {
      Write-InstallerLog "diagnostic" "The release API omitted a SHA256 digest, so Windows publisher signature verification is authoritative"
    }
    if (-not (Test-CloudflaredRuntime $stagingFile)) {
      Throw-DependencyError "KSP-DEP-121" "Cloudflare Tunnel failed Windows publisher verification." "The executable was not signed by a currently trusted Cloudflare certificate. The untrusted file was removed." @("Update Windows trusted root certificates.", "Check proxy and security software, then launch again.")
    }
    Move-Item -LiteralPath $stagingFile -Destination $cloudflared
    Set-DependencyPointer "cloudflared-path.txt" $cloudflared
    Write-InstallerLog "ready" "Cloudflare Tunnel $version is verified and ready"
    return $cloudflared
  } finally {
    Remove-Item -LiteralPath $stagingFile -Force -ErrorAction SilentlyContinue
  }
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

  $installMutex = New-Object Threading.Mutex($false, "Local\KirbySweetsPartyDependencyInstaller")
  $ownsMutex = $false
  try {
    try {
      $ownsMutex = $installMutex.WaitOne([TimeSpan]::FromMinutes(2))
    } catch [Threading.AbandonedMutexException] {
      $ownsMutex = $true
      Write-InstallerLog "repair" "Recovered an interrupted dependency setup lock"
    }
    if (-not $ownsMutex) {
      Throw-DependencyError "KSP-DEP-010" "Another dependency repair is still running." "Setup waited two minutes for the shared dependency lock." @("Close the other game launcher and launch again.")
    }

    $nodePath = Find-InstalledNodeRuntime
    $tunnelPath = if ($ForceTunnelRepair) { $null } else { Find-InstalledCloudflaredRuntime }
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
    Write-JsonAtomic $statusPath $status
    Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    if ($Diagnose) {
      Write-Host ($status | ConvertTo-Json -Depth 6)
    }
    Write-InstallerLog "ready" "Dependency diagnosis and repair completed"
  } finally {
    if ($ownsMutex) { $installMutex.ReleaseMutex() }
    if ($installMutex) { $installMutex.Dispose() }
  }
  exit 0
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
  exit 1
}
