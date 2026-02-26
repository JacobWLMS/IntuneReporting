#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the local development environment for IntuneReporting Azure Functions.

.DESCRIPTION
    Checks prerequisites, creates a Python virtual environment, installs dependencies,
    and creates the local settings file from the example template.

.EXAMPLE
    .\setup-local.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FunctionsDir = Join-Path $PSScriptRoot 'functions'

function Write-Step([string]$Message) {
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-OK([string]$Message) {
    Write-Host "   [OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "   [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "   [FAIL] $Message" -ForegroundColor Red
}

# ── 1. Python 3.11 ────────────────────────────────────────────────────────────
Write-Step "Checking Python 3.11"

$python = $null
foreach ($candidate in @('python3.11', 'python3', 'python')) {
    try {
        $ver = & $candidate --version 2>&1
        if ($ver -match '3\.11') {
            $python = $candidate
            break
        }
    } catch { }
}

if (-not $python) {
    Write-Fail "Python 3.11 not found on PATH."
    Write-Host "   Install from https://www.python.org/downloads/ or via winget:" -ForegroundColor Gray
    Write-Host "   winget install Python.Python.3.11" -ForegroundColor Gray
    exit 1
}

$pythonVersion = & $python --version 2>&1
Write-OK "$python -> $pythonVersion"

# ── 2. Azure Functions Core Tools ─────────────────────────────────────────────
Write-Step "Checking Azure Functions Core Tools (func)"

try {
    $funcVer = & func --version 2>&1
    Write-OK "func $funcVer"
} catch {
    Write-Fail "'func' not found on PATH."
    Write-Host "   Install via winget:" -ForegroundColor Gray
    Write-Host "   winget install Microsoft.Azure.FunctionsCoreTools" -ForegroundColor Gray
    exit 1
}

# ── 3. Azurite ────────────────────────────────────────────────────────────────
Write-Step "Checking Azurite (local Azure Storage emulator)"

$azuriteOk = $false
try {
    $null = & azurite --version 2>&1
    $azuriteOk = $true
    Write-OK "azurite found"
} catch { }

if (-not $azuriteOk) {
    # Check if npm is available to offer install
    try {
        $null = & npm --version 2>&1
        Write-Warn "Azurite not found. Installing globally via npm..."
        & npm install -g azurite
        Write-OK "Azurite installed"
    } catch {
        Write-Warn "Azurite not found and npm is not available."
        Write-Host "   Install Node.js (https://nodejs.org) then run: npm install -g azurite" -ForegroundColor Gray
        Write-Host "   Alternatively install the 'Azurite' VS Code extension." -ForegroundColor Gray
        Write-Host "   Continuing setup — you must start Azurite before running 'func start'." -ForegroundColor Gray
    }
}

# ── 4. Virtual environment ────────────────────────────────────────────────────
Write-Step "Setting up Python virtual environment"

$venvDir = Join-Path $FunctionsDir '.venv'

if (Test-Path $venvDir) {
    Write-OK "Virtual environment already exists at functions/.venv"
} else {
    Write-Host "   Creating virtual environment at functions/.venv ..." -ForegroundColor Gray
    & $python -m venv $venvDir
    Write-OK "Virtual environment created"
}

# ── 5. Install dependencies ───────────────────────────────────────────────────
Write-Step "Installing Python dependencies"

$pip = Join-Path $venvDir 'Scripts\pip.exe'
$requirementsFile = Join-Path $FunctionsDir 'requirements.txt'

Write-Host "   Running pip install -r functions/requirements.txt ..." -ForegroundColor Gray
Write-Host "   (msgraph-beta-sdk is large — this can take a minute or two)" -ForegroundColor Gray
& $pip install -r $requirementsFile
Write-OK "Dependencies installed"

# ── 6. Local settings file ────────────────────────────────────────────────────
Write-Step "Checking local settings file"

$settingsFile  = Join-Path $FunctionsDir 'local.settings.json'
$exampleFile   = Join-Path $FunctionsDir 'local.settings.json.example'

if (Test-Path $settingsFile) {
    Write-OK "functions/local.settings.json already exists — skipping"
} else {
    Copy-Item $exampleFile $settingsFile
    Write-OK "Created functions/local.settings.json from example"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host @"

Setup complete. Next steps:

  1. Fill in your credentials in functions/local.settings.json:
       AZURE_TENANT_ID      - your Entra tenant ID
       AZURE_CLIENT_ID      - app registration client ID
       AZURE_CLIENT_SECRET  - app registration client secret
       LOG_ANALYTICS_DCE    - Data Collection Endpoint URL
       LOG_ANALYTICS_DCR_ID - DCR immutable ID (starts with dcr-)

  2. Start Azurite in a separate terminal:
       azurite --location .azurite

  3. Start the Functions host:
       cd functions
       .\.venv\Scripts\Activate.ps1
       func start

  4. Verify the setup:
       curl http://localhost:7071/api/export/health

  For VS Code debugging: install the Azure Functions extension, then press F5.
"@ -ForegroundColor White
