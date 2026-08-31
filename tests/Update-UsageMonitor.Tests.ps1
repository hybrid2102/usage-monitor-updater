#Requires -Modules Pester

<#
    Unit tests for the pure, decision-making parts of the updater: version comparison,
    asset selection, size formatting and HTTP error normalisation. These are the places
    where a wrong answer is silent - it installs the wrong build, or hides a useful
    error message - so they are worth pinning down.

    Anything that touches the network, the filesystem or running processes is out of
    scope here and covered by running the script for real.
#>

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Update-UsageMonitor.ps1'
    . $script:ScriptPath
}

Describe 'ConvertTo-ComparableVersion' {
    It 'drops the fourth field so a 4-field product version matches a 3-field tag' {
        $exe = ConvertTo-ComparableVersion ([Version] '1.20.0.0')
        $tag = ConvertTo-ComparableVersion ([Version] '1.20.0')
        $exe | Should -Be $tag
    }

    It 'keeps genuinely different versions apart' {
        (ConvertTo-ComparableVersion ([Version] '1.20.1')) |
            Should -Not -Be (ConvertTo-ComparableVersion ([Version] '1.20.0'))
    }

    It 'normalises missing fields to zero rather than -1' {
        $result = ConvertTo-ComparableVersion ([Version] '2.0')
        $result.Build | Should -Be 0
        $result.ToString(3) | Should -Be '2.0.0'
    }
}

Describe 'Format-Size' {
    It 'renders <Bytes> bytes as <Expected>' -TestCases @(
        @{ Bytes = 512;      Expected = '512 B' }
        @{ Bytes = 2048;     Expected = '2 KB' }
        @{ Bytes = 13369344; Expected = '12.8 MB' }
    ) {
        # The MB case is culture-sensitive on the decimal separator; normalise it away.
        (Format-Size $Bytes) -replace ',', '.' | Should -Be $Expected
    }
}

Describe 'Select-ReleaseAsset' {
    BeforeAll {
        $script:OriginalArch = $env:PROCESSOR_ARCHITECTURE

        function Get-StubRelease {
            param([string[]] $Names)
            [pscustomobject]@{
                tag_name = 'v1.0.0'
                assets   = @($Names | ForEach-Object { [pscustomobject]@{ name = $_; size = 1 } })
            }
        }
    }

    It 'throws when the release ships no executable' {
        { Select-ReleaseAsset -Release (Get-StubRelease @('notes.txt', 'source.zip')) } |
            Should -Throw '*No .exe asset*'
    }

    It 'returns the only executable without looking at the architecture' {
        (Select-ReleaseAsset -Release (Get-StubRelease @('App.exe', 'checksums.txt'))).name |
            Should -Be 'App.exe'
    }

    It 'prefers the arm64 build on an arm64 machine' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        (Select-ReleaseAsset -Release (Get-StubRelease @('App-x64.exe', 'App-arm64.exe'))).name |
            Should -Be 'App-arm64.exe'
    }

    It 'prefers the x64 build on an x64 machine' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        (Select-ReleaseAsset -Release (Get-StubRelease @('App-arm64.exe', 'App-x64.exe'))).name |
            Should -Be 'App-x64.exe'
    }

    It 'never picks a foreign-architecture build when no name matches this one' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        (Select-ReleaseAsset -Release (Get-StubRelease @('App-arm64.exe', 'App.exe'))).name |
            Should -Be 'App.exe'
    }

    AfterAll {
        $env:PROCESSOR_ARCHITECTURE = $script:OriginalArch
    }
}

Describe 'Get-HttpErrorInfo' {
    <#
        Both PowerShell editions must be understood: 5.1 raises WebException with a
        WebHeaderCollection, 6+ raises HttpResponseException with an
        HttpResponseHeaders. Catching only one silently disables every friendly
        message on the other edition.
    #>

    It 'reads the status code from a Windows PowerShell style response' {
        $headers = [System.Net.WebHeaderCollection]::new()
        $headers.Add('X-RateLimit-Reset', '1700000000')

        $record = [pscustomobject]@{
            Exception = [pscustomobject]@{
                Response = [pscustomobject]@{ StatusCode = 403; Headers = $headers }
            }
        }

        $info = Get-HttpErrorInfo -ErrorRecord $record
        $info.Status | Should -Be 403
        $info.RateLimitReset | Should -Not -BeNullOrEmpty
    }

    It 'reads the status code from a PowerShell 7 style response' {
        # System.Net.Http is not loaded by default in Windows PowerShell 5.1, so the
        # real type has to be pulled in explicitly. Get-HttpErrorInfo itself is
        # duck-typed and needs neither assembly - only this test does.
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        if (-not ('System.Net.Http.HttpResponseMessage' -as [type])) {
            Set-ItResult -Skipped -Because 'System.Net.Http is unavailable on this runtime'
            return
        }

        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        try {
            $record = [pscustomobject]@{ Exception = [pscustomobject]@{ Response = $response } }
            (Get-HttpErrorInfo -ErrorRecord $record).Status | Should -Be 404
        }
        finally {
            $response.Dispose()
        }
    }

    It 'reads rate-limit headers through the PowerShell 7 TryGetValues shape' {
        # A stand-in for HttpResponseHeaders: same TryGetValues contract, no assembly
        # dependency, so this half of the branch is exercised on both editions.
        $headers = [pscustomobject]@{}
        $headers | Add-Member -MemberType ScriptMethod -Name TryGetValues -Value {
            param($name, [ref] $values)
            if ($name -eq 'X-RateLimit-Reset') { $values.Value = @('1700000000'); return $true }
            return $false
        }

        $record = [pscustomobject]@{
            Exception = [pscustomobject]@{
                Response = [pscustomobject]@{ StatusCode = 403; Headers = $headers }
            }
        }

        $info = Get-HttpErrorInfo -ErrorRecord $record
        $info.Status | Should -Be 403
        $info.RateLimitReset | Should -Not -BeNullOrEmpty
    }

    It 'reports status 0 when the request never reached the server' {
        $record = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'No such host is known' } }

        $info = Get-HttpErrorInfo -ErrorRecord $record
        $info.Status | Should -Be 0
        $info.RateLimitReset | Should -BeNullOrEmpty
    }
}

Describe 'Get-InstalledVersion' {
    It 'returns null for a path that does not exist' {
        Get-InstalledVersion -Path (Join-Path $TestDrive 'missing.exe') | Should -BeNullOrEmpty
    }

    It 'returns null instead of throwing when the file carries no version' {
        $file = Join-Path $TestDrive 'plain.exe'
        Set-Content -LiteralPath $file -Value 'not a real executable'
        Get-InstalledVersion -Path $file | Should -BeNullOrEmpty
    }
}

Describe 'Test-GalleryInstall' {
    <#
        Install-Script drops the script in a shared scripts folder. Defaulting
        -InstallDir to that folder would send the updater hunting for the application in
        a system directory, so the case has to be recognised - and, just as importantly,
        an ordinary folder that merely happens to be called "Scripts" must not be.
    #>

    It 'recognises <Path> as a Gallery install' -TestCases @(
        @{ Path = 'C:\Users\jo\Documents\WindowsPowerShell\Scripts' }
        @{ Path = 'C:\Users\jo\Documents\PowerShell\Scripts' }
        @{ Path = 'C:\Program Files\WindowsPowerShell\Scripts' }
        @{ Path = 'C:\Program Files\PowerShell\Scripts\' }
    ) {
        Test-GalleryInstall -Path $Path | Should -BeTrue
    }

    It 'leaves <Path> alone' -TestCases @(
        @{ Path = 'C:\Tools\UsageMonitor' }
        @{ Path = 'D:\Projects\MyApp\Scripts' }
        @{ Path = 'C:\Users\jo\PowerShell' }
        @{ Path = 'C:\WindowsPowerShell' }
    ) {
        Test-GalleryInstall -Path $Path | Should -BeFalse
    }
}
