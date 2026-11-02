# Independent cancellation marker writer used by mid-run cancel cases.
# It only creates the marker file named by the test; it never deletes or cleans anything.
param(
    [Parameter(Mandatory = $true)][ValidateSet('PlanBytes', 'RemainingCount')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$WatchPath,
    [Parameter(Mandatory = $true)][string]$CancelPath,
    [int]$Threshold = 0,
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
$utf8 = New-Object Text.UTF8Encoding($false)
while ([datetime]::UtcNow -lt $deadline) {
    try {
        if ($Mode -eq 'PlanBytes') {
            $item = Get-Item -LiteralPath $WatchPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and -not $item.PSIsContainer -and [int64]$item.Length -ge [int64]$Threshold) {
                [IO.File]::WriteAllText($CancelPath, 'cancel', $utf8)
                exit 0
            }
        }
        else {
            $count = @(Get-ChildItem -LiteralPath $WatchPath -Filter '*.tmp' -File -Force -ErrorAction SilentlyContinue).Count
            if ($count -le $Threshold) {
                [IO.File]::WriteAllText($CancelPath, 'cancel', $utf8)
                exit 0
            }
        }
    }
    catch { }
    Start-Sleep -Milliseconds 5
}
exit 2
