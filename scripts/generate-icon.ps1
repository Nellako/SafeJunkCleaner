#requires -Version 5.1
# Original geometric artwork. No third-party images or fonts are embedded.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $PSScriptRoot
$directory=Join-Path $root 'assets'
[void][IO.Directory]::CreateDirectory($directory)
$target=Join-Path $directory 'app.ico'
if([IO.File]::Exists($target)){throw 'Icon already exists; inspect it before choosing to replace it.'}
$bitmap=[Drawing.Bitmap]::new(64,64)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$memory=[IO.MemoryStream]::new()
try{
    $graphics.SmoothingMode='AntiAlias';$graphics.Clear([Drawing.Color]::Transparent)
    $blue=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(47,107,255));$white=[Drawing.SolidBrush]::new([Drawing.Color]::White)
    $pen=[Drawing.Pen]::new([Drawing.Color]::White,4)
    try{
        $graphics.FillEllipse($blue,2,2,60,60)
        $points=[Drawing.Point[]]@([Drawing.Point]::new(32,10),[Drawing.Point]::new(36,25),[Drawing.Point]::new(51,29),[Drawing.Point]::new(36,33),[Drawing.Point]::new(32,48),[Drawing.Point]::new(28,33),[Drawing.Point]::new(13,29),[Drawing.Point]::new(28,25))
        $graphics.FillPolygon($white,$points);$graphics.DrawLines($pen,[Drawing.Point[]]@([Drawing.Point]::new(41,45),[Drawing.Point]::new(46,50),[Drawing.Point]::new(55,39)))
    }finally{$blue.Dispose();$white.Dispose();$pen.Dispose()}
    $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$png=$memory.ToArray()
    $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $writer=[IO.BinaryWriter]::new($stream)
    try{
        $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]1)
        $writer.Write([byte]64);$writer.Write([byte]64);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$png.Length);$writer.Write([uint32]22);$writer.Write($png)
    }finally{$writer.Dispose()}
}finally{$graphics.Dispose();$bitmap.Dispose();$memory.Dispose()}
Write-Output ('Created original geometric icon: '+$target)
