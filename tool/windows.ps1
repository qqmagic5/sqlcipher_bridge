$ErrorActionPreference = "Stop"

$OptimizationFlag = "/O2"
$TargetArch = "x64"

$Defines = "-DSQLITE_THREADSAFE=1 " +
           "-DSQLITE_ENABLE_FTS5 " +
           "-DSQLITE_ENABLE_RTREE " +
           "-DSQLITE_ENABLE_COLUMN_METADATA " +
           "-DSQLITE_ENABLE_MATH_FUNCTIONS " +
           "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT " +
           "-DSQLITE_DEFAULT_FOREIGN_KEYS=1 " +
           "-DSQLITE_HAS_CODEC=1 " +
           "-DSQLITE_TEMP_STORE=2 " +
           "-DSQLITE_EXTRA_INIT=sqlcipher_extra_init " +
           "-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"

$InitialLocation = Get-Location

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

$OutputLibraryName = "sqlcipher_bridge"
$VendorLibraryName = "sqlite3"
$LibraryExtension = "dll"

$SrcDir = Join-Path $ProjectRoot "external"
$PrebuiltDir = Join-Path $ProjectRoot "prebuilt"

$TargetOs = "windows"

function Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Clean {
    Step "Cleaning external directory via git..."
    & git -C "$SrcDir" checkout -q HEAD -- . 2>$null
    & git -C "$SrcDir" clean -fdq . 2>$null
}

function Get-DartPackagePath(
    [string]$PackageName,
    [string]$ProjectRoot
) {
    $PackageConfig = Join-Path $ProjectRoot ".dart_tool\package_config.json"

    if (-not (Test-Path $PackageConfig)) {
        throw "$PackageConfig not found. Run 'dart pub get' first."
    }

    $Config = Get-Content $PackageConfig -Raw | ConvertFrom-Json

    $Package = $Config.packages |
        Where-Object { $_.name -eq $PackageName } |
        Select-Object -First 1

    if ($null -eq $Package) {
        throw "Package '$PackageName' not found in $PackageConfig"
    }

    $PackageUri = $Package.rootUri

    if ($PackageUri -like "file://*") {
        return ([System.Uri]$PackageUri).LocalPath
    }

    return Join-Path $ProjectRoot ".dart_tool\$PackageUri"
}

Step "Build options"
Write-Host "ProjectRoot: $ProjectRoot"
Write-Host ""
Write-Host "SrcDir: $SrcDir"
Write-Host "PrebuiltDir: $PrebuiltDir"
Write-Host ""
Write-Host "OutputLibraryName: $OutputLibraryName"
Write-Host "VendorLibraryName: $VendorLibraryName"
Write-Host "LibraryExtension: $LibraryExtension"
Write-Host ""
Write-Host "TargetOs: $TargetOs"
Write-Host "TargetArch: $TargetArch"
Write-Host ""
Write-Host "OptimizationFlag: $OptimizationFlag"
Write-Host "Defines: $Defines"

try {
    Step "Changing directory to $SrcDir..."
    Set-Location $SrcDir

    $OpenSslLibraryName = "openssl_bridge"
    $OpenSslLibraryFile = "$OpenSslLibraryName.dll"
    $OpenSslImportLibrary = "$OpenSslLibraryName.lib"
    $OpenSslRootDir = Get-DartPackagePath $OpenSslLibraryName $ProjectRoot
    $OpenSslPrebuiltDir = Join-Path $OpenSslRootDir "prebuilt\$TargetOs\$TargetArch"
    $OpenSslIncludeDir = Join-Path $OpenSslPrebuiltDir "include"
    
    if (-not (Test-Path (Join-Path $OpenSslPrebuiltDir $OpenSslLibraryFile))) {
        Write-Error "$OpenSslLibraryFile not found at $OpenSslPrebuiltDir"
        exit 1
    }
    if (-not (Test-Path (Join-Path $OpenSslPrebuiltDir $OpenSslImportLibrary))) {
        Write-Error "$OpenSslImportLibrary not found at $OpenSslPrebuiltDir"
        exit 1
    }

    $MakefileMsc = Join-Path $SrcDir "Makefile.msc"
    if (-not (Test-Path $MakefileMsc)) {
        Write-Error "Makefile.msc not found in $SrcDir"
        exit 1
    }

    Step "Building $OutputLibraryName with nmake..."
    nmake.exe /f Makefile.msc clean
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed: 'nmake clean' exited with code $LASTEXITCODE."
        exit 1
    }

    nmake.exe /f Makefile.msc sqlite3.dll `
        OPT_FEATURE_FLAGS="$Defines" `
        CCOPTS="$OptimizationFlag /I`"$OpenSslIncludeDir`"" `
        LTLIBS="/LIBPATH:$OpenSslPrebuiltDir $OpenSslImportLibrary"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed: nmake exited with code $LASTEXITCODE."
        exit 1
    }

    $CompiledDll = Join-Path $SrcDir "$VendorLibraryName.$LibraryExtension"
    if (-not (Test-Path $CompiledDll)) {
        Write-Error "Build failed: $VendorLibraryName.$LibraryExtension not found in $SrcDir."
        exit 1
    }
    $CompiledLib = Join-Path $SrcDir "sqlite3.lib"
    if (-not (Test-Path $CompiledLib)) {
        Write-Error "Build failed: $CompiledLib not found."
        exit 1
    }

    $OutDir = Join-Path $PrebuiltDir "$TargetOs\$TargetArch"
    $OutDll = Join-Path $OutDir "$OutputLibraryName.$LibraryExtension"
    $OutLib = Join-Path $OutDir "$OutputLibraryName.lib"

    Step "Creating output directory..."
    if (Test-Path $OutDir) {
        Remove-Item -Recurse -Force $OutDir
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    Step "Copying files to output directory..."
    Copy-Item -Force $CompiledDll $OutDll
    Copy-Item -Force $CompiledLib $OutLib
    $IncludeDir = Join-Path $OutDir "include"
    New-Item -ItemType Directory -Force -Path $IncludeDir | Out-Null
    Copy-Item -Force `
        (Join-Path $SrcDir "sqlite3.h") `
        (Join-Path $IncludeDir "sqlite3.h")
    Step "Verifying output files..."
    if (-not (Test-Path -Path $OutDll -PathType Leaf)) {
        Write-Error "Output DLL was not created: $OutDll"
        exit 1
    }
    if (-not (Test-Path -Path $OutLib -PathType Leaf)) {
        Write-Error "Output LIB was not created: $OutLib"
        exit 1
    }
    $OutSqliteHeader = Join-Path $IncludeDir "sqlite3.h"
    if (-not (Test-Path -Path $OutSqliteHeader -PathType Leaf)) {
        Write-Error "SQLite header was not copied: $OutSqliteHeader"
        exit 1
    }
    
    Step "$OutputLibraryName build completed."
    Write-Host "Output: $OutDir"
} finally {
    Set-Location $InitialLocation
    Clean
}
