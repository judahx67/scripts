 <#
.SYNOPSIS
  Crop an image to the X3 (528x792) or X4 (480x800) wallpaper spec: uncompressed 24-bit BMP, grayscale-ready.
.DESCRIPTION
  Opens a window showing the image already in grayscale (what the device will actually show).
  Drag inside the box to move the crop, drag its bottom-right grip to resize (the panel aspect stays locked).
  Bright/Contrast sliders and the Invert box update the preview live.
  Save writes <name>_x3.bmp / _x4.bmp next to the source.
.EXAMPLE
  .\XCrop.ps1 photo.jpg
.EXAMPLE
  .\XCrop.ps1 photo.jpg -Device X4 -Invert
.EXAMPLE
  .\XCrop.ps1              # prompts for a file
.EXAMPLE
  .\XCrop.ps1 -SelfCheck   # headless: drives the real handlers for every device, checks the BMP header
#>
param([string]$Path, [ValidateSet('X3', 'X4')][string]$Device = 'X3',
      [double]$Gamma = 1.0, [double]$Contrast = 1.0, [switch]$Invert, [switch]$SelfCheck)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$ErrorActionPreference = 'Stop'
$panels = @{ X3 = 528, 792; X4 = 480, 800 }   # panel resolutions; the crop aspect falls out of these
$W, $H = $panels[$Device]

if ($SelfCheck -and -not $PSBoundParameters.ContainsKey('Device')) {   # no device named: check them all
    foreach ($d in $panels.Keys) { & $PSCommandPath @PSBoundParameters -Device $d }
    exit 0
}

function Get-Attrs([double]$gamma, [double]$contrast, [bool]$invert) {
    # out = lum * c + o; inverted is the same line mirrored: out = -lum * c + (1 - o)
    $c = $contrast; $o = (1 - $c) / 2
    if ($invert) { $c = -$c; $o = 1 - $o }
    $m = New-Object Drawing.Imaging.ColorMatrix   # luminance weights into every channel: gray before it is resized
    $m.Matrix00 = 0.299*$c; $m.Matrix01 = 0.299*$c; $m.Matrix02 = 0.299*$c
    $m.Matrix10 = 0.587*$c; $m.Matrix11 = 0.587*$c; $m.Matrix12 = 0.587*$c
    $m.Matrix20 = 0.114*$c; $m.Matrix21 = 0.114*$c; $m.Matrix22 = 0.114*$c
    $m.Matrix40 = $o; $m.Matrix41 = $o; $m.Matrix42 = $o
    $a = New-Object Drawing.Imaging.ImageAttributes
    $a.SetColorMatrix($m)
    $a.SetGamma([single](1 / $gamma))   # GDI+ gamma darkens as it rises; invert so >1 = brighter
    $a.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)   # kills the edge halo when scaling
    $a
}

function Render($img, [Drawing.Rectangle]$src, [int]$w, [int]$h, [double]$gamma, [double]$contrast, [bool]$invert) {
    $bmp = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::White)   # a 24bpp bitmap starts black; transparent source areas read as paper, not ink
    $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $a = Get-Attrs $gamma $contrast $invert
    $g.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, $w, $h),
                 $src.X, $src.Y, $src.Width, $src.Height, [Drawing.GraphicsUnit]::Pixel, $a)
    $g.Dispose(); $a.Dispose()
    $bmp
}

function Open-Image([string]$p) {
    # stream, not FromFile: FromFile keeps the source locked for the life of the window
    $img = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($p))))
    if ($img.PropertyIdList -contains 274) {
        $rf = @{2='RotateNoneFlipX'; 3='Rotate180FlipNone'; 4='RotateNoneFlipY'; 5='Rotate90FlipX'
                6='Rotate90FlipNone'; 7='Rotate270FlipX'; 8='Rotate270FlipNone'}[[int]$img.GetPropertyItem(274).Value[0]]
        if ($rf) { $img.RotateFlip($rf) }
    }
    $img
}

if ($SelfCheck -and -not $Path) {   # synthetic source so the check runs unattended
    $src = New-Object Drawing.Bitmap 1400, 1584, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [Drawing.Graphics]::FromImage($src)
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.Point 0, 0),
          (New-Object Drawing.Point 1400, 1584), ([Drawing.Color]::Black), ([Drawing.Color]::White)
    $g.FillRectangle($br, 0, 0, 1400, 1584); $g.Dispose()
    $Path = Join-Path $env:TEMP 'xcrop-selfcheck.png'
    $src.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $src.Dispose()
}

if (-not $Path) {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff|All files|*.*'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $Path = $dlg.FileName
}
$Path = (Resolve-Path $Path).Path
$img = Open-Image $Path

# fit the whole image on screen; crop box starts as the largest panel-aspect rect that fits.
# [double] casts are load-bearing: an evenly-dividing ratio comes back Int32 and [Math]::Min
# then picks its int overload, truncating the other ratio to 0.
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$scale = [Math]::Min([double]($area.Width - 120) / $img.Width, [double]($area.Height - 240) / $img.Height)
if ($scale -gt 1) { $scale = 1.0 }
$dw = [int]($img.Width * $scale); $dh = [int]($img.Height * $scale)
if ($dw -lt 1 -or $dh -lt 1) { throw "cannot fit a $($img.Width)x$($img.Height) image on a $($area.Width)x$($area.Height) desktop" }

# floor, not [int]: rounding up puts the derived height a pixel past the image edge
$sw = [int][Math]::Min([double]$img.Width, [Math]::Floor([double]$img.Height * $W / $H))
$sh = [int][Math]::Floor([double]$sw * $H / $W)
$script:sel = New-Object Drawing.Rectangle ([int](($img.Width - $sw) / 2)), ([int](($img.Height - $sh) / 2)), $sw, $sh

$form = New-Object Windows.Forms.Form -Property @{
    Text = "$Device crop ${W}x${H} - $([IO.Path]::GetFileName($Path))"
    FormBorderStyle = 'FixedSingle'; MaximizeBox = $false; StartPosition = 'CenterScreen'
    AutoScaleMode = 'None'   # 1:1 pixels: the crop overlay is drawn in image coordinates, DPI scaling desyncs it
}
$pb = New-Object Windows.Forms.PictureBox -Property @{ Dock = 'Fill'; Cursor = 'SizeAll' }
# one autosizing row: hand-placed controls get clipped once the system font scales them
$bar = New-Object Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Bottom'; AutoSize = $true
    AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; Padding = New-Object Windows.Forms.Padding 6 }
$mid = New-Object Windows.Forms.Padding 4, 10, 4, 0   # drops labels onto the slider centreline
$sliderWidth = [Math]::Max(110, [int](($dw - 340) / 2))

$lg = New-Object Windows.Forms.Label -Property @{ Text = 'Bright'; AutoSize = $true; Margin = $mid }
$gs = New-Object Windows.Forms.TrackBar -Property @{ Minimum = 50; Maximum = 250; TickFrequency = 50
    Size = New-Object Drawing.Size $sliderWidth, 32 }
$lc = New-Object Windows.Forms.Label -Property @{ Text = 'Contrast'; AutoSize = $true; Margin = $mid }
$cs = New-Object Windows.Forms.TrackBar -Property @{ Minimum = 50; Maximum = 250; TickFrequency = 50
    Size = New-Object Drawing.Size $sliderWidth, 32 }
# after the range, not inside the hashtable: -Property applies keys in arbitrary order
$gs.Value = [Math]::Clamp([int]($Gamma * 100), 50, 250)
$cs.Value = [Math]::Clamp([int]($Contrast * 100), 50, 250)
$inv = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Invert'; AutoSize = $true
    Checked = [bool]$Invert; Margin = New-Object Windows.Forms.Padding 12, 10, 4, 0 }
$dev = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'
    Width = 70; Margin = New-Object Windows.Forms.Padding 12, 5, 4, 0 }
$dev.Items.AddRange(@($panels.Keys | Sort-Object))
$dev.SelectedItem = $Device
$save = New-Object Windows.Forms.Button -Property @{ Text = 'Save BMP'; AutoSize = $true
    Margin = New-Object Windows.Forms.Padding 4, 4, 4, 0 }
$status = New-Object Windows.Forms.Label -Property @{ AutoSize = $true; ForeColor = 'DimGray'; Margin = $mid }
$bar.Controls.AddRange(@($lg, $gs, $lc, $cs, $inv, $dev, $save, $status))
$form.Controls.Add($pb); $form.Controls.Add($bar)   # fill first, bottom second: docking runs last-to-first
# measure the bar at the window's width so a wrapped second row is included in the height
$form.ClientSize = New-Object Drawing.Size $dw, ($dh + $bar.GetPreferredSize((New-Object Drawing.Size $dw, 0)).Height)
$form.AcceptButton = $save
(New-Object Windows.Forms.ToolTip).SetToolTip($pb, 'drag the box to move it, drag the corner grip to resize')

# Stage one, done once: the whole source reduced to display size, neutral gray. Every slider tick
# then re-tones this small copy instead of resampling the original, which on a 24MP photo is the
# difference between instant and a second per tick. Re-applying the luminance matrix to gray is a
# no-op (the weights sum to 1), so the two stages compose exactly.
$script:flat = Render $img (New-Object Drawing.Rectangle 0, 0, $img.Width, $img.Height) $dw $dh 1.0 1.0 $false
$flatRect = New-Object Drawing.Rectangle 0, 0, $dw, $dh

function Update-Preview {
    $old = $pb.Image
    $pb.Image = Render $script:flat $flatRect $dw $dh ($gs.Value / 100) ($cs.Value / 100) $inv.Checked
    if ($old) { $old.Dispose() }
}
$gs.Add_ValueChanged({ Update-Preview }); $cs.Add_ValueChanged({ Update-Preview })
$inv.Add_CheckedChanged({ Update-Preview })
Update-Preview

# handlers take param($s, $e): inside an Add_* block $_ is the (sender, args) pair, not the event args.
# They are named so -SelfCheck can fire them without a desktop.
$onPaint = {
    param($s, $e)
    $r = New-Object Drawing.Rectangle ([int]($script:sel.X * $scale)), ([int]($script:sel.Y * $scale)),
         ([int]($script:sel.Width * $scale)), ([int]($script:sel.Height * $scale))
    $dim = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(150, 0, 0, 0))
    $e.Graphics.FillRectangle($dim, 0, 0, $dw, $r.Top)
    $e.Graphics.FillRectangle($dim, 0, $r.Bottom, $dw, $dh - $r.Bottom)
    $e.Graphics.FillRectangle($dim, 0, $r.Top, $r.Left, $r.Height)
    $e.Graphics.FillRectangle($dim, $r.Right, $r.Top, $dw - $r.Right, $r.Height)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 2
    $e.Graphics.DrawRectangle($pen, $r)
    $e.Graphics.FillRectangle([Drawing.Brushes]::White, $r.Right - 11, $r.Bottom - 11, 11, 11)  # resize grip
    $dim.Dispose(); $pen.Dispose()
}

# drag inside = move, drag the grip = resize; aspect stays locked to 528:792
$script:mode = $null
$script:grab = @(0, 0)
$onDown = {
    param($s, $e)
    $x = $e.X / $scale; $y = $e.Y / $scale; $grip = 18 / $scale
    if ([Math]::Abs($x - $script:sel.Right) -lt $grip -and [Math]::Abs($y - $script:sel.Bottom) -lt $grip) {
        $script:mode = 'size'
    } elseif ($script:sel.Contains([int]$x, [int]$y)) {
        # parens are load-bearing: comma binds tighter than minus, so @(a - b, c - d) is not two subtractions
        $script:mode = 'move'; $script:grab = @(($x - $script:sel.X), ($y - $script:sel.Y))
    }
}
$onUp = { $script:mode = $null }
$onMove = {
    param($s, $e)
    if (-not $script:mode) { return }
    $x = $e.X / $scale; $y = $e.Y / $scale
    if ($script:mode -eq 'move') {
        $nx = [Math]::Max(0.0, [Math]::Min([double]($img.Width  - $script:sel.Width),  $x - $script:grab[0]))
        $ny = [Math]::Max(0.0, [Math]::Min([double]($img.Height - $script:sel.Height), $y - $script:grab[1]))
        $script:sel = New-Object Drawing.Rectangle ([int]$nx), ([int]$ny), $script:sel.Width, $script:sel.Height
    } else {
        $nw = [Math]::Max(100.0, $x - $script:sel.X)
        $nw = [Math]::Min($nw, [Math]::Min([double]($img.Width - $script:sel.X), [double]($img.Height - $script:sel.Y) * $W / $H))
        $script:sel = New-Object Drawing.Rectangle $script:sel.X, $script:sel.Y, ([int][Math]::Floor($nw)), ([int][Math]::Floor($nw * $H / $W))
    }
    $pb.Invalidate()
}

# switching panels keeps the crop where it is and re-fits it to the new aspect
$onDevice = {
    param($s, $e)
    $script:Device = [string]$dev.SelectedItem
    $script:W, $script:H = $panels[$script:Device]
    $cw = [Math]::Min([double]$script:sel.Width, [Math]::Min([double]$img.Width, [double]$img.Height * $script:W / $script:H))
    $ch = [int][Math]::Floor($cw * $script:H / $script:W)
    $cx = [Math]::Min([double]$script:sel.X, $img.Width - $cw)
    $cy = [Math]::Min([double]$script:sel.Y, [double]($img.Height - $ch))
    $script:sel = New-Object Drawing.Rectangle ([int]$cx), ([int]$cy), ([int]$cw), $ch
    $form.Text = "$($script:Device) crop $($script:W)x$($script:H) - $([IO.Path]::GetFileName($Path))"
    $pb.Invalidate()
}

$script:saved = @()
$onSave = {
    $out = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([IO.Path]::GetFileNameWithoutExtension($Path) + "_$($script:Device.ToLower()).bmp")
    # same two stages as the preview, so the file is exactly what the window showed.
    # Stage one lands at output size, so stage two resamples nothing.
    $crop = Render $img $script:sel $W $H 1.0 1.0 $false
    $bmp = Render $crop (New-Object Drawing.Rectangle 0, 0, $W, $H) $W $H ($gs.Value / 100) ($cs.Value / 100) $inv.Checked
    $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Bmp)
    $crop.Dispose(); $bmp.Dispose()
    # window stays open: the point of the panel box is exporting X3 and X4 from one crop.
    # Re-saving the same panel overwrites without asking - that is the iteration loop, not an accident.
    $script:saved = @($script:saved | Where-Object { $_ -ne $out }) + $out
    $status.Text = "saved $([IO.Path]::GetFileName($out))"
}
$pb.Add_Paint($onPaint); $pb.Add_MouseDown($onDown); $pb.Add_MouseUp($onUp); $pb.Add_MouseMove($onMove)
$dev.Add_SelectedIndexChanged($onDevice); $save.Add_Click($onSave)

if ($SelfCheck) {
    # fire the real handlers: switch panels, drag the crop by hand, resize by the grip, paint, save
    $ev = { param($x, $y) New-Object Windows.Forms.MouseEventArgs ([Windows.Forms.MouseButtons]::Left), 1, ([int]$x), ([int]$y), 0 }
    $form.CreateControl(); $form.PerformLayout()
    if ($pb.Width -ne $dw -or $pb.Height -ne $dh) { throw "preview is $($pb.Width)x$($pb.Height), expected ${dw}x${dh}: overlay would be off by that much" }
    if ($bar.Top -lt $pb.Bottom -or $bar.Bottom -gt $form.ClientSize.Height) { throw 'control bar overlaps the preview or runs off the form' }
    foreach ($ctl in $bar.Controls) {
        if ($ctl.Right -gt $bar.Width -or $ctl.Bottom -gt $bar.Height) { throw "$($ctl.GetType().Name) '$($ctl.Text)' is clipped by the control bar" }
    }
    $other = @($panels.Keys | Where-Object { $_ -ne $Device })[0]
    $dev.SelectedItem = $other; & $onDevice $dev $null
    $ratio = $panels[$other][0] / $panels[$other][1]
    if ([Math]::Abs($script:sel.Width / $script:sel.Height - $ratio) -gt 0.01) { throw "panel box did not re-fit the crop to $other" }
    $dev.SelectedItem = $Device; & $onDevice $dev $null
    $c = $script:sel
    & $onDown $pb (& $ev ($c.X * $scale + 10) ($c.Y * $scale + 10))
    & $onMove $pb (& $ev ($c.X * $scale + 30) ($c.Y * $scale + 30))   # diagonal: a full-width crop can still move down
    $slack = $img.Width -gt $c.Width -or $img.Height -gt $c.Height
    if ($slack -and $script:sel.Location -eq $c.Location) { throw 'drag did not move the crop' }
    & $onUp $pb $null
    $c = $script:sel
    & $onDown $pb (& $ev ($c.Right * $scale - 2) ($c.Bottom * $scale - 2))
    & $onMove $pb (& $ev ($c.Right * $scale - 40) ($c.Bottom * $scale))
    if ($script:sel.Width -ge $c.Width) { throw 'grip did not resize the crop' }
    if ([Math]::Abs($script:sel.Width / $script:sel.Height - $W / $H) -gt 0.01) { throw "resize broke the $Device aspect" }
    & $onUp $pb $null
    $surface = New-Object Drawing.Bitmap $dw, $dh
    $sg = [Drawing.Graphics]::FromImage($surface)
    & $onPaint $pb (New-Object Windows.Forms.PaintEventArgs $sg, (New-Object Drawing.Rectangle 0, 0, $dw, $dh))
    $sg.Dispose(); $surface.Dispose()

    $pts = @(40, 40), @(200, 300), @(($W - 20), ($H - 20))   # parens: comma binds tighter than minus
    $plain = Render $img $script:sel $W $H 1.0 1.0 $false
    $flip  = Render $img $script:sel $W $H 1.0 1.0 $true
    foreach ($pt in $pts) {
        # the whole point of the tool: output must be gray, or it will not survive the panel
        $px = $plain.GetPixel($pt[0], $pt[1])
        if ($px.R -ne $px.G -or $px.G -ne $px.B) { throw "output is not gray at $($pt[0]),$($pt[1]): $($px.R),$($px.G),$($px.B)" }
        # invert must be a true complement, not merely "different"
        $sum = $px.R + $flip.GetPixel($pt[0], $pt[1]).R
        if ([Math]::Abs($sum - 255) -gt 3) { throw "invert is not a complement at $($pt[0]),$($pt[1]): $sum should be 255" }
    }
    $flip.Dispose()

    # a transparent source must composite onto paper, not onto the bitmap's default black
    $clear = New-Object Drawing.Bitmap 64, 64, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $onWhite = Render $clear (New-Object Drawing.Rectangle 0, 0, 64, 64) 32 32 1.0 1.0 $false
    if ($onWhite.GetPixel(16, 16).R -ne 255) { throw "transparent areas came out $($onWhite.GetPixel(16,16).R), not white" }
    $clear.Dispose(); $onWhite.Dispose()

    # sliders: brighter must be brighter, and contrast must pivot around mid gray
    $ramp = New-Object Drawing.Bitmap 400, 400, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $rg = [Drawing.Graphics]::FromImage($ramp)
    $rb = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.Point 0, 0),
          (New-Object Drawing.Point 400, 0), ([Drawing.Color]::Black), ([Drawing.Color]::White)
    $rg.FillRectangle($rb, 0, 0, 400, 400); $rg.Dispose()
    $whole = New-Object Drawing.Rectangle 0, 0, 400, 400
    $tone = { param($gm, $ct) $r = Render $ramp $whole 400 400 $gm $ct $false
              $v = @($r.GetPixel(80, 200).R, $r.GetPixel(320, 200).R); $r.Dispose(); $v }
    $base = & $tone 1.0 1.0
    $up = & $tone 2.0 1.0; $down = & $tone 0.5 1.0
    if ($up[0] -le $base[0] -or $down[0] -ge $base[0]) { throw "bright slider is not monotonic: $($down[0]) $($base[0]) $($up[0])" }
    $hard = & $tone 1.0 2.0
    if ($hard[0] -ge $base[0] -or $hard[1] -le $base[1]) { throw "contrast does not pivot around mid: dark $($hard[0]) light $($hard[1])" }
    $ramp.Dispose()

    # and the slider -> preview wiring, not just the maths: same pixels, before and after
    $probe = { @(0.25, 0.5, 0.75) | ForEach-Object { $pb.Image.GetPixel([int]($dw * $_), [int]($dh * $_)).R } }
    $before = & $probe
    $gs.Value = 200; $cs.Value = 160; Update-Preview
    if (-not (Compare-Object $before (& $probe))) { throw 'moving the sliders did not change the preview' }
    $inv.Checked = -not $inv.Checked; Update-Preview
    if (-not (Compare-Object $before (& $probe))) { throw 'the invert box did not change the preview' }
    $inv.Checked = -not $inv.Checked
    $gs.Value = 100; $cs.Value = 100; Update-Preview
    $plain.Dispose()

    $inv.Checked = $true   # the save below goes through the checkbox, inverted
    & $onSave $save $null

    $out = $script:saved[-1]
    if (-not $out) { throw 'save produced no file' }
    if ($form.IsDisposed) { throw 'save closed the window; it should stay open for the other panel' }
    $hdr = [IO.File]::ReadAllBytes($out)
    if ([Text.Encoding]::ASCII.GetString($hdr[0..1]) -ne 'BM') { throw 'not a BMP' }
    $bw = [BitConverter]::ToInt32($hdr, 18); $bh = [Math]::Abs([BitConverter]::ToInt32($hdr, 22))
    $bpp = [BitConverter]::ToInt16($hdr, 28); $comp = [BitConverter]::ToInt32($hdr, 30)
    if ($bw -ne $W -or $bh -ne $H -or $bpp -ne 24 -or $comp -ne 0) { throw "bad header: ${bw}x${bh} ${bpp}bpp comp=$comp" }
    if ($hdr.Length -lt $W * $H * 3) { throw 'too small to be uncompressed' }
    # and the pixels are the crop that was framed, at the settings that were showing
    $want = Render $img $script:sel $W $H ($gs.Value / 100) ($cs.Value / 100) $inv.Checked
    $got = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $hdr)))
    foreach ($pt in $pts) {
        $d = [Math]::Abs($want.GetPixel($pt[0], $pt[1]).R - $got.GetPixel($pt[0], $pt[1]).R)
        if ($d -gt 2) { throw "saved file is not the framed crop at $($pt[0]),$($pt[1]): off by $d" }
    }
    $want.Dispose(); $got.Dispose()
    "self-check ok: $out (${bw}x${bh} ${bpp}bpp uncompressed, $($hdr.Length) bytes)"
    $pb.Image.Dispose(); $script:flat.Dispose(); $img.Dispose(); $form.Dispose()
    Remove-Item $out, (Join-Path $env:TEMP 'xcrop-selfcheck.png') -ErrorAction SilentlyContinue
    exit 0
}

[void]$form.ShowDialog()
$pb.Image.Dispose(); $script:flat.Dispose(); $img.Dispose(); $form.Dispose()
$script:saved | ForEach-Object { "saved: $_" }
