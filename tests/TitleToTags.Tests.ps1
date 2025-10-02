Import-Module Pester

Describe 'Process-TitleToTags' {
    It 'extracts tags and returns cleaned title' {
    Import-Module -Name (Join-Path $PSScriptRoot '..' 'TitleToTags.psm1') -Force
        $title = "Fix crash when loading [UI] [critical] - causes OOM"
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
}
