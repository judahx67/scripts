# album-review.ps1 - quick keep/delete review of the music library.
# Decisions saved to album-decisions.json after every click (resumable).
# Nothing is deleted until you press "Finish & Delete..." and confirm; deletes go to the Recycle Bin.
# Keys: K = keep, D = delete, Backspace = undo last

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$saveFile = Join-Path $root 'album-decisions.json'
$audioExts = '.flac','.mp3','.m4a','.ogg','.opus','.wav','.wma','.ape'

Write-Host 'Scanning library...'
$groups = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $audioExts -contains $_.Extension.ToLower() } |
    Group-Object DirectoryName

# Merge disc subfolders (CD1, Disc 2, ...) into their parent album folder
$albumMap = @{}
foreach ($g in $groups) {
    $dir = $g.Name
    if ((Split-Path $dir -Leaf) -match '^(cd|disc|disk|vol(ume)?)[ ._-]*\d+$') { $dir = Split-Path $dir -Parent }
    if ($dir -eq $root) { continue }
    if (-not $albumMap.ContainsKey($dir)) {
        $albumMap[$dir] = [pscustomobject]@{ Path = $dir; Tracks = 0; Audio = ($g.Group | Sort-Object Name)[0].FullName }
    }
    $albumMap[$dir].Tracks += $g.Count
}

$albums = @($albumMap.Values | Sort-Object Path | ForEach-Object {
    $leaf = Split-Path $_.Path -Leaf
    $parentDir = Split-Path $_.Path -Parent
    if ($parentDir -eq $root) { $artist = '' } else { $artist = Split-Path $parentDir -Leaf }
    $year = ''; $title = $leaf
    if ($leaf -match '^(\d{4})(-\d{2}(-\d{2})?)?\s*[-.]\s*(.+)$') { $year = $Matches[1]; $title = $Matches[4] }
    [pscustomobject]@{
        Path = $_.Path; Rel = $_.Path.Substring($root.Length + 1)
        Artist = $artist; Title = $title; Year = $year; Tracks = $_.Tracks; Audio = $_.Audio
    }
})
Write-Host "Found $($albums.Count) albums."

# ---------- cover art ----------
function Read-BE32($br) {
    $b = $br.ReadBytes(4)
    return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor $b[3]
}

function Get-EmbeddedArt([string]$file) {
    try {
        $fs = [IO.File]::OpenRead($file)
        $br = New-Object IO.BinaryReader($fs)
        try {
            $magic = $br.ReadBytes(4)
            $magicStr = [Text.Encoding]::ASCII.GetString($magic)
            if ($magicStr -eq 'fLaC') {
                while ($fs.Position -lt $fs.Length) {
                    $h = $br.ReadBytes(4)
                    if ($h.Count -lt 4) { break }
                    $isLast = ($h[0] -band 0x80) -ne 0
                    $btype = $h[0] -band 0x7F
                    $len = ([int]$h[1] -shl 16) -bor ([int]$h[2] -shl 8) -bor $h[3]
                    if ($btype -eq 6) {
                        [void]$br.ReadBytes(4)                       # picture type
                        $n = Read-BE32 $br; [void]$br.ReadBytes($n)  # mime
                        $n = Read-BE32 $br; [void]$br.ReadBytes($n)  # description
                        [void]$br.ReadBytes(16)                      # dims/depth/colors
                        $n = Read-BE32 $br
                        return $br.ReadBytes($n)
                    }
                    [void]$fs.Seek($len, 'Current')
                    if ($isLast) { break }
                }
            }
            elseif ($magicStr.StartsWith('ID3')) {
                [void]$fs.Seek(3, 'Begin')
                $ver = $br.ReadByte(); [void]$br.ReadByte(); [void]$br.ReadByte()
                $sz = $br.ReadBytes(4)
                $tagSize = ([int]$sz[0] -shl 21) -bor ([int]$sz[1] -shl 14) -bor ([int]$sz[2] -shl 7) -bor $sz[3]
                $body = $br.ReadBytes($tagSize)
                $pos = 0
                while ($pos + 10 -le $body.Length) {
                    if ($body[$pos] -eq 0) { break }
                    $id = [Text.Encoding]::ASCII.GetString($body, $pos, 4)
                    if ($ver -ge 4) {
                        $fsize = ([int]$body[$pos+4] -shl 21) -bor ([int]$body[$pos+5] -shl 14) -bor ([int]$body[$pos+6] -shl 7) -bor $body[$pos+7]
                    } else {
                        $fsize = ([int]$body[$pos+4] -shl 24) -bor ([int]$body[$pos+5] -shl 16) -bor ([int]$body[$pos+6] -shl 8) -bor $body[$pos+7]
                    }
                    if ($fsize -le 0 -or ($pos + 10 + $fsize) -gt $body.Length) { break }
                    if ($id -eq 'APIC') {
                        $p = $pos + 10
                        $enc = $body[$p]; $p++
                        while ($body[$p] -ne 0) { $p++ }; $p++       # mime
                        $p++                                          # picture type
                        if ($enc -eq 1 -or $enc -eq 2) {
                            while (-not ($body[$p] -eq 0 -and $body[$p+1] -eq 0)) { $p += 2 }; $p += 2
                        } else {
                            while ($body[$p] -ne 0) { $p++ }; $p++
                        }
                        $len = ($pos + 10 + $fsize) - $p
                        if ($len -le 0) { break }
                        $img = New-Object byte[] $len
                        [Array]::Copy($body, $p, $img, 0, $len)
                        return $img
                    }
                    $pos += 10 + $fsize
                }
            }
        } finally { $br.Dispose() }
    } catch { }
    return $null
}

function Get-CoverImage($album) {
    $bytes = $null
    if ($album.Audio) { $bytes = Get-EmbeddedArt $album.Audio }
    if (-not $bytes) {
        $imgs = @(Get-ChildItem -LiteralPath $album.Path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(jpe?g|png)$' })
        $pick = $imgs | Where-Object { $_.BaseName -match '^(cover|folder|front|index|image|albumart|album)$' } | Select-Object -First 1
        if (-not $pick) { $pick = $imgs | Sort-Object Length -Descending | Select-Object -First 1 }
        if ($pick) { $bytes = [IO.File]::ReadAllBytes($pick.FullName) }
    }
    if ($bytes) {
        try { return [Drawing.Image]::FromStream((New-Object IO.MemoryStream(,$bytes))) } catch { }
    }
    return $null
}

# ---------- decisions ----------
$decisions = @{}
if (Test-Path $saveFile) {
    (Get-Content -LiteralPath $saveFile -Raw | ConvertFrom-Json).psobject.Properties |
        ForEach-Object { $decisions[$_.Name] = $_.Value }
}
function Save-Decisions {
    $o = [ordered]@{}
    $decisions.Keys | Sort-Object | ForEach-Object { $o[$_] = $decisions[$_] }
    [IO.File]::WriteAllText($saveFile, (ConvertTo-Json $o), [Text.Encoding]::UTF8)
}

# ---------- UI ----------
$bg = [Drawing.Color]::FromArgb(18, 18, 18)
$form = New-Object Windows.Forms.Form
$form.Text = 'Album Review'
$form.ClientSize = New-Object Drawing.Size(520, 720)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.KeyPreview = $true
$form.BackColor = $bg

$pic = New-Object Windows.Forms.PictureBox
$pic.SetBounds(20, 15, 480, 480)
$pic.SizeMode = 'Zoom'
$pic.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.SetBounds(20, 505, 480, 60)
$lblTitle.Font = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [Drawing.Color]::White
$lblTitle.BackColor = $bg

$lblArtist = New-Object Windows.Forms.Label
$lblArtist.SetBounds(20, 567, 480, 25)
$lblArtist.Font = New-Object Drawing.Font('Segoe UI', 10)
$lblArtist.ForeColor = [Drawing.Color]::FromArgb(179, 179, 179)
$lblArtist.BackColor = $bg

$lblProgress = New-Object Windows.Forms.Label
$lblProgress.SetBounds(20, 596, 480, 20)
$lblProgress.Font = New-Object Drawing.Font('Segoe UI', 9)
$lblProgress.ForeColor = [Drawing.Color]::FromArgb(120, 120, 120)
$lblProgress.BackColor = $bg

function New-Btn($text, $x, $w, $back) {
    $b = New-Object Windows.Forms.Button
    $b.SetBounds($x, 625, $w, 45)
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $b.ForeColor = [Drawing.Color]::White
    $b.BackColor = $back
    $b.TabStop = $false
    return $b
}
$btnKeep   = New-Btn 'Keep (K)'    20  150 ([Drawing.Color]::FromArgb(29, 135, 66))
$btnDelete = New-Btn 'Delete (D)'  185 150 ([Drawing.Color]::FromArgb(180, 40, 40))
$btnBack   = New-Btn 'Undo'        350 70  ([Drawing.Color]::FromArgb(60, 60, 60))
$btnFinish = New-Btn 'Finish...'   430 70  ([Drawing.Color]::FromArgb(60, 60, 60))
$form.Controls.AddRange(@($pic, $lblTitle, $lblArtist, $lblProgress, $btnKeep, $btnDelete, $btnBack, $btnFinish))

$script:idx = -1
$script:history = New-Object Collections.Stack

function Show-Album {
    $a = $albums[$script:idx]
    $old = $pic.Image
    $pic.Image = Get-CoverImage $a
    if ($old) { $old.Dispose() }
    if ($a.Year) { $lblTitle.Text = "$($a.Title) ($($a.Year))" } else { $lblTitle.Text = $a.Title }
    if ($a.Artist) { $lblArtist.Text = "$($a.Artist)  -  $($a.Tracks) songs" } else { $lblArtist.Text = "$($a.Tracks) songs" }
    $delCount = @($decisions.Values | Where-Object { $_ -eq 'delete' }).Count
    $lblProgress.Text = "$($decisions.Count) / $($albums.Count) decided  -  $delCount marked for deletion"
}

function Next-Album {
    $i = $script:idx + 1
    while ($i -lt $albums.Count -and $decisions.ContainsKey($albums[$i].Rel)) { $i++ }
    if ($i -ge $albums.Count) {
        $script:idx = -1
        if ($pic.Image) { $pic.Image.Dispose(); $pic.Image = $null }
        $lblTitle.Text = 'All albums reviewed'
        $lblArtist.Text = 'Press Finish... to review and delete the marked albums.'
        $btnKeep.Enabled = $false; $btnDelete.Enabled = $false
    } else {
        $script:idx = $i
        $btnKeep.Enabled = $true; $btnDelete.Enabled = $true
        Show-Album
    }
}

function Set-Decision($what) {
    if ($script:idx -lt 0) { return }
    $decisions[$albums[$script:idx].Rel] = $what
    Save-Decisions
    $script:history.Push($script:idx)
    Next-Album
}

function Undo-Decision {
    if ($script:history.Count -eq 0) { return }
    $script:idx = $script:history.Pop()
    $decisions.Remove($albums[$script:idx].Rel)
    Save-Decisions
    $btnKeep.Enabled = $true; $btnDelete.Enabled = $true
    Show-Album
}

function Invoke-Finish {
    $del = @($albums | Where-Object { $decisions[$_.Rel] -eq 'delete' })
    if ($del.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('No albums are marked for deletion.', 'Album Review') | Out-Null
        return
    }
    $bytes = 0
    foreach ($a in $del) {
        $bytes += (Get-ChildItem -LiteralPath $a.Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    }
    $gb = [math]::Round($bytes / 1GB, 2)

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Confirm deletion'
    $dlg.ClientSize = New-Object Drawing.Size(560, 480)
    $dlg.StartPosition = 'CenterParent'
    $lbl = New-Object Windows.Forms.Label
    $lbl.SetBounds(15, 12, 530, 22)
    $lbl.Text = "These $($del.Count) albums ($gb GB) will be sent to the Recycle Bin:"
    $txt = New-Object Windows.Forms.TextBox
    $txt.SetBounds(15, 40, 530, 380)
    $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Vertical'
    $txt.Text = ($del.Rel -join "`r`n")
    $ok = New-Object Windows.Forms.Button
    $ok.SetBounds(285, 432, 180, 35); $ok.Text = "Delete $($del.Count) albums"
    $ok.DialogResult = 'OK'
    $cancel = New-Object Windows.Forms.Button
    $cancel.SetBounds(475, 432, 70, 35); $cancel.Text = 'Cancel'
    $cancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))
    $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog($form) -ne 'OK') { return }

    $failed = @()
    foreach ($a in $del) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($a.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $decisions[$a.Rel] = 'deleted'
            $parent = Split-Path $a.Path -Parent   # remove artist folder if now empty
            if ($parent -ne $root -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($parent, 'OnlyErrorDialogs', 'SendToRecycleBin')
            }
        } catch { $failed += $a.Rel }
    }
    Save-Decisions
    $msg = "Deleted $($del.Count - $failed.Count) albums (sent to Recycle Bin)."
    if ($failed.Count) { $msg += "`r`nFailed: `r`n" + ($failed -join "`r`n") }
    [Windows.Forms.MessageBox]::Show($msg, 'Album Review') | Out-Null
}

$btnKeep.Add_Click({ Set-Decision 'keep' })
$btnDelete.Add_Click({ Set-Decision 'delete' })
$btnBack.Add_Click({ Undo-Decision })
$btnFinish.Add_Click({ Invoke-Finish })
$form.Add_KeyDown({
    switch ($_.KeyCode) {
        'K' { Set-Decision 'keep' }
        'D' { Set-Decision 'delete' }
        'Back' { Undo-Decision }
    }
})
$form.Add_FormClosed({ if ($pic.Image) { $pic.Image.Dispose() } })

Next-Album
[void]$form.ShowDialog()
