# Build engine if needed
if (!(Test-Path "../bin/evolution-engine.exe")) {
    Write-Host "Rebuilding engine..." -ForegroundColor Cyan
    Push-Location ..
    dub build -b release
    Pop-Location
}

# Download rules
Write-Host "Downloading latest rules..." -ForegroundColor Cyan
$rulesUrl = "https://github.com/AMDphreak/evolution-rules-code/archive/refs/tags/latest.zip"
$zipPath = "latest.zip"
$extractPath = "rules_code"

if (Test-Path $extractPath) { Remove-Item -Recurse -Force $extractPath }
Invoke-WebRequest -Uri $rulesUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
Remove-Item $zipPath

$rulesDir = (Get-ChildItem -Directory $extractPath).FullName + "/rules/qt"

# Run test
$engine = "../bin/evolution-engine.exe"
Write-Host "Running evolution-engine test..." -ForegroundColor Green
& $engine --path . --rules-dir $rulesDir --from 5.15 --to 6.0
