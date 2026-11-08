#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$version = 'v0.7.2'
$stage = Join-Path $dist ('build-' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $stage ('ClipLite-' + $version)
New-Item -ItemType Directory -Path $package -Force | Out-Null
try {
    foreach ($name in @('ClipLite.ps1', 'Start-ClipLite.cmd', 'Start-ClipLite-Diagnostic.cmd', 'execute.bat', 'config.example.json', 'templates.example.json')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $package
    }
    Copy-Item -LiteralPath (Join-Path $root 'docs\USAGE.txt') -Destination (Join-Path $package 'README.txt')
    $zipPath = Join-Path $dist ('ClipLite-' + $version + '.zip')
    Compress-Archive -LiteralPath $package -DestinationPath $zipPath -Force
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    ($hash + '  ' + [IO.Path]::GetFileName($zipPath)) | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII
    Write-Output $zipPath
} finally {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $expectedParent = [IO.Path]::GetFullPath($dist)
    if ([IO.Path]::GetDirectoryName($resolvedStage) -ne $expectedParent -or [IO.Path]::GetFileName($resolvedStage) -notlike 'build-*') { throw 'Unexpected build directory' }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
