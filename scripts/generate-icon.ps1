#requires -Version 5.1
# 由 assets\app-icon-source.png（旧版 v2.2.1 内嵌的原创立绘，权利人声明本人原创或拥有分发权）
# 重建多尺寸应用图标：主体等比完整缩放居中，透明区域合成 #FFFFFF 方形背景。
# 16-128 写入 32bpp BMP 帧，256 写入 PNG 帧。不读取网络、不引入第三方图片或字体。
[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$OutputPath,
    [switch]$Force,
    [string]$PreviewDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $PSScriptRoot
if(-not $SourcePath){$SourcePath=Join-Path $root 'assets\app-icon-source.png'}
if(-not $OutputPath){$OutputPath=Join-Path $root 'assets\app.ico'}
if(-not [IO.File]::Exists($SourcePath)){throw ('找不到原图素材：'+$SourcePath)}
if([IO.File]::Exists($OutputPath) -and -not $Force){throw '目标图标已存在；确认需要替换时使用 -Force。'}
$sizes=@(16,24,32,48,64,128,256)
$source=[Drawing.Bitmap]::FromFile($SourcePath)
$frames=New-Object 'System.Collections.Generic.List[object]'
try{
    foreach($size in $sizes){
        $bitmap=[Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try{
            $graphics.Clear([Drawing.Color]::FromArgb(255,255,255,255))
            $graphics.CompositingMode='SourceOver';$graphics.CompositingQuality='HighQuality'
            $graphics.InterpolationMode='HighQualityBicubic';$graphics.PixelOffsetMode='HighQuality';$graphics.SmoothingMode='HighQuality'
            # 等比完整：按较长边适配目标方形，不裁切主体。
            $scale=[math]::Min($size/$source.Width,$size/$source.Height)
            $w=[math]::Max(1,[int][math]::Round($source.Width*$scale));$h=[math]::Max(1,[int][math]::Round($source.Height*$scale))
            $x=[int][math]::Floor(($size-$w)/2);$y=[int][math]::Floor(($size-$h)/2)
            $attributes=[Drawing.Imaging.ImageAttributes]::new()
            try{
                $attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
                $graphics.DrawImage($source,[Drawing.Rectangle]::new($x,$y,$w,$h),0,0,$source.Width,$source.Height,[Drawing.GraphicsUnit]::Pixel,$attributes)
            }finally{$attributes.Dispose()}
        }finally{$graphics.Dispose()}
        if($PreviewDirectory){
            [void][IO.Directory]::CreateDirectory($PreviewDirectory)
            $bitmap.Save((Join-Path $PreviewDirectory ('icon-{0}.png' -f $size)),[Drawing.Imaging.ImageFormat]::Png)
        }
        if($size -ge 256){
            $memory=[IO.MemoryStream]::new()
            try{$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$data=$memory.ToArray()}finally{$memory.Dispose()}
        }else{
            # BITMAPINFOHEADER + 自下而上 BGRA 像素 + 全零 AND 掩码（白底不透明）。
            $rect=[Drawing.Rectangle]::new(0,0,$size,$size)
            $locked=$bitmap.LockBits($rect,[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try{$stride=$locked.Stride;$pixels=New-Object byte[] ($stride*$size);[Runtime.InteropServices.Marshal]::Copy($locked.Scan0,$pixels,0,$pixels.Length)}finally{$bitmap.UnlockBits($locked)}
            $maskStride=[int]([math]::Ceiling($size/32.0)*4)
            $memory=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($memory)
            try{
                $writer.Write([uint32]40);$writer.Write([int32]$size);$writer.Write([int32]($size*2));$writer.Write([uint16]1);$writer.Write([uint16]32)
                $writer.Write([uint32]0);$writer.Write([uint32]($size*$size*4+$maskStride*$size));$writer.Write([int32]0);$writer.Write([int32]0);$writer.Write([uint32]0);$writer.Write([uint32]0)
                for($row=$size-1;$row -ge 0;$row--){$writer.Write($pixels,$row*$stride,$size*4)}
                $writer.Write((New-Object byte[] ($maskStride*$size)))
                $writer.Flush();$data=$memory.ToArray()
            }finally{$writer.Dispose()}
        }
        $bitmap.Dispose()
        [void]$frames.Add([pscustomobject]@{Size=$size;Data=$data})
    }
}finally{$source.Dispose()}
$temporary=$OutputPath+'.'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.tmp'
$stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
$writer=[IO.BinaryWriter]::new($stream)
try{
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$frames.Count)
    [uint32]$offset=6+16*$frames.Count
    foreach($frame in $frames){
        $dimension=if($frame.Size -ge 256){0}else{$frame.Size}
        $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frame.Data.Length);$writer.Write([uint32]$offset)
        $offset+=[uint32]$frame.Data.Length
    }
    foreach($frame in $frames){$writer.Write($frame.Data)}
}finally{$writer.Dispose()}
try{[IO.File]::Copy($temporary,$OutputPath,$true)}finally{[IO.File]::Delete($temporary)}
[pscustomobject]@{Output=$OutputPath;Sizes=$sizes;Bytes=([IO.FileInfo]$OutputPath).Length;SHA256=(Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash}
