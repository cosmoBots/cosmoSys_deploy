param(
 [Parameter(Mandatory=$true)][string]$SshAlias,
 [Parameter(Mandatory=$true)][string]$RemoteBackupDirectory,
 [Parameter(Mandatory=$true)][string]$Destination
)
# Download an existing backup created by upstream scripts/backup.sh.
# Authentication and known-host checking use the user's normal SSH configuration.
$ErrorActionPreference='Stop'
if ($SshAlias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'Invalid SSH alias' }
if ($RemoteBackupDirectory -notmatch '^/[a-zA-Z0-9_./-]+$' -or $RemoteBackupDirectory.Contains('..')) { throw 'Invalid remote directory' }
$target=[IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $target) { throw 'Choose a new destination directory' }
New-Item -ItemType Directory -Path $target | Out-Null
& scp -o BatchMode=yes -o StrictHostKeyChecking=yes -r "${SshAlias}:$RemoteBackupDirectory" $target
if ($LASTEXITCODE -ne 0) { throw 'Backup download failed' }
$folder=Join-Path $target ($RemoteBackupDirectory.TrimEnd('/').Split('/')[-1])
foreach ($line in Get-Content -LiteralPath (Join-Path $folder 'SHA256SUMS')) {
 $parts=$line -split '\s+',2
 $name=$parts[1].TrimStart('*')
 if ($name -notin @('database.dump','files.tar.gz','manifest.env')) { throw 'Unexpected checksum entry' }
 if ((Get-FileHash -LiteralPath (Join-Path $folder $name) -Algorithm SHA256).Hash -ne $parts[0]) { throw "Checksum mismatch: $name" }
}
Write-Output "Downloaded and checksum-verified: $folder. Test restoration separately."
