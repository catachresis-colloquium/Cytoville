# SPDX-License-Identifier: AGPL-3.0-or-later
$ErrorActionPreference = 'Stop'
if (!$env:RUNNER_TEMP -or !$env:GITHUB_ENV) {
    throw 'This installer requires the GitHub Actions runner environment.'
}
$toolsDirectory = Join-Path $env:RUNNER_TEMP 'cytoville-native-tools'
New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null
$archive = Join-Path $toolsDirectory 'zig-0.16.0.zip'
$expected = '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e'
$filename = 'zig-x86_64-windows-0.16.0.zip'
# Mirrors listed by https://ziglang.org/download/community-mirrors.txt.
# Their bytes are untrusted until they match the existing pinned release hash.
$mirrors = @('https://pkg.hexops.org/zig', 'https://ziglang.freetls.fastly.net', 'https://zig.linus.dev/zig') | Sort-Object { Get-Random }
$sources = @($mirrors | ForEach-Object { "$_/$filename" }) + @("https://ziglang.org/download/0.16.0/$filename")
$downloaded = $false
foreach ($source in $sources) {
    Write-Host "Downloading pinned Zig from $source"
    & curl.exe --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --connect-timeout 15 --max-time 180 --output $archive $source
    if ($LASTEXITCODE -ne 0) { continue }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        throw 'Zig archive checksum mismatch; refusing extraction.'
    }
    $downloaded = $true
    break
}
if (!$downloaded) { throw 'All bounded Zig download attempts failed.' }
Write-Host 'Verified Zig archive; extracting.'
Expand-Archive -LiteralPath $archive -DestinationPath $toolsDirectory
$zigExe = Join-Path $toolsDirectory 'zig-x86_64-windows-0.16.0/zig.exe'
"ZIG=$zigExe" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
rustup toolchain install 1.99.1 --profile minimal
if ($LASTEXITCODE -ne 0) { throw 'Rust installation failed.' }
rustup default 1.99.1
if ($LASTEXITCODE -ne 0) { throw 'Rust selection failed.' }
