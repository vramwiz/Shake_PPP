$ErrorActionPreference = 'Stop'

$packageName = 'Shake_PPP'
$pluginDir = 'C:\ProgramData\aviutl2\Plugin\Shake_PPP'
$pluginFile = Join-Path $pluginDir 'Shake_PPP.auf2'
$debugDll = Join-Path $pluginDir 'Shake_PPP.dll'
$debugSymbols = Join-Path $pluginDir 'Shake_PPP.rsm'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$readmeFile = Join-Path $projectRoot 'README.md'
$workDir = Join-Path $PSScriptRoot $packageName
$zipFile = Join-Path $PSScriptRoot "$packageName.zip"

if (-not (Test-Path -LiteralPath $pluginFile -PathType Leaf)) {
  Write-Host 'Filter plugin not found:'
  Write-Host "  $pluginFile"
  Write-Host 'Build the Release configuration first, then run this batch again.'
  exit 1
}

if ((Test-Path -LiteralPath $debugDll -PathType Leaf) -or
    (Test-Path -LiteralPath $debugSymbols -PathType Leaf)) {
  Write-Host 'Debug build files remain in the plugin directory.'
  Write-Host 'Build the Release configuration first, then run this batch again.'
  Write-Host "  $pluginDir"
  exit 1
}

if (-not (Test-Path -LiteralPath $readmeFile -PathType Leaf)) {
  Write-Host 'README not found:'
  Write-Host "  $readmeFile"
  exit 1
}

$setupRoot = [System.IO.Path]::GetFullPath($PSScriptRoot +
  [System.IO.Path]::DirectorySeparatorChar)
$resolvedWorkDir = [System.IO.Path]::GetFullPath($workDir)
$resolvedZipFile = [System.IO.Path]::GetFullPath($zipFile)
if (-not $resolvedWorkDir.StartsWith($setupRoot,
    [System.StringComparison]::OrdinalIgnoreCase) -or
    -not $resolvedZipFile.StartsWith($setupRoot,
    [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'Package output escaped the Setup directory.'
}

if (Test-Path -LiteralPath $resolvedWorkDir) {
  Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force
}

if (Test-Path -LiteralPath $resolvedZipFile) {
  Remove-Item -LiteralPath $resolvedZipFile -Force
}

try {
  New-Item -ItemType Directory -Path $resolvedWorkDir -Force | Out-Null
  Copy-Item -LiteralPath $pluginFile -Destination $resolvedWorkDir -Force
  Copy-Item -LiteralPath $readmeFile -Destination $resolvedWorkDir -Force
  Compress-Archive -Path $resolvedWorkDir -DestinationPath $resolvedZipFile -Force
}
finally {
  if (Test-Path -LiteralPath $resolvedWorkDir) {
    Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force
  }
}

Write-Host 'Created:'
Write-Host "  $resolvedZipFile"
