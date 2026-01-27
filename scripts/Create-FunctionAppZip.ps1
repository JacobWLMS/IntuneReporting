<#
.SYNOPSIS
    Creates a deployment zip file for the Azure Function App.

.DESCRIPTION
    This script packages the Azure Function App code into a zip file ready for deployment.
    It excludes development files, virtual environments, and non-essential directories
    based on the .funcignore file patterns.

.PARAMETER OutputPath
    The path where the zip file will be created. Defaults to 'function-app.zip' in the current directory.

.PARAMETER Force
    Overwrite the output file if it already exists.

.EXAMPLE
    .\Create-FunctionAppZip.ps1
    Creates function-app.zip in the scripts directory.

.EXAMPLE
    .\Create-FunctionAppZip.ps1 -OutputPath "C:\Releases\function-app-v1.0.zip" -Force
    Creates the zip at the specified path, overwriting if it exists.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\function-app.zip"),

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Get the root directory (parent of scripts folder)
$RootDir = Split-Path $PSScriptRoot -Parent
$TempDir = Join-Path $env:TEMP "FunctionAppPackage_$(Get-Random)"

Write-Host "📦 Creating Function App deployment package..." -ForegroundColor Cyan
Write-Host "   Source: $RootDir" -ForegroundColor Gray

# Resolve output path
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

# Check if output file exists
if ((Test-Path $OutputPath) -and -not $Force) {
    Write-Error "Output file '$OutputPath' already exists. Use -Force to overwrite."
    exit 1
}

# Define what to include (Function App essentials)
$IncludeItems = @(
    "fn_*",           # All function directories
    "shared",         # Shared code
    "host.json",      # Function App host configuration
    "requirements.txt" # Python dependencies
)

# Define what to exclude (matches .funcignore patterns)
$ExcludePatterns = @(
    ".venv",
    ".git",
    ".github",
    "__pycache__",
    "*.pyc",
    "local.settings.json",
    ".vscode",
    "database",
    "dashboards",
    "deployment",
    "scripts",
    "workbooks",
    "*.md",
    ".env",
    ".env.example",
    ".funcignore",
    ".gitignore"
)

try {
    # Create temp directory
    Write-Host "   Creating temporary directory..." -ForegroundColor Gray
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    # Copy function directories
    Write-Host "   Copying function code..." -ForegroundColor Gray
    
    $FunctionDirs = Get-ChildItem -Path $RootDir -Directory -Filter "fn_*"
    foreach ($dir in $FunctionDirs) {
        $destPath = Join-Path $TempDir $dir.Name
        
        # Copy directory excluding __pycache__
        Copy-Item -Path $dir.FullName -Destination $destPath -Recurse -Force
        
        # Remove __pycache__ directories
        Get-ChildItem -Path $destPath -Directory -Filter "__pycache__" -Recurse | 
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        
        Write-Host "     ✓ $($dir.Name)" -ForegroundColor Green
    }

    # Copy shared directory
    $SharedDir = Join-Path $RootDir "shared"
    if (Test-Path $SharedDir) {
        $destShared = Join-Path $TempDir "shared"
        Copy-Item -Path $SharedDir -Destination $destShared -Recurse -Force
        
        # Remove __pycache__
        Get-ChildItem -Path $destShared -Directory -Filter "__pycache__" -Recurse | 
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        
        Write-Host "     ✓ shared" -ForegroundColor Green
    }

    # Copy essential files
    Write-Host "   Copying configuration files..." -ForegroundColor Gray
    
    $EssentialFiles = @("host.json", "requirements.txt")
    foreach ($file in $EssentialFiles) {
        $srcFile = Join-Path $RootDir $file
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination $TempDir -Force
            Write-Host "     ✓ $file" -ForegroundColor Green
        } else {
            Write-Warning "File not found: $file"
        }
    }

    # Create the zip file
    Write-Host "   Creating zip archive..." -ForegroundColor Gray
    
    # Remove existing zip if Force is specified
    if (Test-Path $OutputPath) {
        Remove-Item $OutputPath -Force
    }

    # Create zip
    Compress-Archive -Path "$TempDir\*" -DestinationPath $OutputPath -CompressionLevel Optimal

    # Get file info
    $ZipInfo = Get-Item $OutputPath
    $SizeMB = [math]::Round($ZipInfo.Length / 1MB, 2)

    Write-Host ""
    Write-Host "✅ Package created successfully!" -ForegroundColor Green
    Write-Host "   Output: $OutputPath" -ForegroundColor Cyan
    Write-Host "   Size: $SizeMB MB" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "📤 To deploy manually:" -ForegroundColor Yellow
    Write-Host "   az functionapp deployment source config-zip \" -ForegroundColor Gray
    Write-Host "     --resource-group <resource-group> \" -ForegroundColor Gray
    Write-Host "     --name <function-app-name> \" -ForegroundColor Gray
    Write-Host "     --src `"$OutputPath`"" -ForegroundColor Gray

} catch {
    Write-Error "Failed to create deployment package: $_"
    exit 1
} finally {
    # Cleanup temp directory
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
