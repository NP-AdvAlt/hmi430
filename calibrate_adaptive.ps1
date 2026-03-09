# calibrate_adaptive.ps1
# Adaptive CNC-to-screen calibration.
# Tiles the full screen with 30 buttons (6x5), aims booper at a target button,
# reads which button lit, zooms in around the hit, repeats until <10px accuracy.
# Tests at 5 screen locations to detect any tilt/scale in the mapping.
#
# Usage: powershell -ExecutionPolicy Bypass -File calibrate_adaptive.ps1

. "$PSScriptRoot\mtp_screenshot.ps1"
Add-Type -AssemblyName System.Drawing

# ?????? CNC mapping (start from original config.spt values) ???????????????????????????????????????????????????????????????
$script:xOrigin = 138.0;  $script:xScale = 93.0 / 479.0  # CNC_X = xOrigin - sx*xScale
$script:yOrigin = -77.0;  $script:yScale = 51.0 / 271.0  # CNC_Y = yOrigin + sy*yScale

# ?????? Test locations (screen pixels) ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
$testLocations = @(
    @{name="center";     sx=240; sy=136},
    @{name="top-left";   sx= 80; sy= 45},
    @{name="top-right";  sx=400; sy= 45},
    @{name="bot-left";   sx= 80; sy=227},
    @{name="bot-right";  sx=400; sy=227}
)

$nodeExe  = "C:\Claude\hmi430\node\node-v22.14.0-win-x64\node.exe"
$buildJs  = "C:\Claude\hmi430\splat_build.js"
$buildBd  = "C:\Claude\hmi430\_build.b1d"
$binPath  = "C:\Claude\hmi430\_build.b1n"
$sptPath  = "C:\Claude\hmi430\ui_test.spt"
$mtpExe   = "C:\Claude\hmi430\MtpCopy.exe"
$outDir   = "C:\Claude\hmi430\screen_captures\calibration"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ?????? Helpers ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
function ScreenToCnc($sx, $sy) {
    [PSCustomObject]@{
        X = [Math]::Round($script:xOrigin - $sx * $script:xScale, 3)
        Y = [Math]::Round($script:yOrigin + $sy * $script:yScale, 3)
    }
}

function ApplyMappingCorrection($errSx, $errSy) {
    # errSx = hit_sx - target_sx (pixels we missed by)
    # Adjust origins so next press at same screen coord hits correctly
    $script:xOrigin += $errSx * $script:xScale
    $script:yOrigin -= $errSy * $script:yScale
    Write-Host "  Mapping updated: xOrigin=$([Math]::Round($script:xOrigin,3))  yOrigin=$([Math]::Round($script:yOrigin,3))"
}

function Get-GridButtons($regionX, $regionY, $regionW, $regionH, $cols, $rows) {
    $buttons = @()
    $id = 0
    for ($r = 0; $r -lt $rows; $r++) {
        $y = $regionY + [int]($regionH * $r / $rows)
        $h = $regionY + [int]($regionH * ($r+1) / $rows) - $y
        for ($c = 0; $c -lt $cols; $c++) {
            $x = $regionX + [int]($regionW * $c / $cols)
            $w = $regionX + [int]($regionW * ($c+1) / $cols) - $x
            $buttons += [PSCustomObject]@{
                id=$id; col=$c; row=$r
                x=$x; y=$y; w=$w; h=$h
                cx=($x + [int]($w/2)); cy=($y + [int]($h/2))
            }
            $id++
        }
    }
    return $buttons
}

function New-GridFirmware($buttons, $targetId) {
    $cols = ($buttons | Measure-Object col -Maximum).Maximum + 1
    $n    = $buttons.Count
    $spt  = "; ui_test.spt -- adaptive calibration grid ($n buttons)`n"
    $spt += "uiTask:`n    YieldTask`n    YieldTask`nuiTask_draw:`n    GoSub drawGrid`n    YieldTask`n    YieldTask`nuiTask_idle:`n    Pause 500`n    GoTo uiTask_idle`n`ndrawGrid:`n    #HMI SetColours(f:'FFFFFFFF, b:'FF000000)`n    #HMI Reset(b:0)`n    ClrInstCount`n"
    for ($i = 0; $i -lt $n; $i++) {
        $b = $buttons[$i]
        $col = if ($b.id -eq $targetId) { "'FFA0A0A0" } else { "'FF404040" }
        $spt += "    #HMI ButtonEvent2(id:$($b.id), x:$($b.x)px, y:$($b.y)px, w:$($b.w)px, h:$($b.h)px, t:"" "", rb:$col, ev:onBtn$($b.id))`n"
        if (($i + 1) % 5 -eq 0 -and $i -lt $n-1) { $spt += "    ClrInstCount`n" }
    }
    $spt += "    Return`n"
    foreach ($b in $buttons) {
        $spt += "`nonBtn$($b.id):`n    #HMI ButtonEvent2(id:$($b.id), x:$($b.x)px, y:$($b.y)px, w:$($b.w)px, h:$($b.h)px, t:"" "", rb:'FFFFFFFF, ev:onBtn$($b.id))`n    Return`n"
    }
    [System.IO.File]::WriteAllText($sptPath, $spt, [System.Text.UTF8Encoding]::new($false))
}

function Build-AndFlash {
    $r = & $nodeExe $buildJs $buildBd 2>&1 | Out-String
    if ($r -notmatch 'BUILD SUCCESS') { throw "Build failed:`n$r" }
    # Retry flash: after reboot, Windows MTP re-enumeration can take 30-60s
    $deadline = [DateTime]::Now.AddSeconds(90)
    while ([DateTime]::Now -lt $deadline) {
        $f = & $mtpExe $binPath 2>&1 | Out-String
        if ($f -match 'SUCCESS') { return }
        if ($f -notmatch 'System Firmware.*not found') { throw "Flash failed:`n$f" }
        Write-Host "  System Firmware not ready yet, retrying in 5s..."
        Start-Sleep -Seconds 5
    }
    throw "Flash failed: System Firmware not available after 90s"
}

function Get-Bright($bmp, $cx, $cy, $r=6) {
    $t=0.0; $n=0
    for ($px=$cx-$r; $px -lt $cx+$r; $px++) {
        for ($py=$cy-$r; $py -lt $cy+$r; $py++) {
            if ($px -ge 0 -and $px -lt 480 -and $py -ge 0 -and $py -lt 272) {
                $p=$bmp.GetPixel($px,$py); $t+=0.299*$p.R+0.587*$p.G+0.114*$p.B; $n++
            }
        }
    }
    if ($n -gt 0) { return $t/$n } else { return 0.0 }
}

# ?????? CNC ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
$comPort = $null
$cnc = Get-PnpDevice | Where-Object { $_.FriendlyName -match 'CH340' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($cnc -and ($cnc.FriendlyName -match 'COM(\d+)')) { $comPort = "COM$($Matches[1])" }
if (-not $comPort) {
    foreach ($p in 'COM13','COM12','COM15','COM11','COM14') {
        if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $p) { $comPort = $p; break }
    }
}
if (-not $comPort) { throw "CNC COM port not found." }
Write-Host "CNC: $comPort"

$port = [System.IO.Ports.SerialPort]::new($comPort, 115200)
$port.ReadTimeout = 5000; $port.Open(); Start-Sleep -Milliseconds 500

function Send-Gcode([string]$cmd, [int]$waitMs=300) {
    $port.WriteLine($cmd); Start-Sleep -Milliseconds $waitMs
    try { while ($port.BytesToRead -gt 0) { $port.ReadLine() | Out-Null } } catch {}
}
function Wait-Idle([int]$timeoutSec=45) {
    $d = [DateTime]::Now.AddSeconds($timeoutSec)
    while ([DateTime]::Now -lt $d) {
        $port.Write("?"); Start-Sleep -Milliseconds 150
        try { $r = $port.ReadLine(); if ($r -match 'Idle') { return } } catch {}
    }
    Write-Warning "Idle timeout"
}

try {
    # ?????? HOME ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
    Write-Host "`n=== HOMING ==="
    Send-Gcode '$X' 300            # clear alarm if any
    Send-Gcode '$H' 500            # homing cycle (moves to limit switches)
    Wait-Idle 60
    Send-Gcode 'G21 G90 G54' 300
    Send-Gcode 'G10 L20 P1 X0 Y0 Z0' 300   # set work origin at home
    Send-Gcode 'G0 Z0' 800; Wait-Idle
    Write-Host "Homed OK"

    # ?????? CALIBRATION LOOP ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
    $logEntries = [System.Collections.Generic.List[PSObject]]::new()
    $round = 0

    foreach ($loc in $testLocations) {
        Write-Host "`n===== Location: $($loc.name) target=($($loc.sx),$($loc.sy)) ====="

        # Start with full-screen grid, zoom in each round
        $regionX = 0; $regionY = 0; $regionW = 480; $regionH = 272
        $cols = 6; $rows = 5
        $maxRounds = 4

        for ($rnd = 1; $rnd -le $maxRounds; $rnd++) {
            $round++
            $buttons = Get-GridButtons $regionX $regionY $regionW $regionH $cols $rows

            # Find which button contains the current target screen position
            $targetBtn = $buttons | Where-Object {
                $loc.sx -ge $_.x -and $loc.sx -lt ($_.x+$_.w) -and
                $loc.sy -ge $_.y -and $loc.sy -lt ($_.y+$_.h)
            } | Select-Object -First 1
            if (-not $targetBtn) { Write-Warning "Target outside region, clipping to center button"; $targetBtn = $buttons[[int]($buttons.Count/2)] }

            $btnSzStr = "$($targetBtn.w)x$($targetBtn.h)px"
            Write-Host "`n  [Round $rnd] grid $($regionW)x$($regionH)px region, buttons $btnSzStr"
            Write-Host "  Target btn$($targetBtn.id) at screen($($targetBtn.cx),$($targetBtn.cy))"

            # Generate, build, flash firmware
            Write-Host "  Generating firmware..."
            New-GridFirmware $buttons $targetBtn.id
            Write-Host "  Building..."
            Build-AndFlash
            Write-Host "  Flashed OK -- booting HMI..."
            Start-Sleep -Seconds 3   # let device start rebooting
            Send-Gcode "M3 S1000" 500
            Start-Sleep -Seconds 20  # boot time (was 15 -- extra margin for MTP re-enum)

            # Compute CNC position for target button center
            $cncPos = ScreenToCnc $targetBtn.cx $targetBtn.cy
            Write-Host "  Pressing CNC($($cncPos.X), $($cncPos.Y))..."

            Send-Gcode "G0 X$($cncPos.X) Y$($cncPos.Y)" 1500; Wait-Idle
            Send-Gcode "G0 Z-14" 700; Wait-Idle
            Start-Sleep -Milliseconds 400
            Send-Gcode "G0 Z-4" 600; Wait-Idle
            Start-Sleep -Milliseconds 400
            Send-Gcode "G0 Z0" 800; Wait-Idle

            # Screenshot
            Write-Host "  Taking screenshot..."
            $shotFile = Get-MtpScreenshot -OutDir $outDir
            $shotDest = Join-Path $outDir "round${round}_$($loc.name)_rnd${rnd}.png"
            if (Test-Path $shotDest) { Remove-Item $shotDest -Force }
            Rename-Item $shotFile (Split-Path $shotDest -Leaf) -Force
            Write-Host "  Screenshot: $shotDest"

            Send-Gcode "M5" 300   # power off (resets buttons on next boot)

            # Analyze which button turned white
            $bmp = [System.Drawing.Bitmap]::new($shotDest)
            $hitBtn = $null; $hitBright = 0
            foreach ($b in $buttons) {
                $bright = Get-Bright $bmp $b.cx $b.cy
                if ($bright -gt 200 -and $bright -gt $hitBright) {
                    $hitBtn = $b; $hitBright = $bright
                }
            }
            $bmp.Dispose()

            if (-not $hitBtn) {
                Write-Host "  NO HIT detected. Booper missed all buttons."
                Write-Host "  Button size was $btnSzStr ??? region may need adjustment."
                $logEntries.Add([PSCustomObject]@{
                    location=$loc.name; round=$rnd; btnSize=$btnSzStr
                    targetSx=$targetBtn.cx; targetSy=$targetBtn.cy
                    hitSx="MISS"; hitSy="MISS"; errSx=""; errSy=""
                    cncX=$cncPos.X; cncY=$cncPos.Y
                })
                break  # can't zoom in without a hit
            }

            $errSx = $hitBtn.cx - $targetBtn.cx
            $errSy = $hitBtn.cy - $targetBtn.cy
            $errMm = [Math]::Round([Math]::Sqrt([Math]::Pow($errSx/$script:xScale*($script:xScale*479/93.0),2) + [Math]::Pow($errSy/$script:yScale*($script:yScale*271/51.0),2)),1)

            Write-Host "  HIT btn$($hitBtn.id) at screen($($hitBtn.cx),$($hitBtn.cy))  brightness=$([Math]::Round($hitBright,1))"
            Write-Host "  Error: $errSx px X, $errSy px Y  (~$([Math]::Round([Math]::Abs($errSx)*93/479,1))mm X, ~$([Math]::Round([Math]::Abs($errSy)*51/271,1))mm Y)"

            $logEntries.Add([PSCustomObject]@{
                location=$loc.name; round=$rnd; btnSize=$btnSzStr
                targetSx=$targetBtn.cx; targetSy=$targetBtn.cy
                hitSx=$hitBtn.cx; hitSy=$hitBtn.cy
                errSx=$errSx; errSy=$errSy
                cncX=$cncPos.X; cncY=$cncPos.Y
            })

            # Apply correction and zoom in
            if ($loc.name -eq "center") {
                # Only update mapping from center location (most reliable)
                ApplyMappingCorrection $errSx $errSy
            }

            # Stop if already within 1 button of target
            if ([Math]::Abs($errSx) -le $targetBtn.w -and [Math]::Abs($errSy) -le $targetBtn.h) {
                Write-Host "  Within button tolerance ??? zooming in"
            }

            # Zoom in: 3x3 button region around actual hit
            $zoomW = $targetBtn.w * 4   # cover 4 buttons wide around hit
            $zoomH = $targetBtn.h * 4
            $regionX = [Math]::Max(0, $hitBtn.cx - [int]($zoomW/2))
            $regionY = [Math]::Max(0, $hitBtn.cy - [int]($zoomH/2))
            $regionW = [Math]::Min($zoomW, 480 - $regionX)
            $regionH = [Math]::Min($zoomH, 272 - $regionY)
            # Keep target within region
            if ($loc.sx -lt $regionX) { $regionX = [Math]::Max(0, $loc.sx - [int]($zoomW/4)) }
            if ($loc.sy -lt $regionY) { $regionY = [Math]::Max(0, $loc.sy - [int]($zoomH/4)) }
            if ($loc.sx -ge $regionX + $regionW) { $regionW = [Math]::Min($loc.sx - $regionX + [int]($zoomW/4), 480-$regionX) }
            if ($loc.sy -ge $regionY + $regionH) { $regionH = [Math]::Min($loc.sy - $regionY + [int]($zoomH/4), 272-$regionY) }

            # Stop when buttons are <= 10px
            $nextBtnW = [int]($regionW / $cols)
            $nextBtnH = [int]($regionH / $rows)
            if ($nextBtnW -le 10 -and $nextBtnH -le 10) {
                Write-Host "  Reached small button size -- done for this location"
                break
            }
        }
    }

    Send-Gcode "G0 Z0" 800; Wait-Idle

} finally {
    if ($port -and $port.IsOpen) { $port.Close() }
}

# ?????? Results ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
Write-Host "`n===== CALIBRATION RESULTS ====="
Write-Host "Final mapping:  xOrigin=$([Math]::Round($script:xOrigin,3))  yOrigin=$([Math]::Round($script:yOrigin,3))"
Write-Host "Original was:   xOrigin=138.000  yOrigin=-77.000"
Write-Host ""
$logEntries | Format-Table -AutoSize
$csv = Join-Path $outDir "calibration_results.csv"
$logEntries | Export-Csv $csv -NoTypeInformation
Write-Host "Log: $csv"
Write-Host ""
Write-Host "To apply these corrections, update calibrate_zones.ps1:"
Write-Host "  `$xOrigin = $([Math]::Round($script:xOrigin,3))"
Write-Host "  `$yOrigin = $([Math]::Round($script:yOrigin,3))"
