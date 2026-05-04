#Requires -Version 5.1
<#
  构建 Windows NWVPN（WPF）并编译 go nw-client.exe 到 archives\windows-nwvpn\publish。
  在仓库根目录执行: .\scripts\package_windows_nwvpn.ps1
#>
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Win = Join-Path $Root "apps\windows\NWVPN"
$Out = Join-Path $Root "archives\windows-nwvpn"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Publish = Join-Path $Out "publish"

Push-Location $Win
try {
  dotnet publish -c Release -r win-x64 --self-contained false -o $Publish
}
finally {
  Pop-Location
}

$Go = Join-Path $Root "go"
Push-Location $Go
try {
  $nw = Join-Path $Publish "nw-client.exe"
  go build -trimpath -ldflags="-s -w" -o $nw .\cmd\nw-client
  Write-Host "Built nw-client -> $nw"
}
finally {
  Pop-Location
}

Write-Host "Done. Output: $Publish"
