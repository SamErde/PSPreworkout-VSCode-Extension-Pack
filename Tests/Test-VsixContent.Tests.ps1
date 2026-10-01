BeforeAll {
    $ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\scripts\Test-VsixContent.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-TestVsix {
        param (
            [string] $Path,
            [hashtable] $Entry
        )

        $Archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($Name in $Entry.Keys) {
                $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry($Name).Open())
                try {
                    $Writer.Write($Entry[$Name])
                } finally {
                    $Writer.Dispose()
                }
            }
        } finally {
            $Archive.Dispose()
        }
    }

    $PackageJson = '{ "name": "test-pack", "publisher": "Tester", "version": "1.2.3" }'
    $PackagePath = Join-Path -Path $TestDrive -ChildPath 'package.json'
    Set-Content -Path $PackagePath -Value $PackageJson -Encoding utf8
    $AllowedEntry = @('extension.vsixmanifest', 'extension/package.json', 'extension/readme.md')
}

Describe 'Test-VsixContent.ps1' {
    It 'passes when the VSIX matches the allow-list and package.json' {
        $VsixPath = Join-Path -Path $TestDrive -ChildPath 'valid.vsix'
        New-TestVsix -Path $VsixPath -Entry @{
            'extension.vsixmanifest' = '<xml />'
            'extension/package.json' = $PackageJson
            'extension/readme.md'    = '# Readme'
        }

        { & $ScriptPath -Path $VsixPath -PackagePath $PackagePath -AllowedEntry $AllowedEntry 6>$null } | Should -Not -Throw
    }

    It 'throws when the VSIX contains an unexpected file' {
        $VsixPath = Join-Path -Path $TestDrive -ChildPath 'unexpected.vsix'
        New-TestVsix -Path $VsixPath -Entry @{
            'extension.vsixmanifest'           = '<xml />'
            'extension/package.json'           = $PackageJson
            'extension/readme.md'              = '# Readme'
            'extension/.github/workflows/x.yml' = 'on: push'
        }

        { & $ScriptPath -Path $VsixPath -PackagePath $PackagePath -AllowedEntry $AllowedEntry } |
            Should -Throw -ExpectedMessage '*Unexpected: extension/.github/workflows/x.yml*'
    }

    It 'throws when the VSIX is missing an expected file' {
        $VsixPath = Join-Path -Path $TestDrive -ChildPath 'missing.vsix'
        New-TestVsix -Path $VsixPath -Entry @{
            'extension.vsixmanifest' = '<xml />'
            'extension/package.json' = $PackageJson
        }

        { & $ScriptPath -Path $VsixPath -PackagePath $PackagePath -AllowedEntry $AllowedEntry } |
            Should -Throw -ExpectedMessage '*Missing: extension/readme.md*'
    }

    It 'throws when the embedded version does not match package.json' {
        $VsixPath = Join-Path -Path $TestDrive -ChildPath 'version.vsix'
        New-TestVsix -Path $VsixPath -Entry @{
            'extension.vsixmanifest' = '<xml />'
            'extension/package.json' = '{ "name": "test-pack", "publisher": "Tester", "version": "9.9.9" }'
            'extension/readme.md'    = '# Readme'
        }

        { & $ScriptPath -Path $VsixPath -PackagePath $PackagePath -AllowedEntry $AllowedEntry } |
            Should -Throw -ExpectedMessage "*version '9.9.9' does not match*"
    }

    It 'throws when the VSIX file does not exist' {
        { & $ScriptPath -Path (Join-Path -Path $TestDrive -ChildPath 'absent.vsix') -PackagePath $PackagePath } |
            Should -Throw -ExpectedMessage 'VSIX file not found*'
    }
}
