[CmdletBinding()]
param(
    [switch]$SkipInstall,
    [switch]$KeepConsole
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$windowsRoot = Join-Path $repoRoot "windows"
$buildRoot = Join-Path $windowsRoot "build"
$distRoot = Join-Path $repoRoot "dist"
$packageJSON = Join-Path $windowsRoot "package.json"
$packageLock = Join-Path $windowsRoot "package-lock.json"
$nodeModules = Join-Path $windowsRoot "node_modules"
$bundlePath = Join-Path $buildRoot "main.cjs"
$blobPath = Join-Path $buildRoot "sea-prep.blob"
$seaConfig = Join-Path $windowsRoot "sea-config.json"
$outputEXE = Join-Path $distRoot "CliptoPulse.exe"

if ($env:OS -ne "Windows_NT") {
    throw "CliptoPulse.exe must be built on Windows."
}
if (-not (Test-Path -LiteralPath $packageJSON)) {
    throw "Missing Windows package manifest: $packageJSON"
}

$nodeCommand = Get-Command node -ErrorAction Stop
$nodeVersionText = (& $nodeCommand.Source --version).TrimStart("v")
$nodeMajor = [int]($nodeVersionText.Split(".")[0])
if ($nodeMajor -lt 24) {
    throw "Node.js 24 or newer is required; found $nodeVersionText."
}

$esbuildCommand = Join-Path $windowsRoot "node_modules\.bin\esbuild.cmd"
$postjectCommand = Join-Path $windowsRoot "node_modules\.bin\postject.cmd"
$dependenciesPresent = (Test-Path -LiteralPath $esbuildCommand) -and (Test-Path -LiteralPath $postjectCommand)

if (-not $SkipInstall -and -not $dependenciesPresent) {
    Push-Location $windowsRoot
    try {
        if (Test-Path -LiteralPath $packageLock) {
            & npm ci
        } else {
            & npm install
        }
        if ($LASTEXITCODE -ne 0) { throw "npm dependency installation failed." }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $esbuildCommand) -or -not (Test-Path -LiteralPath $postjectCommand)) {
    throw "Windows build dependencies are missing. Run without -SkipInstall first."
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null

Push-Location $windowsRoot
try {
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw "TypeScript validation or bundling failed." }
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath $bundlePath)) {
    throw "Bundled entry point was not produced: $bundlePath"
}

Push-Location $repoRoot
try {
    if (Test-Path -LiteralPath $blobPath) { Remove-Item -LiteralPath $blobPath -Force }
    & $nodeCommand.Source --experimental-sea-config $seaConfig
    if ($LASTEXITCODE -ne 0) { throw "Node SEA preparation failed." }
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath $blobPath)) {
    throw "SEA preparation blob was not produced: $blobPath"
}

if (Test-Path -LiteralPath $outputEXE) { Remove-Item -LiteralPath $outputEXE -Force }
Copy-Item -LiteralPath $nodeCommand.Source -Destination $outputEXE

function Find-WindowsSDKTool([string]$Name) {
    $kitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    if (-not (Test-Path -LiteralPath $kitsRoot)) { return $null }
    return Get-ChildItem -LiteralPath $kitsRoot -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\$([regex]::Escape($Name))$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$signTool = Find-WindowsSDKTool "signtool.exe"
if ($signTool) {
    & $signTool remove /s $outputEXE | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the Node executable signature before SEA injection." }
} else {
    Write-Warning "signtool.exe was not found; postject may reject the signed Node executable."
}

& $postjectCommand $outputEXE "NODE_SEA_BLOB" $blobPath `
    --sentinel-fuse "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"
if ($LASTEXITCODE -ne 0) { throw "postject failed to inject the SEA blob." }

if (-not $KeepConsole) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $editbin = $null
    if (Test-Path -LiteralPath $vswhere) {
        $vsRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
        if ($vsRoot) {
            $editbin = Get-ChildItem -LiteralPath (Join-Path $vsRoot "VC\Tools\MSVC") -Recurse -Filter "editbin.exe" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\Hostx64\\x64\\editbin\.exe$" } |
                Sort-Object FullName -Descending |
                Select-Object -First 1 -ExpandProperty FullName
        }
    }
    if ($editbin) {
        & $editbin /NOLOGO /SUBSYSTEM:WINDOWS $outputEXE
        if ($LASTEXITCODE -ne 0) { throw "editbin could not switch the EXE to the Windows subsystem." }
    } else {
        Write-Warning "editbin.exe was not found; the portable EXE will show a console window."
    }
}

$result = Get-Item -LiteralPath $outputEXE
Write-Host "Built $($result.FullName) ($([math]::Round($result.Length / 1MB, 1)) MiB)"
