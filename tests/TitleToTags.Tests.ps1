Import-Module Pester

Describe 'Convert-TitleToTags' {
    It 'extracts tags and returns cleaned title' {
    Import-Module -Name (Join-Path $PSScriptRoot '..' 'TitleToTags.psm1') -Force
    $title = "[UI] [critical] Fix crash when loading - causes OOM"
    $res = Convert-TitleToTags -title $title
    $res.Title | Should -Be 'Fix crash when loading - causes OOM'
    $res.Tags | Should -BeExactly @('UI','critical')
    }

    It 'handles no tags' {
    Import-Module -Name (Join-Path $PSScriptRoot '..' 'TitleToTags.psm1') -Force
        $title = 'Simple title with no tags'
        $res = Convert-TitleToTags -title $title
        $res.Title | Should -Be $title
        $res.Tags.Count | Should -Be 0
    }

    It 'does not extract bracketed tokens that are not at the start' {
        Import-Module -Name (Join-Path $PSScriptRoot '..' 'TitleToTags.psm1') -Force
        $title = 'Do not touch this [Bracketed] middle token'
        $res = Convert-TitleToTags -title $title
        $res.Title | Should -Be $title
        $res.Tags.Count | Should -Be 0
    }
}
