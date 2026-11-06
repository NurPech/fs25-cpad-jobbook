# Packs FS25_CpAdJobBook/ into a zip (modDesc.xml at the zip root) and copies it
# into the game's mods folder. Close the game first, it locks the zip while running.
# Mods folder: -ModsDir, else the environment variable FS25_MODS_DIR, else the default
# <Documents>\My Games\FarmingSimulator2025\mods.
param(
    [string]$ModsDir = $(if ($env:FS25_MODS_DIR) { $env:FS25_MODS_DIR } else {
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FarmingSimulator2025\mods' })
)

$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'FS25_CpAdJobBook'
$zip = Join-Path $ModsDir 'FS25_CpAdJobBook.zip'

if (-not (Test-Path $src)) { throw "Mod folder not found: $src" }
if (-not (Test-Path $ModsDir)) { throw "Mods folder not found: $ModsDir" }

if (Test-Path $zip) { Remove-Item $zip -Force }

# ZipFile (instead of Compress-Archive) guarantees forward slashes in entry names
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($src, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)

Write-Host "Built $zip"
