<#
.SYNOPSIS
    Generates markdown extension metadata from a VS Code extension pack manifest.

.DESCRIPTION
    Reads extension IDs from package.json, resolves marketplace metadata with
    vsce show --json, and writes a markdown table for the included extensions.

.PARAMETER PackagePath
    Path to the package.json file that contains the extensionPack array.

.PARAMETER OutputPath
    Path to the markdown file to create or overwrite.

.PARAMETER VscePath
    Path or command name for the vsce executable.

.PARAMETER PassThru
    Returns the generated markdown document to the pipeline.

.EXAMPLE
    .\Get-ExtensionInfo.ps1

    Generates Extensions.md from the package.json file in the repository root.

.EXAMPLE
    .\Get-ExtensionInfo.ps1 -PackagePath .\package.json -OutputPath .\Extensions.md -Verbose

    Generates extension metadata with verbose progress messages.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateScript({
            if (Test-Path -Path $_ -PathType Leaf) {
                return $true
            }

            throw "Package path '$_' does not exist or is not a file."
        })]
    [string]$PackagePath = (Join-Path -Path $PSScriptRoot -ChildPath 'package.json'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Extensions.md'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VscePath = 'vsce',

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest

function Get-ExtensionPackItem {
    <#
    .SYNOPSIS
        Reads extension IDs from a VS Code extension pack manifest.

    .DESCRIPTION
        Parses package.json, validates that extensionPack exists, and returns
        one object per unique extension ID.

    .PARAMETER PackagePath
        Path to the package.json file to read.

    .OUTPUTS
        PSCustomObject with ExtensionId and MarketplaceUri properties.

    .EXAMPLE
        Get-ExtensionPackItem -PackagePath .\package.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackagePath
    )

    try {
        $Package = Get-Content -Path $PackagePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            $_.Exception,
            'PackageJsonReadFailed',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $PackagePath
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    if ('extensionPack' -notin $Package.PSObject.Properties.Name) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Package '$PackagePath' does not define an extensionPack array."),
            'ExtensionPackMissing',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $PackagePath
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    $ExtensionIds = @($Package.extensionPack)
    if ($ExtensionIds.Count -eq 0) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Package '$PackagePath' has an empty extensionPack array."),
            'ExtensionPackEmpty',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $PackagePath
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    $DuplicateIds = $ExtensionIds |
        Group-Object |
        Where-Object { $_.Count -gt 1 } |
        Select-Object -ExpandProperty Name

    if ($DuplicateIds) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Duplicate extension IDs found: $($DuplicateIds -join ', ')."),
            'DuplicateExtensionId',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $PackagePath
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    foreach ($ExtensionId in $ExtensionIds) {
        if ($ExtensionId -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*$') {
            $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new("Extension ID '$ExtensionId' is not in publisher.name format."),
                'InvalidExtensionId',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $ExtensionId
            )
            $PSCmdlet.ThrowTerminatingError($ErrorRecord)
        }

        [PSCustomObject]@{
            ExtensionId    = $ExtensionId
            MarketplaceUri = "https://marketplace.visualstudio.com/items?itemName=$ExtensionId"
        }
    }
}

function Invoke-VsceShow {
    <#
    .SYNOPSIS
        Gets raw marketplace metadata by invoking vsce.

    .DESCRIPTION
        Calls vsce show --json for one extension ID and converts the JSON
        response into a PowerShell object.

    .PARAMETER ExtensionId
        Extension ID in publisher.name format.

    .PARAMETER VscePath
        Path or command name for the vsce executable.

    .OUTPUTS
        PSCustomObject returned from the vsce JSON response.

    .EXAMPLE
        Invoke-VsceShow -ExtensionId ms-vscode.powershell -VscePath vsce
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*$')]
        [string]$ExtensionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VscePath
    )

    $OriginalConsoleEncoding = [Console]::OutputEncoding
    $RetryCount = 3
    $RetryDelaySeconds = 2
    $Output = $null

    for ($Attempt = 1; $Attempt -le $RetryCount; $Attempt++) {
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $Output = & $VscePath show --json $ExtensionId 2>&1
            if ($LASTEXITCODE -eq 0) {
                break
            }
        } finally {
            [Console]::OutputEncoding = $OriginalConsoleEncoding
        }

        if ($Attempt -lt $RetryCount) {
            Write-Verbose "Retrying details for '$ExtensionId' after vsce failure: $($Output -join ' ')"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("vsce show failed for '$ExtensionId': $($Output -join ' ')"),
            'VsceShowFailed',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $ExtensionId
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
        return
    }

    try {
        $Output -join [Environment]::NewLine | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            $_.Exception,
            'VsceJsonParseFailed',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $ExtensionId
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
        return
    }
}

function ConvertTo-MarkdownTableValue {
    <#
    .SYNOPSIS
        Escapes text for safe use in a markdown table cell.

    .DESCRIPTION
        Decodes HTML entities, normalizes whitespace, escapes markdown table
        separators, and optionally truncates long values.

    .PARAMETER Value
        Text to format for markdown table output.

    .PARAMETER MaximumLength
        Maximum output length before truncation.

    .OUTPUTS
        String formatted for a markdown table cell.

    .EXAMPLE
        ConvertTo-MarkdownTableValue -Value 'A | B'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value,

        [Parameter()]
        [ValidateRange(10, 1000)]
        [int]$MaximumLength = 100
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $FormattedValue = [System.Net.WebUtility]::HtmlDecode($Value).Trim()
    $FormattedValue = $FormattedValue -replace '\r?\n', ' '
    $FormattedValue = $FormattedValue -replace '\s{2,}', ' '
    $FormattedValue = $FormattedValue -replace '\|', '\|'

    if ($FormattedValue.Length -gt $MaximumLength) {
        $FormattedValue = $FormattedValue.Substring(0, $MaximumLength - 3).TrimEnd() + '...'
    }

    $FormattedValue
}

function Get-MarketplaceExtensionInfo {
    <#
    .SYNOPSIS
        Normalizes marketplace metadata for one extension.

    .DESCRIPTION
        Reads marketplace metadata through vsce and converts the raw response to
        the fields needed by the generated extension table.

    .PARAMETER ExtensionId
        Extension ID in publisher.name format.

    .PARAMETER VscePath
        Path or command name for the vsce executable.

    .OUTPUTS
        PSCustomObject with normalized extension metadata.

    .EXAMPLE
        Get-MarketplaceExtensionInfo -ExtensionId ms-vscode.powershell -VscePath vsce
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*$')]
        [string]$ExtensionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VscePath
    )

    Write-Verbose "Fetching details for: $ExtensionId"
    $MarketplaceExtension = Invoke-VsceShow -ExtensionId $ExtensionId -VscePath $VscePath
    $LatestVersion = @($MarketplaceExtension.versions)[0]

    [PSCustomObject]@{
        ExtensionId    = $ExtensionId
        ExtensionName  = $MarketplaceExtension.displayName
        Publisher      = $MarketplaceExtension.publisher.displayName
        Version        = $LatestVersion.version
        Description    = $MarketplaceExtension.shortDescription
        MarketplaceUri = "https://marketplace.visualstudio.com/items?itemName=$ExtensionId"
    }
}

function ConvertTo-MarkdownTableRow {
    <#
    .SYNOPSIS
        Converts normalized extension metadata to a markdown table row.

    .DESCRIPTION
        Creates one markdown table row with marketplace links and shields.io
        badges for installs and last updated date.

    .PARAMETER ExtensionInfo
        Normalized extension metadata object.

    .PARAMETER ShieldStyle
        shields.io badge style to use.

    .OUTPUTS
        String containing a markdown table row.

    .EXAMPLE
        ConvertTo-MarkdownTableRow -ExtensionInfo $ExtensionInfo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$ExtensionInfo,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ShieldStyle = 'flat-square'
    )

    process {
        $ShieldBaseUri = 'https://img.shields.io/visual-studio-marketplace'
        $ExtensionId = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.ExtensionId
        $ExtensionName = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.ExtensionName
        $Publisher = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.Publisher
        $Version = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.Version
        $Description = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.Description
        $MarketplaceUri = $ExtensionInfo.MarketplaceUri
        $ExtensionInstalls = "![Visual Studio Marketplace Installs]($ShieldBaseUri/i/$ExtensionId`?style=$ShieldStyle)"
        $ExtensionLastUpdated = "![Visual Studio Marketplace Last Updated]($ShieldBaseUri/last-updated/$ExtensionId`?style=$ShieldStyle)"

        "|[$ExtensionName]($MarketplaceUri)|$Publisher|$Version|$Description|$ExtensionInstalls|$ExtensionLastUpdated|"
    }
}

function ConvertTo-ExtensionMarkdownDocument {
    <#
    .SYNOPSIS
        Builds the generated extension markdown document.

    .DESCRIPTION
        Creates the Extensions.md content from normalized extension metadata.

    .PARAMETER ExtensionInfo
        Collection of normalized extension metadata objects.

    .OUTPUTS
        String containing the complete markdown document.

    .EXAMPLE
        ConvertTo-ExtensionMarkdownDocument -ExtensionInfo $ExtensionInfo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject[]]$ExtensionInfo
    )

    $Builder = [System.Text.StringBuilder]::new()
    [void]$Builder.AppendLine('# Extensions')
    [void]$Builder.AppendLine()
    [void]$Builder.AppendLine('| Extension | Publisher | Version | Description | Installs | Last Updated |')
    [void]$Builder.AppendLine('|-----------|-----------|---------|-------------|----------|--------------|')

    foreach ($Extension in $ExtensionInfo) {
        [void]$Builder.AppendLine((ConvertTo-MarkdownTableRow -ExtensionInfo $Extension))
    }

    $Builder.ToString()
}

function Update-ExtensionInfoDocument {
    <#
    .SYNOPSIS
        Updates the generated extension information markdown file.

    .DESCRIPTION
        Reads extension IDs from package.json, resolves their marketplace
        metadata, writes the generated markdown document, and optionally returns
        the generated content.

    .PARAMETER PackagePath
        Path to the package.json file that contains the extensionPack array.

    .PARAMETER OutputPath
        Path to the markdown file to create or overwrite.

    .PARAMETER VscePath
        Path or command name for the vsce executable.

    .PARAMETER PassThru
        Returns the generated markdown document to the pipeline.

    .OUTPUTS
        String when PassThru is specified.

    .EXAMPLE
        Update-ExtensionInfoDocument -PackagePath .\package.json -OutputPath .\Extensions.md
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VscePath,

        [Parameter()]
        [switch]$PassThru
    )

    $ExtensionInfo = foreach ($ExtensionItem in (Get-ExtensionPackItem -PackagePath $PackagePath)) {
        Get-MarketplaceExtensionInfo -ExtensionId $ExtensionItem.ExtensionId -VscePath $VscePath -ErrorAction Stop
    }

    $Markdown = ConvertTo-ExtensionMarkdownDocument -ExtensionInfo $ExtensionInfo
    $OutputDirectory = Split-Path -Path $OutputPath -Parent

    if ($OutputDirectory -and -not (Test-Path -Path $OutputDirectory -PathType Container)) {
        [void](New-Item -Path $OutputDirectory -ItemType Directory -Force)
    }

    $Utf8Encoding = [System.Text.UTF8Encoding]::new($false)
    $ResolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if ($PSCmdlet.ShouldProcess($ResolvedOutputPath, 'Write extension information markdown')) {
        [System.IO.File]::WriteAllText($ResolvedOutputPath, $Markdown, $Utf8Encoding)
    }

    if ($PassThru.IsPresent) {
        $Markdown
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Update-ExtensionInfoDocument -PackagePath $PackagePath -OutputPath $OutputPath -VscePath $VscePath -PassThru:$PassThru
}
