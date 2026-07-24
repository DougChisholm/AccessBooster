<#
.SYNOPSIS
    Extracts all database objects from a Microsoft Access database (.accdb or .mdb)
    and packages them into a zip file for upload to AccessBooster.

.DESCRIPTION
    Run this script on any machine where Microsoft Access is installed.
    It extracts: table schema, queries, forms, reports, and VBA modules.
    No table data is included in the output.

    Requirements:
      - Microsoft Access (for forms, reports, VBA)
        The ACE Database Engine alone covers schema and queries.

.PARAMETER InputPath
    Full path to the source .accdb or .mdb file.

.EXAMPLE
    .\extract_schema.ps1 -InputPath "C:\MyData\Staff.accdb"
    # Creates C:\MyData\Staff_accessbooster.zip -- upload this to AccessBooster
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$InputPath
)

$ErrorActionPreference = "Continue"

# -- File picker fallback (used when the script is run without -InputPath) ------
if (-not $InputPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.OpenFileDialog
    $picker.Title  = "Select your Access database"
    $picker.Filter = "Access databases (*.accdb;*.mdb)|*.accdb;*.mdb|All files (*.*)|*.*"
    if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $InputPath = $picker.FileName
    } else {
        Write-Host "No file selected. Exiting."
        exit 0
    }
}

# -- 32-bit PowerShell relaunch -------------------------------------------------
# Microsoft 365 / retail Access is almost always 32-bit. A 64-bit PowerShell
# host cannot load a 32-bit COM server (Access.Application), so detect 32-bit
# Access in the registry and re-launch under SysWOW64\PowerShell if required.
if ([IntPtr]::Size -eq 8) {
    $wow64ps  = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    $access32 = "HKLM:\SOFTWARE\WOW6432Node\Classes\Access.Application"
    if ((Test-Path $wow64ps) -and (Test-Path $access32)) {
        Write-Host "Detected 32-bit Access -- relaunching in 32-bit PowerShell..."
        & $wow64ps -ExecutionPolicy Bypass -File $PSCommandPath -InputPath $InputPath
        exit $LASTEXITCODE
    }
}

# -- Resolve path ---------------------------------------------------------------
$InputPath = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop | Select-Object -ExpandProperty Path
$leaf = Split-Path $InputPath -Leaf
$dir  = Split-Path $InputPath -Parent
# Use string ops instead of [System.IO.Path] (works in Constrained Language Mode)
$ext  = if ($leaf.Contains('.')) { '.' + $leaf.Split('.')[-1].ToLower() } else { '' }
$name = if ($ext) { $leaf.Substring(0, $leaf.Length - $ext.Length) } else { $leaf }

if ($ext -notin @('.accdb', '.mdb')) {
    Write-Error "File must be .accdb or .mdb. Got: $ext"
    exit 1
}

$objectsDir = Join-Path $dir ($name + "_objects_tmp")
$zipPath    = Join-Path $dir ($name + "_accessbooster.zip")

if (Test-Path $objectsDir) { Remove-Item $objectsDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $objectsDir | Out-Null

Write-Host ""
Write-Host "AccessBooster -- Database Extraction Script"
Write-Host "==========================================="
Write-Host "Input  : $InputPath"
Write-Host "Output : $zipPath"
Write-Host "  Tip  : If Windows blocked this script, run it as:"
Write-Host "         powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
Write-Host ""

# -- Step 1/3: Open Access and extract all objects ------------------------------
Write-Host "Step 1/3: Opening database with Access..."

$accessOk = $false
try {
    $acc = New-Object -ComObject Access.Application
    $acc.Visible = $false
    $acc.OpenCurrentDatabase($InputPath)
    $accessOk = $true
    $accDb = $acc.CurrentDb()

    # Schema
    $sqlLines = @()
    $tCount = 0
    foreach ($tbl in $accDb.TableDefs) {
        if ($tbl.Name.StartsWith("MSys") -or $tbl.Name.StartsWith("~")) { continue }
        $cols = @()
        foreach ($fld in $tbl.Fields) {
            $typeName = switch ($fld.Type) {
                1  { "BIT" }
                2  { "SMALLINT" }
                3  { "SMALLINT" }
                4  { "INTEGER" }
                5  { "DECIMAL(19,4)" }
                6  { "REAL" }
                7  { "FLOAT" }
                8  { "DATETIME" }
                10 { "NVARCHAR($($fld.Size))" }
                11 { "NTEXT" }
                12 { "VARBINARY(MAX)" }
                15 { "UNIQUEIDENTIFIER" }
                default { "NVARCHAR(255)" }
            }
            $cols += "  [$($fld.Name)] $typeName"
        }
        $sqlLines += "CREATE TABLE [$($tbl.Name)] ("
        $sqlLines += ($cols -join ",`n")
        $sqlLines += ");"
        $sqlLines += ""
        $tCount++
    }
    $sqlLines | Set-Content (Join-Path $objectsDir "schema.sql") -Encoding UTF8
    Write-Host "  Schema: $tCount table(s) exported"

    # Queries
    $qCount = 0
    foreach ($qdf in $accDb.QueryDefs) {
        if ($qdf.Name.StartsWith("~")) { continue }
        $safe = $qdf.Name -replace '[\\/:*?"<>|]', '_'
        "-- Query: $($qdf.Name)`n$($qdf.SQL)" |
            Set-Content (Join-Path $objectsDir "query_${safe}.sql") -Encoding UTF8
        $qCount++
    }
    Write-Host "  Queries: $qCount exported"

    Write-Host ""
    Write-Host "Step 2/3: Extracting forms, reports, VBA..."

    # Forms
    $fCount = 0
    foreach ($frm in $acc.CurrentProject.AllForms) {
        try {
            $safe = $frm.Name -replace '[\/:*?"<>|]', '_'
            $acc.SaveAsText(2, $frm.Name, (Join-Path $objectsDir "form_${safe}.txt"))  # 2 = acForm
            $fCount++
        } catch {
            # Retry: open the form in design view first, then export
            try {
                $acc.DoCmd.OpenForm($frm.Name, 1)  # 1 = acDesign
                $acc.SaveAsText(2, $frm.Name, (Join-Path $objectsDir "form_${safe}.txt"))  # 2 = acForm
                $acc.DoCmd.Close(2, $frm.Name)     # 2 = acForm
                $fCount++
            } catch {
                Write-Warning "  Form '$($frm.Name)' skipped: $_"
            }
        }
    }
    Write-Host "  Forms: $fCount exported"

    # Reports
    $rCount = 0
    foreach ($rpt in $acc.CurrentProject.AllReports) {
        try {
            $safe = $rpt.Name -replace '[\/:*?"<>|]', '_'
            $acc.SaveAsText(3, $rpt.Name, (Join-Path $objectsDir "report_${safe}.txt"))
            $rCount++
        } catch {
            # Retry: open the report in design view first, then export
            try {
                $acc.DoCmd.OpenReport($rpt.Name, 1)  # 1 = acViewDesign
                $acc.SaveAsText(3, $rpt.Name, (Join-Path $objectsDir "report_${safe}.txt"))
                $acc.DoCmd.Close(3, $rpt.Name)       # 3 = acReport
                $rCount++
            } catch {
                Write-Warning "  Report '$($rpt.Name)' skipped: $_"
            }
        }
    }
    Write-Host "  Reports: $rCount exported"

    # VBA
    $vCount = 0
    try {
        $proj = $acc.VBE.VBProjects.Item(1)
        for ($i = 1; $i -le $proj.VBComponents.Count; $i++) {
            $comp = $proj.VBComponents.Item($i)
            if ($comp.CodeModule.CountOfLines -gt 0) {
                $safe = $comp.Name -replace '[\\/:*?"<>|]', '_'
                $comp.CodeModule.Lines(1, $comp.CodeModule.CountOfLines) |
                    Set-Content (Join-Path $objectsDir "vba_${safe}.bas") -Encoding UTF8
                $vCount++
            }
        }
    } catch { Write-Warning "  VBA extraction failed: $_" }
    Write-Host "  VBA modules: $vCount exported"

    $acc.CloseCurrentDatabase()
    $acc.Quit()
    $acc = $null

} catch {
    if ($accessOk) {
        Write-Warning "  Access error: $_"
        try { $acc.Quit() } catch {}
    } else {
        Write-Error "Cannot open Microsoft Access. Ensure Access is installed on this machine.`nError: $_"
        Remove-Item $objectsDir -Recurse -Force
        exit 1
    }
}

# -- Step 3/3: Create zip -------------------------------------------------------
Write-Host ""
Write-Host "Step 3/3: Creating upload package..."

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$objectsDir\*" -DestinationPath $zipPath
Remove-Item $objectsDir -Recurse -Force

Write-Host ""
Write-Host "=========================================="
Write-Host " Done! Upload this file to AccessBooster:"
Write-Host "   $zipPath"
Write-Host "=========================================="
