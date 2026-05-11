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

.PARAMETER ReadmePath
    Path to README.md where the generated extension table should be synced.

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
[OutputType([String])]
param(
    [Parameter()]
    [ValidateScript({
        if (Test-Path -Path $_ -PathType Leaf) {
            return $true
        }
    })]
    [string]$PackagePath = (Join-Path -Path $PSScriptRoot -ChildPath 'package.json'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Extensions.md'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReadmePath = (Join-Path -Path $PSScriptRoot -ChildPath 'README.md'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VscePath = 'vsce',

    [Parameter()]
    [switch]$PassThru
)

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
    $InstallCount = Get-ExtensionStatisticValue -MarketplaceExtension $MarketplaceExtension -StatisticName 'install'
    $LastUpdated = ConvertTo-MarketplaceDate -Value $MarketplaceExtension.lastUpdated -FieldName 'lastUpdated' -ExtensionId $ExtensionId

    [PSCustomObject]@{
        ExtensionId    = $ExtensionId
        ExtensionName  = $MarketplaceExtension.displayName
        Publisher      = $MarketplaceExtension.publisher.displayName
        Version        = $LatestVersion.version
        Description    = $MarketplaceExtension.shortDescription
        InstallCount   = $InstallCount
        LastUpdated    = $LastUpdated
        MarketplaceUri = "https://marketplace.visualstudio.com/items?itemName=$ExtensionId"
    }
}

function Get-ExtensionStatisticValue {
    <#
    .SYNOPSIS
        Gets one numeric statistic from Visual Studio Marketplace metadata.

    .DESCRIPTION
        Finds a named statistic from a marketplace extension response and
        returns its numeric value. A missing statistic is treated as invalid
        marketplace data so generated documentation does not silently go stale.

    .PARAMETER MarketplaceExtension
        Marketplace extension metadata returned by vsce show --json.

    .PARAMETER StatisticName
        Statistic name to read, such as install or updateCount.

    .OUTPUTS
        Double statistic value.

    .EXAMPLE
        Get-ExtensionStatisticValue -MarketplaceExtension $Extension -StatisticName install
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$MarketplaceExtension,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StatisticName
    )

    $Statistic = @($MarketplaceExtension.statistics) |
        Where-Object { $_.statisticName -eq $StatisticName } |
        Select-Object -First 1

    if ($null -eq $Statistic) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("Marketplace metadata for '$($MarketplaceExtension.extensionId)' does not include the '$StatisticName' statistic."),
            'MarketplaceStatisticMissing',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $MarketplaceExtension
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    [double]$Statistic.value
}

function ConvertTo-MarketplaceDate {
    <#
    .SYNOPSIS
        Converts a marketplace timestamp to a date string.

    .DESCRIPTION
        Parses a marketplace timestamp and formats it as yyyy-MM-dd for
        readable generated documentation and static badges.

    .PARAMETER Value
        Timestamp value to parse.

    .PARAMETER FieldName
        Name of the timestamp field being parsed.

    .PARAMETER ExtensionId
        Extension ID used in parse error messages.

    .OUTPUTS
        String in yyyy-MM-dd format.

    .EXAMPLE
        ConvertTo-MarketplaceDate -Value $Extension.lastUpdated -FieldName lastUpdated -ExtensionId ms-vscode.powershell
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FieldName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExtensionId
    )

    $ParsedDate = [System.DateTimeOffset]::MinValue
    if (-not [System.DateTimeOffset]::TryParse($Value, [ref]$ParsedDate)) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.FormatException]::new("Marketplace metadata field '$FieldName' for '$ExtensionId' is not a valid timestamp: '$Value'."),
            'MarketplaceDateParseFailed',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $Value
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    $ParsedDate.UtcDateTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-CompactNumber {
    <#
    .SYNOPSIS
        Formats a number for compact badge display.

    .DESCRIPTION
        Converts large marketplace counts into short invariant strings, such as
        1.23K, 4.56M, or 7.89B.

    .PARAMETER Value
        Numeric value to format.

    .OUTPUTS
        Compact count string.

    .EXAMPLE
        ConvertTo-CompactNumber -Value 1234567
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, [double]::MaxValue)]
        [double]$Value
    )

    $Suffixes = @(
        [PSCustomObject]@{ Threshold = 1000000000; Suffix = 'B' }
        [PSCustomObject]@{ Threshold = 1000000; Suffix = 'M' }
        [PSCustomObject]@{ Threshold = 1000; Suffix = 'K' }
    )

    foreach ($Suffix in $Suffixes) {
        if ($Value -ge $Suffix.Threshold) {
            $CompactValue = $Value / $Suffix.Threshold
            return ('{0:0.##}{1}' -f $CompactValue, $Suffix.Suffix)
        }
    }

    ('{0:0}' -f $Value)
}

function ConvertTo-StaticShieldBadge {
    <#
    .SYNOPSIS
        Creates a static shields.io badge URL.

    .DESCRIPTION
        Builds a static badge URL from generated marketplace values instead of
        relying on retired dynamic Visual Studio Marketplace badge endpoints.

    .PARAMETER Label
        Badge label.

    .PARAMETER Message
        Badge message.

    .PARAMETER Color
        Badge color.

    .PARAMETER Style
        Badge style.

    .OUTPUTS
        Static shields.io badge URL.

    .EXAMPLE
        ConvertTo-StaticShieldBadge -Label installs -Message 1.23M
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Color = 'blue',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Style = 'for-the-badge'
    )

    $Parameters = [ordered]@{
        label   = $Label
        message = $Message
        color   = $Color
        style   = $Style
    }

    $Query = foreach ($Parameter in $Parameters.GetEnumerator()) {
        '{0}={1}' -f $Parameter.Key, [System.Uri]::EscapeDataString($Parameter.Value)
    }

    'https://img.shields.io/static/v1?{0}' -f ($Query -join '&')
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
        [string]$ShieldStyle = 'for-the-badge'
    )

    process {
        $ExtensionName = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.ExtensionName
        $Publisher = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.Publisher
        $Version = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.Version
        $Description = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.Description
        $InstallCount = ConvertTo-CompactNumber -Value $ExtensionInfo.InstallCount
        $LastUpdated = ConvertTo-MarkdownTableValue -Value $ExtensionInfo.LastUpdated
        $MarketplaceUri = $ExtensionInfo.MarketplaceUri
        $ExtensionInstalls = "![Visual Studio Marketplace Installs]($(ConvertTo-StaticShieldBadge -Label 'installs' -Message $InstallCount -Style $ShieldStyle))"
        $ExtensionLastUpdated = "![Visual Studio Marketplace Last Updated]($(ConvertTo-StaticShieldBadge -Label 'updated' -Message $LastUpdated -Style $ShieldStyle))"

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

function Update-ReadmeExtensionTable {
    <#
    .SYNOPSIS
        Syncs the generated extension table into README.md.

    .DESCRIPTION
        Replaces the README Extensions Included section with the table from the
        generated Extensions.md document so both public docs stay consistent.

    .PARAMETER ReadmePath
        Path to README.md.

    .PARAMETER ExtensionMarkdown
        Complete generated Extensions.md document.

    .PARAMETER PackageInfo
        Optional marketplace metadata for this extension pack, used to refresh
        README header badges.

    .OUTPUTS
        None.

    .EXAMPLE
        Update-ReadmeExtensionTable -ReadmePath .\README.md -ExtensionMarkdown $Markdown
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({
            if (Test-Path -Path $_ -PathType Leaf) {
                return $true
            }
        })]
        [string]$ReadmePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExtensionMarkdown,

        [Parameter()]
        [PSCustomObject]$PackageInfo
    )

    $Readme = Get-Content -Path $ReadmePath -Raw -ErrorAction Stop
    $Heading = '## Extensions Included'
    $ReadmeParts = $Readme -split [regex]::Escape($Heading), 2
    if ($ReadmeParts.Count -ne 2) {
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("README '$ReadmePath' does not contain the '$Heading' heading."),
            'ReadmeExtensionHeadingMissing',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $ReadmePath
        )
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    $Table = ($ExtensionMarkdown -replace '^# Extensions\r?\n\r?\n', '').TrimEnd()
    $UpdatedReadme = $ReadmeParts[0].TrimEnd() +
        [Environment]::NewLine +
        [Environment]::NewLine +
        $Heading +
        [Environment]::NewLine +
        [Environment]::NewLine +
        $Table +
        [Environment]::NewLine

    if ($PackageInfo) {
        $PackageVersion = ConvertTo-MarkdownTableValue -Value $PackageInfo.Version
        $PackageInstalls = ConvertTo-CompactNumber -Value $PackageInfo.InstallCount
        $VersionBadge = "[![Version]($(ConvertTo-StaticShieldBadge -Label 'version' -Message $PackageVersion -Style 'flat'))]($($PackageInfo.MarketplaceUri))"
        $InstallsBadge = "[![Installs]($(ConvertTo-StaticShieldBadge -Label 'installs' -Message $PackageInstalls -Style 'flat'))]($($PackageInfo.MarketplaceUri))"
        $ReadmeLines = @($UpdatedReadme -split '\r?\n')

        for ($LineIndex = 0; $LineIndex -lt $ReadmeLines.Count; $LineIndex++) {
            if ($ReadmeLines[$LineIndex].StartsWith('[![Version](')) {
                $ReadmeLines[$LineIndex] = $VersionBadge
            } elseif ($ReadmeLines[$LineIndex].StartsWith('[![Installs](')) {
                $ReadmeLines[$LineIndex] = $InstallsBadge
            }
        }

        $UpdatedReadme = ($ReadmeLines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    }

    $Utf8Encoding = [System.Text.UTF8Encoding]::new($false)
    $ResolvedReadmePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReadmePath)
    if ($PSCmdlet.ShouldProcess($ResolvedReadmePath, 'Sync generated extension table')) {
        [System.IO.File]::WriteAllText($ResolvedReadmePath, $UpdatedReadme, $Utf8Encoding)
    }
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

    .PARAMETER ReadmePath
        Optional path to README.md where the generated table should be synced.

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
        [ValidateNotNullOrEmpty()]
        [string]$ReadmePath,

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

    if ($ReadmePath) {
        $PackageManifest = Get-Content -Path $PackagePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        $PackageInfo = $null
        if ('publisher' -in $PackageManifest.PSObject.Properties.Name -and 'name' -in $PackageManifest.PSObject.Properties.Name) {
            $PackageExtensionId = "$($PackageManifest.publisher).$($PackageManifest.name)"
            $PackageInfo = Get-MarketplaceExtensionInfo -ExtensionId $PackageExtensionId -VscePath $VscePath -ErrorAction Stop
        }

        Update-ReadmeExtensionTable -ReadmePath $ReadmePath -ExtensionMarkdown $Markdown -PackageInfo $PackageInfo
    }

    if ($PassThru.IsPresent) {
        $Markdown
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    Update-ExtensionInfoDocument -PackagePath $PackagePath -OutputPath $OutputPath -VscePath $VscePath -ReadmePath $ReadmePath -PassThru:$PassThru
}
