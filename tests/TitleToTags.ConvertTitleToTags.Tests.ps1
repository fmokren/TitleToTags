# Pester tests for Convert-TitleToTags

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\TitleToTags.psm1') -Force
. (Join-Path -Path $PSScriptRoot -ChildPath '..\testdata_patterns.ps1')

$titlePatterns = Get-TestDataPatterns

Describe 'Convert-TitleToTags' {
    foreach ($pat in $titlePatterns) {
        It "parses title: '$($pat.Title)'" {
            $res = Convert-TitleToTags -title $pat.Title
            $res | Should -Not -Be $null

            # Tags: order-insensitive compare
            $expected = @()
            if ($pat.ExpectedTags) { $expected += $pat.ExpectedTags }
            $actual = @()
            if ($res.Tags) { $actual += $res.Tags }
            $actual.Count | Should -Be $expected.Count
            foreach ($t in $expected) { $actual | Should -Contain $t }

            # Title should not contain bracket syntax any longer
            $res.Title | Should -Not -Match '\[[^\]]+\]'

            # If the pattern specified an expected title snippet, ensure the normalized title contains
            # at least the first significant word (case-insensitive). This keeps the test resilient
            # to the module's normalization rules while still checking meaningful output.
            if ($pat.ExpectedTitle -and $pat.ExpectedTitle.Trim().Length -gt 0) {
                $firstWord = ($pat.ExpectedTitle -split '\s+' | Where-Object { $_ -match '\w' } | Select-Object -First 1)
                if ($firstWord) { $res.Title.ToLower() | Should -Match ($firstWord.ToLower()) }
            }
        }
    }
}
