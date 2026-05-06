BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\Get-ExtensionInfo.ps1')
}

Describe 'Get-ExtensionPackItem' {
    It 'returns each extension ID from package.json' {
        $PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
        @'
{
  "extensionPack": [
    "publisher.first-extension",
    "publisher.second-extension"
  ]
}
'@ | Set-Content -Path $PackagePath -Encoding utf8

        $Result = Get-ExtensionPackItem -PackagePath $PackagePath

        $Result.ExtensionId | Should -Be @('publisher.first-extension', 'publisher.second-extension')
        $Result[0].MarketplaceUri | Should -Be 'https://marketplace.visualstudio.com/items?itemName=publisher.first-extension'
    }

    It 'throws when package.json contains duplicate extension IDs' {
        $PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
        @'
{
  "extensionPack": [
    "publisher.duplicate-extension",
    "publisher.duplicate-extension"
  ]
}
'@ | Set-Content -Path $PackagePath -Encoding utf8

        { Get-ExtensionPackItem -PackagePath $PackagePath } | Should -Throw -ExpectedMessage '*Duplicate extension IDs*'
    }

    It 'throws when package.json is missing extensionPack' {
        $PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
        '{ "name": "sample" }' | Set-Content -Path $PackagePath -Encoding utf8

        { Get-ExtensionPackItem -PackagePath $PackagePath } | Should -Throw -ExpectedMessage '*does not define an extensionPack array*'
    }

    It 'throws when package.json has an empty extensionPack' {
        $PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
        '{ "extensionPack": [] }' | Set-Content -Path $PackagePath -Encoding utf8

        { Get-ExtensionPackItem -PackagePath $PackagePath } | Should -Throw -ExpectedMessage '*empty extensionPack array*'
    }

    It 'throws when package.json contains an invalid extension ID' {
        $PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
        @'
{
  "extensionPack": [
    "invalid-extension-id"
  ]
}
'@ | Set-Content -Path $PackagePath -Encoding utf8

        { Get-ExtensionPackItem -PackagePath $PackagePath } | Should -Throw -ExpectedMessage '*publisher.name format*'
    }
}

Describe 'Invoke-VsceShow' {
    BeforeEach {
        $script:FakeVscePath = Join-Path -Path $TestDrive -ChildPath 'fake-vsce.ps1'
    }

    It 'returns parsed JSON from a successful vsce call' {
        @'
if ($args[0] -eq 'show' -and $args[1] -eq '--json') {
    '{"displayName":"Sample Extension","shortDescription":"Sample","publisher":{"displayName":"Publisher"},"versions":[{"version":"1.0.0"}]}'
    exit 0
}

exit 1
'@ | Set-Content -Path $script:FakeVscePath -Encoding utf8

        $Result = Invoke-VsceShow -ExtensionId 'publisher.sample-extension' -VscePath $script:FakeVscePath

        $Result.displayName | Should -Be 'Sample Extension'
    }

    It 'throws when vsce returns invalid JSON' {
        @'
if ($args[0] -eq 'show' -and $args[1] -eq '--json') {
    'not-json'
    exit 0
}

exit 1
'@ | Set-Content -Path $script:FakeVscePath -Encoding utf8

        { Invoke-VsceShow -ExtensionId 'publisher.sample-extension' -VscePath $script:FakeVscePath } |
            Should -Throw -ExpectedMessage '*Conversion from JSON failed*'
    }
}

Describe 'ConvertTo-MarkdownTableValue' {
    It 'escapes table separators and normalizes whitespace' {
        $Value = "Name | with`n" + 'newline'
        $Result = ConvertTo-MarkdownTableValue -Value $Value

        $Result | Should -Be 'Name \| with newline'
    }

    It 'truncates long values' {
        $Result = ConvertTo-MarkdownTableValue -Value ('a' * 20) -MaximumLength 10

        $Result | Should -Be 'aaaaaaa...'
    }
}

Describe 'ConvertTo-ExtensionMarkdownDocument' {
    It 'creates badge URLs without escaping the query string separator' {
        $ExtensionInfo = [PSCustomObject]@{
            ExtensionId    = 'publisher.sample-extension'
            ExtensionName  = 'Sample Extension'
            Publisher      = 'Publisher'
            Version        = '1.2.3'
            Description    = 'Sample description'
            MarketplaceUri = 'https://marketplace.visualstudio.com/items?itemName=publisher.sample-extension'
        }

        $Result = ConvertTo-ExtensionMarkdownDocument -ExtensionInfo $ExtensionInfo

        $Result | Should -Match 'last-updated/publisher.sample-extension\?style=flat-square'
        $Result | Should -Not -Match '\\\?style='
    }
}

Describe 'Get-MarketplaceExtensionInfo' {
    It 'normalizes marketplace metadata returned by vsce' {
        Mock Invoke-VsceShow {
            [PSCustomObject]@{
                displayName      = 'Sample Extension'
                shortDescription = 'Sample description'
                publisher        = [PSCustomObject]@{
                    displayName = 'Publisher'
                }
                versions         = @(
                    [PSCustomObject]@{
                        version = '2.0.0'
                    }
                )
            }
        }

        $Result = Get-MarketplaceExtensionInfo -ExtensionId 'publisher.sample-extension' -VscePath 'vsce'

        $Result.ExtensionId | Should -Be 'publisher.sample-extension'
        $Result.ExtensionName | Should -Be 'Sample Extension'
        $Result.Publisher | Should -Be 'Publisher'
        $Result.Version | Should -Be '2.0.0'
        Should -Invoke Invoke-VsceShow -Exactly 1 -ParameterFilter {
            $ExtensionId -eq 'publisher.sample-extension' -and $VscePath -eq 'vsce'
        }
    }
}

Describe 'ConvertTo-MarkdownTableRow' {
    It 'creates one markdown row with marketplace badges' {
        $ExtensionInfo = [PSCustomObject]@{
            ExtensionId    = 'publisher.sample-extension'
            ExtensionName  = 'Sample Extension'
            Publisher      = 'Publisher'
            Version        = '1.2.3'
            Description    = 'Sample description'
            MarketplaceUri = 'https://marketplace.visualstudio.com/items?itemName=publisher.sample-extension'
        }

        $Result = ConvertTo-MarkdownTableRow -ExtensionInfo $ExtensionInfo

        $Result | Should -Be '|[Sample Extension](https://marketplace.visualstudio.com/items?itemName=publisher.sample-extension)|Publisher|1.2.3|Sample description|![Visual Studio Marketplace Installs](https://img.shields.io/visual-studio-marketplace/i/publisher.sample-extension?style=flat-square)|![Visual Studio Marketplace Last Updated](https://img.shields.io/visual-studio-marketplace/last-updated/publisher.sample-extension?style=flat-square)|'
    }
}

Describe 'Update-ExtensionInfoDocument' {
    BeforeEach {
        $script:PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
        $script:OutputPath = Join-Path -Path $TestDrive -ChildPath 'Extensions.md'
        @'
{
  "extensionPack": [
    "publisher.sample-extension"
  ]
}
'@ | Set-Content -Path $script:PackagePath -Encoding utf8
    }

    It 'writes generated extension information to the requested output path' {
        Mock Get-MarketplaceExtensionInfo {
            [PSCustomObject]@{
                ExtensionId    = $ExtensionId
                ExtensionName  = 'Sample Extension'
                Publisher      = 'Publisher'
                Version        = '1.2.3'
                Description    = 'Sample description'
                MarketplaceUri = "https://marketplace.visualstudio.com/items?itemName=$ExtensionId"
            }
        }

        Update-ExtensionInfoDocument -PackagePath $script:PackagePath -OutputPath $script:OutputPath -VscePath 'vsce'

        $script:OutputPath | Should -Exist
        Get-Content -Path $script:OutputPath -Raw | Should -Match 'Sample Extension'
        Should -Invoke Get-MarketplaceExtensionInfo -Exactly 1 -ParameterFilter {
            $ExtensionId -eq 'publisher.sample-extension'
        }
    }

    It 'returns generated markdown when PassThru is specified' {
        Mock Get-MarketplaceExtensionInfo {
            [PSCustomObject]@{
                ExtensionId    = $ExtensionId
                ExtensionName  = 'Sample Extension'
                Publisher      = 'Publisher'
                Version        = '1.2.3'
                Description    = 'Sample description'
                MarketplaceUri = "https://marketplace.visualstudio.com/items?itemName=$ExtensionId"
            }
        }

        $Result = Update-ExtensionInfoDocument -PackagePath $script:PackagePath -OutputPath $script:OutputPath -VscePath 'vsce' -PassThru

        $Result | Should -Match '# Extensions'
        $Result | Should -Match 'Sample Extension'
    }

    It 'creates the output directory when it does not exist' {
        $NestedOutputPath = Join-Path -Path $TestDrive -ChildPath 'nested\Extensions.md'
        Mock Get-MarketplaceExtensionInfo {
            [PSCustomObject]@{
                ExtensionId    = $ExtensionId
                ExtensionName  = 'Sample Extension'
                Publisher      = 'Publisher'
                Version        = '1.2.3'
                Description    = 'Sample description'
                MarketplaceUri = "https://marketplace.visualstudio.com/items?itemName=$ExtensionId"
            }
        }

        Update-ExtensionInfoDocument -PackagePath $script:PackagePath -OutputPath $NestedOutputPath -VscePath 'vsce'

        $NestedOutputPath | Should -Exist
    }
}
