#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies that a packaged VSIX contains exactly the expected files.

.DESCRIPTION
    Opens the VSIX (a zip archive) and compares its entries against an allow-list. Any missing or
    unexpected entry fails the check, which prevents accidentally shipping repository files such as
    scripts, tests, workflow files, or credentials. The embedded extension/package.json is also checked
    so the VSIX name, publisher, and version match the repository package.json.

.PARAMETER Path
    Path to the VSIX file to verify.

.PARAMETER PackagePath
    Path to the repository package.json used to verify the embedded manifest.

.PARAMETER AllowedEntry
    The exact set of entries the VSIX is allowed and required to contain.

.EXAMPLE
    ./scripts/Test-VsixContent.ps1 -Path ./dist/pspreworkout-powershell-extensions-pack.vsix

    Verifies the VSIX and throws if its contents differ from the allow-list.

.OUTPUTS
    None. Throws a terminating error when verification fails.
#>
[CmdletBinding()]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $Path = './dist/pspreworkout-powershell-extensions-pack.vsix',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $PackagePath = './package.json',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]
    $AllowedEntry = @(
        '[Content_Types].xml'
        'extension.vsixmanifest'
        'extension/changelog.md'
        'extension/Extensions.md'
        'extension/images/logo.png'
        'extension/LICENSE.txt'
        'extension/package.json'
        'extension/readme.md'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "VSIX file not found: $Path"
}

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "package.json not found: $PackagePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$ResolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
$Archive = [System.IO.Compression.ZipFile]::OpenRead($ResolvedPath)
try {
    # Directory entries end with '/' and carry no content, so only compare file entries.
    $ActualEntry = @($Archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object FullName)

    $Missing = @($AllowedEntry | Where-Object { $_ -cnotin $ActualEntry })
    $Unexpected = @($ActualEntry | Where-Object { $_ -cnotin $AllowedEntry })

    if ($Missing.Count -gt 0 -or $Unexpected.Count -gt 0) {
        $Message = "VSIX content does not match the allow-list ($Path)."
        if ($Missing.Count -gt 0) {
            $Message += " Missing: $($Missing -join ', ')."
        }
        if ($Unexpected.Count -gt 0) {
            $Message += " Unexpected: $($Unexpected -join ', ')."
        }
        throw $Message
    }

    $Reader = [System.IO.StreamReader]::new($Archive.GetEntry('extension/package.json').Open())
    try {
        $EmbeddedPackage = $Reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $Reader.Dispose()
    }
} finally {
    $Archive.Dispose()
}

$RepositoryPackage = Get-Content -LiteralPath $PackagePath -Raw | ConvertFrom-Json
foreach ($Property in 'name', 'publisher', 'version') {
    if ($EmbeddedPackage.$Property -cne $RepositoryPackage.$Property) {
        throw "VSIX $Property '$($EmbeddedPackage.$Property)' does not match package.json '$($RepositoryPackage.$Property)'."
    }
}

Write-Information -MessageData "VSIX content verified: $($ActualEntry.Count) entries match the allow-list." -InformationAction Continue
