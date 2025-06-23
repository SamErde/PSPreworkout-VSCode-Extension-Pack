<#
.SYNOPSIS
    Fetches extension information from the Visual Studio Marketplace and generates a markdown table.

.DESCRIPTION
    This script reads extension IDs from package.json, fetches details from the VS Marketplace, and generates a markdown
    table with extension information including badges for version, install count, and last updated date.

.EXAMPLE
    .\Get-ExtensionInfo.ps1
    Generates Extensions.md with information about all extensions listed in package.json
#>

# Ensure package.json exists
if (-not (Test-Path -Path '.\package.json')) {
    throw 'package.json not found in current directory'
}

$ExtensionIds = Get-Content -Path .\package.json | ConvertFrom-Json | Select-Object -ExpandProperty extensionPack

$BaseUri = 'https://marketplace.visualstudio.com/items?itemName='
$ShieldBaseUri = 'https://img.shields.io/visual-studio-marketplace'
$ShieldStyle = 'flat-square'

<#
    Use `vsce show --json 'SamErde.pspreworkout-powershell-extensions-pack'` instead of IWR.
#>

# Initialize StringBuilder for all extension rows
$AllExtensionRows = [System.Text.StringBuilder]::new()

# Add markdown table header
$AllExtensionRows.AppendLine('| Extension | Publisher | Version | Description | Installs | Last Updated |') > $null
$AllExtensionRows.AppendLine('|-----------|-----------|---------|-------------|----------|--------------|') > $null

$ExtensionIds | ForEach-Object {

    $ExtensionId = $_
    $ExtensionUri = $BaseUri + $ExtensionId # Visual Studio Marketplace URL for the extension

    try {
        Write-Host "Fetching details for: $ExtensionId" -ForegroundColor Cyan
        $Response = Invoke-WebRequest -Uri $ExtensionUri -UseBasicParsing -ErrorAction Stop

        # Extract extension name from the response content.
        # $ExtensionName = $ExtensionId # Fallback to the extension ID if name extraction fails.
        # Look for example: `<span class="ux-item-name">CodeSnap</span>`
        if ($Response.Content -match '<span class="ux-item-name">([^<]+)</span>') {
            # $ExtensionName = $matches[1].Trim()
            # Remove any HTML encoding within the extension name.
            $ExtensionName = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        }

        # Extract extension description from the response content.
        # Example: `<div class="ux-item-shortdesc">📷 Take beautiful screenshots of your code</div>`
        if ($Response.Content -match '<div class="ux-item-shortdesc">([^<]+)</div>') {
            # $ExtensionDescription = $matches[1].Trim()
            # Remove any HTML encoding within the description.
            $ExtensionDescription = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
            # Truncate description if too long
            if ($ExtensionDescription.Length -gt 100) {
                $ExtensionDescription = $ExtensionDescription.Substring(0, 97) + '...'
            }
        }

        # Extract publisher name from the response content.
        # Try multiple patterns to find the publisher.
        if ($Response.Content -match '<a[^>]*class="[^"]*ux-item-publisher-link[^"]*"[^>]*>([^<]+)</a>') {
            $ExtensionPublisher = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        } elseif ($Response.Content -match '<div[^>]*class="[^"]*ux-item-publisher[^"]*"[^>]*>.*?>([^<]+)</') {
            $ExtensionPublisher = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        } elseif ($Response.Content -match 'ux-item-publisher[^>]*>.*?>([^<]+)</') {
            $ExtensionPublisher = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        } else {
            $ExtensionPublisher = 'Unknown Publisher'
        }

        # Get the extension version from the response content.
        if ($Response.Content -match 'io/extensions/[^/]+/[^/]+/(\d+\.\d+\.\d+)/') {
            $ExtensionVersion = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        } elseif ($Response.Content -match '<td[^>]*role="definition"[^>]*aria-labelledby="version"[^>]*>([^<]+)</td>') {
            $ExtensionVersion = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        } elseif ($Response.Content -match 'aria-labelledby="version"[^>]*>([^<]+)</') {
            $ExtensionVersion = [System.Web.HttpUtility]::HtmlDecode($matches[1].Trim())
        } elseif ($Response.Content -match '<span class="ux-item-version">([^<]+)</span>') {
            $ExtensionVersion = $matches[1]
        } else {
            $ExtensionVersion = 'Unknown Version'
        }
    } catch {
        Write-Warning "Failed to fetch details for $ExtensionId : $($_.Exception.Message)"
        $ExtensionName = $ExtensionId
        $ExtensionDescription = 'Failed to fetch description'
        $ExtensionPublisher = 'Unknown Publisher'
        $ExtensionVersion = 'Unknown Version'
    }

    $ExtensionNameLink = "[$ExtensionName]($ExtensionUri)"
    $ExtensionInstalls = "![Visual Studio Marketplace Installs](${ShieldBaseUri}/i/${ExtensionId}?style=${ShieldStyle})"
    $ExtensionLastUpdated = "![Visual Studio Marketplace Last Updated](${ShieldBaseUri}/last-updated/${ExtensionId}?style=${ShieldStyle})"

    # Create markdown table row with clickable extension name
    $ExtensionRow = "|$ExtensionNameLink|$ExtensionPublisher|$ExtensionVersion|$ExtensionDescription|$ExtensionInstalls|$ExtensionLastUpdated"
    $AllExtensionRows.AppendLine("$ExtensionRow") > $null

    # Small delay to be respectful to the VS Marketplace servers
    Start-Sleep -Milliseconds 1500
}

$AllExtensionRows.ToString() | Out-File -FilePath .\Extensions.md -Encoding utf8 -Force
