#requires -Version 5.1
# N05: white-background multi-size application icon - exactly the 7 required sizes,
# every frame opaque, corner pixels pure white (#FFFFFF, alpha 255),主体完整且等比居中,
# 256 frame stored as PNG and smaller frames as 32bpp DIB with a zero AND mask, and the
# build embeds the same bytes so window/EXE resources cannot drift.
# This is a pixel/resource check, NOT a desktop visual acceptance.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
Add-Type -AssemblyName System.Drawing
try {
    $iconPath = Join-Path $RepoRoot 'assets\app.ico'
    $sourcePath = Join-Path $RepoRoot 'assets\app-icon-source.png'
    Assert-True 'assets/app.ico exists' ([IO.File]::Exists($iconPath)) $iconPath
    Assert-True 'icon source artwork exists' ([IO.File]::Exists($sourcePath)) $sourcePath
    if (-not [IO.File]::Exists($iconPath)) { throw 'icon missing' }

    $bytes = [IO.File]::ReadAllBytes($iconPath)
    Assert-True 'icon is a non-trivial file (> 8 KiB)' ($bytes.Length -gt 8192) ('bytes=' + $bytes.Length)
    Assert-Equal 'ICONDIR reserved field is zero' 0 ([int][BitConverter]::ToUInt16($bytes, 0))
    Assert-Equal 'ICONDIR type is 1 (icon)' 1 ([int][BitConverter]::ToUInt16($bytes, 2))
    $count = [int][BitConverter]::ToUInt16($bytes, 4)
    Assert-Equal 'icon declares exactly 7 frames' 7 $count ''
    if ($count -ne 7) { throw ('unexpected frame count ' + $count) }

    $entries = @()
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + $i * 16
        $width = [int]$bytes[$o]; if ($width -eq 0) { $width = 256 }
        $height = [int]$bytes[$o + 1]; if ($height -eq 0) { $height = 256 }
        $entries += [pscustomobject]@{
            Index = $i
            Width = $width
            Height = $height
            Bpp = [int][BitConverter]::ToUInt16($bytes, $o + 6)
            Size = [int64][BitConverter]::ToUInt32($bytes, $o + 8)
            Offset = [int64][BitConverter]::ToUInt32($bytes, $o + 12)
        }
    }
    [void](Save-Evidence 'icon-entries' $entries)

    $requiredSizes = @(16, 24, 32, 48, 64, 128, 256)
    Assert-Equal 'icon sizes are exactly 16/24/32/48/64/128/256' ($requiredSizes -join ',') ((@($entries | ForEach-Object { $_.Width }) | Sort-Object) -join ',') ''
    Assert-Equal 'every icon frame is square' 0 (@($entries | Where-Object { $_.Width -ne $_.Height }).Count) (($entries | ForEach-Object { $_.Width.ToString() + 'x' + $_.Height.ToString() }) -join ',')
    Assert-Equal 'frame count equals directory count' 7 $entries.Count ''
    Assert-Equal 'every frame uses 32 bits per pixel' 0 (@($entries | Where-Object { $_.Bpp -ne 32 }).Count) (($entries | ForEach-Object { $_.Width.ToString() + ':' + $_.Bpp }) -join ',')
    $overlaps = @()
    for ($a = 0; $a -lt $entries.Count; $a++) {
        for ($b = $a + 1; $b -lt $entries.Count; $b++) {
            $ea = $entries[$a]; $eb = $entries[$b]
            if ($ea.Offset -lt ($eb.Offset + $eb.Size) -and $eb.Offset -lt ($ea.Offset + $ea.Size)) { $overlaps += ($ea.Width.ToString() + '/' + $eb.Width.ToString()) }
        }
    }
    Assert-Equal 'frame data ranges do not overlap' 0 $overlaps.Count ($overlaps -join ',')
    $outOfRange = @($entries | Where-Object { $_.Offset -lt 6 -or ($_.Offset + $_.Size) -gt $bytes.Length -or $_.Size -le 0 })
    Assert-Equal 'every frame lies inside the file' 0 $outOfRange.Count (($outOfRange | ForEach-Object { $_.Width }) -join ',')

    $sourceInfo = $null
    if ([IO.File]::Exists($sourcePath)) {
        $sourceBitmap = [Drawing.Bitmap]::FromFile($sourcePath)
        try {
            # Opaque subject bounding box in the source artwork.
            $minX = $sourceBitmap.Width; $minY = $sourceBitmap.Height; $maxX = -1; $maxY = -1; $subject = 0
            for ($y = 0; $y -lt $sourceBitmap.Height; $y++) {
                for ($x = 0; $x -lt $sourceBitmap.Width; $x++) {
                    if ($sourceBitmap.GetPixel($x, $y).A -gt 32) {
                        $subject++
                        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
                    }
                }
            }
            $sourceInfo = [pscustomobject]@{ Width = $sourceBitmap.Width; Height = $sourceBitmap.Height; Subject = $subject; MinX = $minX; MinY = $minY; MaxX = $maxX; MaxY = $maxY }
            Assert-True 'source artwork is at least 128px for a 256px frame' ($sourceBitmap.Width -ge 128) ([string]$sourceBitmap.Width)
            Assert-True 'source artwork has a real opaque subject' ($subject -gt 1000) ([string]$subject)
            Assert-True 'source artwork has transparent margins (needs white composition)' (($minX -gt 0) -or ($minY -gt 0) -or ($maxX -lt ($sourceBitmap.Width - 1)) -or ($maxY -lt ($sourceBitmap.Height - 1))) ([string]$minX + ',' + [string]$minY + '-' + [string]$maxX + ',' + [string]$maxY)
        }
        finally { $sourceBitmap.Dispose() }
    }
    [void](Save-Evidence 'icon-source' $sourceInfo)

    $white = [Drawing.Color]::FromArgb(255, 255, 255, 255)
    $frameReports = New-Object 'System.Collections.Generic.List[object]'
    $cornerFailures = New-Object 'System.Collections.Generic.List[string]'
    $alphaFailures = New-Object 'System.Collections.Generic.List[string]'
    $subjectFailures = New-Object 'System.Collections.Generic.List[string]'
    $formatFailures = New-Object 'System.Collections.Generic.List[string]'
    $centeringFailures = New-Object 'System.Collections.Generic.List[string]'

    foreach ($entry in $entries) {
        $size = $entry.Width
        # Indexing a byte[] with a range yields Object[]; the MemoryStream/Bitmap
        # constructors need a real byte[]. Copy explicitly instead of casting the range.
        $frame = New-Object byte[] $entry.Size
        [Array]::Copy($bytes, [int]$entry.Offset, $frame, 0, [int]$entry.Size)
        $isPng = ($frame.Length -ge 8 -and $frame[0] -eq 0x89 -and $frame[1] -eq 0x50 -and $frame[2] -eq 0x4E -and $frame[3] -eq 0x47)
        if ($size -ge 256) {
            if (-not $isPng) { $formatFailures.Add($size.ToString() + ':expected-png') }
        }
        else {
            if ($isPng) { $formatFailures.Add($size.ToString() + ':unexpected-png') }
            $headerSize = [int][BitConverter]::ToUInt32($frame, 0)
            $biWidth = [int][BitConverter]::ToInt32($frame, 4)
            $biHeight = [int][BitConverter]::ToInt32($frame, 8)
            $planes = [int][BitConverter]::ToUInt16($frame, 12)
            $bitCount = [int][BitConverter]::ToUInt16($frame, 14)
            if ($headerSize -ne 40 -or $biWidth -ne $size -or $biHeight -ne (2 * $size) -or $planes -ne 1 -or $bitCount -ne 32) { $formatFailures.Add($size.ToString() + ':dib-header') }
            $maskStride = [int]([math]::Ceiling($size / 32.0) * 4)
            $pixelBytes = $size * $size * 4
            if ($frame.Length -ne (40 + $pixelBytes + $maskStride * $size)) { $formatFailures.Add($size.ToString() + ':length') }
            else {
                $maskOffset = 40 + $pixelBytes
                $maskNonZero = 0
                for ($m = $maskOffset; $m -lt $frame.Length; $m++) { if ($frame[$m] -ne 0) { $maskNonZero++; break } }
                if ($maskNonZero -gt 0) { $formatFailures.Add($size.ToString() + ':and-mask-not-zero') }
            }
        }

        # DIB frames inside an ICO are header+pixels+mask, not standalone image files, so
        # decode them manually as bottom-up BGRA. PNG (256) frames decode with GDI+.
        $step = [math]::Max(1, [int][math]::Floor($size / 128))
        $minX = $size; $minY = $size; $maxX = -1; $maxY = -1
        $bitmap = $null; $stream = $null
        try {
            if ($isPng) {
                $stream = [IO.MemoryStream]::new($frame, $false)
                $bitmap = [Drawing.Bitmap]::new($stream)
                if ($bitmap.Width -ne $size -or $bitmap.Height -ne $size) { $formatFailures.Add($size.ToString() + ':decoded-size') }
                $cornerPixels = @(
                    $bitmap.GetPixel(0, 0), $bitmap.GetPixel($size - 1, 0),
                    $bitmap.GetPixel(0, $size - 1), $bitmap.GetPixel($size - 1, $size - 1)
                )
            }
            else {
                # 1-based byte helpers; row 0 in the file is the BOTTOM image row.
                $cornerPixels = @()
                $last = $size - 1
                $cornerPoints = @([pscustomobject]@{ X = 0; Y = 0 }, [pscustomobject]@{ X = $last; Y = 0 }, [pscustomobject]@{ X = 0; Y = $last }, [pscustomobject]@{ X = $last; Y = $last })
                $cornerPixels = @()
                foreach ($point in $cornerPoints) {
                    $x = [int]$point.X; $y = [int]$point.Y; $fileRow = $last - $y
                    $base = 40 + $fileRow * ($size * 4) + $x * 4
                    $cornerPixels += [Drawing.Color]::FromArgb([int]$frame[$base + 3], [int]$frame[$base + 2], [int]$frame[$base + 1], [int]$frame[$base])
                }
            }
            foreach ($corner in $cornerPixels) {
                if ($corner.A -ne 255 -or $corner.R -ne 255 -or $corner.G -ne 255 -or $corner.B -ne 255) {
                    $cornerFailures.Add($size.ToString() + ':' + $corner.A + ',' + $corner.R + ',' + $corner.G + ',' + $corner.B)
                    break
                }
            }
            for ($y = 0; $y -lt $size; $y += $step) {
                for ($x = 0; $x -lt $size; $x += $step) {
                    if ($isPng) {
                        $pixel = $bitmap.GetPixel($x, $y)
                        $alpha = [int]$pixel.A; $red = [int]$pixel.R; $green = [int]$pixel.G; $blue = [int]$pixel.B
                    }
                    else {
                        $fileRow = $size - 1 - $y; $base = 40 + $fileRow * ($size * 4) + $x * 4
                        $blue = [int]$frame[$base]; $green = [int]$frame[$base + 1]; $red = [int]$frame[$base + 2]; $alpha = [int]$frame[$base + 3]
                    }
                    if ($alpha -ne 255) { $alphaFailures.Add($size.ToString() + ':' + $x + ',' + $y + '=' + $alpha); $y = $size; break }
                    if ($red -ne 255 -or $green -ne 255 -or $blue -ne 255) {
                        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
                    }
                }
            }
            $subjectPixels = 0
            if ($maxX -ge 0) { $subjectPixels = ($maxX - $minX + $step) * ($maxY - $minY + $step) }
            if ($maxX -lt 0) { $subjectFailures.Add($size.ToString() + ':no-subject') }
            else {
                $marginLeft = $minX; $marginRight = $size - 1 - $maxX
                $marginTop = $minY; $marginBottom = $size - 1 - $maxY
                $tolerance = [math]::Max(2, [int][math]::Ceiling($size * 0.08))
                if ([math]::Abs($marginLeft - $marginRight) -gt $tolerance -or [math]::Abs($marginTop - $marginBottom) -gt $tolerance) {
                    $centeringFailures.Add($size.ToString() + ':margins=' + $marginLeft + ',' + $marginTop + ',' + $marginRight + ',' + $marginBottom)
                }
                if ($size -ge 48 -and $subjectPixels -lt ($size * $size * 0.10)) { $subjectFailures.Add($size.ToString() + ':subject-too-small') }
            }
            [void]$frameReports.Add([pscustomobject]@{
                Size = $size; Format = $(if ($isPng) { 'PNG' } else { 'DIB32' }); Bytes = $entry.Size
                SubjectBounds = ('' + $minX + ',' + $minY + '-' + $maxX + ',' + $maxY)
                Margins = ('' + $minX + '/' + $minY + '/' + ($size - 1 - $maxX) + '/' + ($size - 1 - $maxY))
            })
        }
        finally {
            if ($bitmap) { $bitmap.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }

    Assert-Equal 'every frame has opaque pixels only (alpha 255)' 0 $alphaFailures.Count (($alphaFailures | Select-Object -First 6) -join '; ')
    Assert-Equal 'every frame has pure white (#FFFFFF) corner pixels' 0 $cornerFailures.Count (($cornerFailures | Select-Object -First 6) -join '; ')
    Assert-Equal 'every frame carries a non-empty subject with sane proportions' 0 $subjectFailures.Count (($subjectFailures | Select-Object -First 6) -join '; ')
    Assert-Equal 'every frame uses the required PNG/DIB32 container layout' 0 $formatFailures.Count (($formatFailures | Select-Object -First 6) -join '; ')
    Assert-Equal 'subject is visually centred within tolerance on every frame' 0 $centeringFailures.Count (($centeringFailures | Select-Object -First 6) -join '; ')
    [void](Save-Evidence 'icon-frames' $frameReports.ToArray())

    # The build must embed exactly these icon bytes so the window/EXE icon cannot drift.
    $buildText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\build.ps1'))
    Assert-True 'build.ps1 embeds the icon as SjcEmbeddedIconBase64' ($buildText -match 'SjcEmbeddedIconBase64') ''
    Assert-True 'build.ps1 records assets\app.ico in Sources' ($buildText -match "assets\\app\.ico") ''
    Assert-True 'build.ps1 records its own script in Sources' ($buildText -match "scripts\\build\.ps1") ''
    Assert-True 'build.ps1 passes the icon to ps2exe' ($buildText -match '-iconFile\s+\$icon') ''

    # Reading the icon through the GUI loader must yield the same largest frame when the
    # GUI module is loaded by a Release run. In a Core run Gui.ps1 is intentionally not
    # loaded, so this is a limitation (never a coverage gap) and G01/G03/X01 cover it.
    if ($script:GuiModuleLoaded) {
        $appIcon = Get-SjcGuiAppIcon
        Assert-True 'GUI icon loader resolves the same icon file' ((-not [string]::IsNullOrWhiteSpace([string]$appIcon.Source)) -and ([IO.Path]::GetFullPath([string]$appIcon.Source) -eq [IO.Path]::GetFullPath($iconPath))) ([string]$appIcon.Source)
        Add-Limitation 'GUI 图标加载仅验证资源解析；实际窗口外观仍需桌面观察。'
    }
    else {
        Add-Limitation '本次运行未加载 Gui.ps1（Scope=Core）：窗口图标资源解析由 Release 的 G01/G03/X01 覆盖，此处不计为缺口。'
    }

    # Regression guard: verify the icon is not the old single 64px geometric asset.
    Assert-True 'icon is no longer the legacy single-size 64px asset' (-not ($bytes.Length -eq 1431 -and $count -eq 1)) ('bytes=' + $bytes.Length + '; frames=' + $count)
    Add-Limitation '像素/资源检查证明白底与尺寸合规，不构成桌面实际观察或视觉美观验收。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
