<#
.SYNOPSIS
  Shared title pattern definitions used by create_testdata.ps1 and e2e_test.ps1

This file defines a single variable, $titlePatterns, which is an array of PSCustomObject
entries. Each entry contains: Title, ExpectedTags, and ExpectedTitle. Dot-source this file
from caller scripts so $titlePatterns is available in their scope.
#>

Set-StrictMode -Version Latest

function Get-TestDataPatterns {
    <#
    .SYNOPSIS
      Returns the array of test patterns (Title, ExpectedTags, ExpectedTitle)
    #>
    return @(
        # 0. No bracketed substrings at all
        [PSCustomObject]@{
            Title = 'No bracketed substrings in this title'
            ExpectedTags = @()
            ExpectedTitle = 'No bracketed substrings in this title'
        },
        # 1. Single bracketed substring at the start
        [PSCustomObject]@{
            Title = '[Single] bracketed substring at start of title'
            ExpectedTags = @('Single')
            ExpectedTitle = 'Bracketed substring at start of title'
        },
        # 2. Single bracketed substring at the end
        [PSCustomObject]@{
            Title = 'Title with bracketed substring at end [End]'
            ExpectedTags = @('End')
            ExpectedTitle = 'Title with bracketed substring at end'
        },
        # 3. Two bracketed substrings separated by text
        [PSCustomObject]@{
            Title = 'Title with two bracketed substrings [One] [Two] at end'
            ExpectedTags = @('One', 'Two')
            ExpectedTitle = 'Title with two bracketed substrings at end'
        },
        # 4. Only bracketed substrings; no other words
        [PSCustomObject]@{
            Title = '[All][Brackets][Only]'
            ExpectedTags = @('All', 'Brackets', 'Only')
            ExpectedTitle = 'Untitled Work Item'
        },
        # 5. Bracket at the start and another later in the title
        [PSCustomObject]@{
            Title = '[First] Title begins with bracketed substring and also has [Second]'
            ExpectedTags = @('First', 'Second')
            ExpectedTitle = 'Title begins with bracketed substring and also has'
        },
        # 6. Two adjacent bracketed substrings at the start with no separator
        [PSCustomObject]@{
            Title = '[First][Second]Title begins with adjacent bracketed substrings'
            ExpectedTags = @('First', 'Second')
            ExpectedTitle = 'Title begins with adjacent bracketed substrings'
        },
        # 7. Title with a single bracketed substring at the beginning but the following text is lowercase
        [PSCustomObject]@{
            Title = '[start] title begins with lowercase text'
            ExpectedTags = @('start')
            ExpectedTitle = 'Title begins with lowercase text'
        },
        # 8. Title with nested brackets (should be treated as literal)
        [PSCustomObject]@{
            Title = '[Outer [Inner]] Title with nested brackets'
            ExpectedTags = @('Outer', 'Inner')
            ExpectedTitle = 'Title with nested brackets'
        },
        # 9. Title with empty brackets (should be ignored)
        [PSCustomObject]@{
            Title = 'Title with empty brackets [] should ignore them'
            ExpectedTags = @()
            ExpectedTitle = 'Title with empty brackets [] should ignore them'
        },
        # 10. Title with brackets but no content (should be ignored)
        [PSCustomObject]@{
            Title = 'Title with empty brackets [ ] should ignore them'
            ExpectedTags = @()
            ExpectedTitle = 'Title with empty brackets [ ] should ignore them'
        },
        # 11. Title with multiple spaces between words and brackets
        [PSCustomObject]@{
            Title = 'Title   with    multiple   spaces  [Tag]  should   normalize'
            ExpectedTags = @('Tag')
            ExpectedTitle = 'Title with multiple spaces should normalize'
        }
    )
}
