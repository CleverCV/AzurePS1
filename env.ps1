$env:LOVE = Join-Path $PSScriptRoot "l2"

if (!(Test-Path "$env:LOVE\love.exe")) {
    Write-Host "[ERROR] LÖVE2D not found!" -ForegroundColor Red
    Write-Host "Expected: $env:LOVE\love.exe"
    return
}

function Run-AzurePS1 {
    & "$env:LOVE\love.exe" $PSScriptRoot
}

function Build-AzurePS1 {
    & "$env:LOVE\love.exe" --version
}

Write-Host ""
Write-Host " AzurePS1 Development Environment" -ForegroundColor Cyan
Write-Host " LOVE: $env:LOVE" -ForegroundColor Green
Write-Host " Environment loaded successfully!" -ForegroundColor Green
Write-Host ""