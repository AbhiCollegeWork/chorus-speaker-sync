<#
.SYNOPSIS
  Clear Word's "disabled items" blacklist so it will open a file again.

.DESCRIPTION
  When Word hangs or is force-closed while opening a document, it records that
  file's path in the registry under

      HKCU\Software\Microsoft\Office\<ver>\Word\Resiliency\DisabledItems

  From then on Word refuses or hangs on that exact path, no matter how healthy
  the file is. The giveaway is that a byte-identical copy under a different
  filename opens instantly.

  This is self-reinforcing: the hang leads to a force-close, which adds another
  blacklist entry, which causes the next hang.

  This script removes the entries matching a pattern, leaving unrelated entries
  (add-ins, other documents) alone.

.EXAMPLE
  .\unblock-word-files.ps1 -Match chorus

.EXAMPLE
  .\unblock-word-files.ps1 -List
#>
[CmdletBinding()]
param(
    [string]$Match = "chorus",
    [switch]$List,
    [switch]$All
)

$roots = Get-ChildItem "HKCU:\Software\Microsoft\Office" -ErrorAction SilentlyContinue |
         Where-Object { $_.PSChildName -match '^\d+\.\d+$' }

if (-not $roots) { Write-Host "No Office installation found in the registry." -ForegroundColor Yellow; return }

$found = 0
$removed = 0

foreach ($r in $roots) {
    $ver = $r.PSChildName
    $key = "HKCU:\Software\Microsoft\Office\$ver\Word\Resiliency\DisabledItems"
    if (-not (Test-Path $key)) { continue }

    Write-Host "Office $ver" -ForegroundColor Cyan
    $item = Get-Item $key

    foreach ($name in $item.GetValueNames()) {
        $raw = $item.GetValue($name)
        $text = if ($raw -is [byte[]]) {
            ([System.Text.Encoding]::Unicode.GetString($raw) -replace '[^\x20-\x7E]', ' ').Trim()
        } else { "$raw" }

        $found++
        $isMatch = $All -or ($text -match [regex]::Escape($Match))

        if ($List) {
            $flag = if ($isMatch) { "*" } else { " " }
            Write-Host "  $flag $text"
            continue
        }

        if ($isMatch) {
            Remove-ItemProperty -Path $key -Name $name -Force
            Write-Host "  removed: $text" -ForegroundColor Green
            $removed++
        } else {
            Write-Host "  kept   : $text" -ForegroundColor DarkGray
        }
    }
}

if ($List) {
    Write-Host "`n$found entries listed (* = would be removed with -Match '$Match')."
} else {
    Write-Host "`nRemoved $removed of $found entries." -ForegroundColor Cyan
    if ($removed -gt 0) {
        Write-Host "Close Word completely before reopening the files." -ForegroundColor Yellow
    }
}
