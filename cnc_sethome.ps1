# cnc_sethome.ps1 - Establish home position and configure machine
#
# Machine physical layout:
#   X:  0 = gantry all the way LEFT,   160 = all the way right
#   Y:  0 = table all the way TOWARD user, 100 = away  ($3 bit1 inverts motor so Y- is toward user)
#   Z:  0 = head at LOWEST (toward work), 45 = fully RETRACTED (home)
#
# Work coordinate system after this script:
#   Home = work (0, 0, 0) = machine (0, 0, 45)
#   Z goes negative when moving toward work surface (e.g. work Z=-30 = 30mm below home)

function WaitForIdle {
    param($port, $label = '', $timeoutSec = 30)
    Start-Sleep -Milliseconds 400
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $port.Write('?')
        Start-Sleep -Milliseconds 250
        $r = $port.ReadExisting()
        if ($r -match 'Alarm') { Write-Host "  [ALARM] $r"; return $false }
        if ($r -match 'Idle')  {
            $pos = [regex]::Match($r, 'MPos:([0-9.\-,]+)').Groups[1].Value
            Write-Host "  [Idle] $label  MPos=$pos"
            return $true
        }
    }
    Write-Host "  WARNING: timed out"
    return $false
}

function Send {
    param($port, $cmd, [switch]$wait)
    Write-Host "> $cmd"
    $port.WriteLine($cmd)
    Start-Sleep -Milliseconds 200
    $ack = $port.ReadExisting()
    if ($ack) { Write-Host "< $($ack.Trim())" }
    if ($wait) { WaitForIdle $port $cmd | Out-Null }
}

# --- Open port ---
$port = New-Object System.IO.Ports.SerialPort 'COM13', 115200, 'None', 8, 'One'
$port.ReadTimeout = 3000
$port.Open()
Start-Sleep -Milliseconds 800
$port.WriteLine('')
Start-Sleep -Milliseconds 600
$port.ReadExisting() | Out-Null

$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "=== Current state: $($port.ReadExisting().Trim())"

# ---------------------------------------------------------------
# STEP 1: Correct travel limits to match actual machine dimensions
# ---------------------------------------------------------------
Write-Host "`n=== Setting correct travel limits ==="
Send $port '$130=160'   # X max travel: 160mm
Send $port '$131=100'   # Y max travel: 100mm
Send $port '$132=45'    # Z max travel: 45mm

# ---------------------------------------------------------------
# STEP 2: Move to physical home position
#   - Retract Z fully first (Z=45 in machine coords = head fully up)
#   - Then move X=0 (gantry left) and Y=0 (table toward user)
# ---------------------------------------------------------------
Write-Host "`n=== Retracting Z to maximum (head fully up) ==="
Send $port 'G90'              # absolute positioning
Send $port 'G21'              # millimetres
Send $port 'G0 Z45' -wait    # retract Z fully

Write-Host "`n=== Moving to home XY (gantry left, table toward user) ==="
Send $port 'G0 X0 Y0' -wait

# ---------------------------------------------------------------
# STEP 3: Zero work coordinate system (G54) at this position
#   Machine is now at: X=0, Y=0, Z=45
#   We define this as work (0, 0, 0)
#   G54 offset stored = X:0, Y:0, Z:45
# ---------------------------------------------------------------
Write-Host "`n=== Setting work coordinate origin (G54) at home position ==="
Send $port 'G10 L20 P1 X0 Y0 Z0'   # P1 = G54

# Activate G54
Send $port 'G54'

# Verify - work position should now read 0,0,0
$port.Write('?')
Start-Sleep -Milliseconds 400
$status = $port.ReadExisting()
Write-Host "Work position check: $($status.Trim())"

# ---------------------------------------------------------------
# STEP 4: Store this as the G28 quick-home position
# ---------------------------------------------------------------
Write-Host "`n=== Storing G28 home position ==="
Send $port 'G28.1'

# ---------------------------------------------------------------
# STEP 5: Set startup blocks so G54 is always active on power-up
# ---------------------------------------------------------------
Write-Host "`n=== Configuring startup blocks ==="
Send $port '$N0=G21G90G54'   # mm mode, absolute, use G54 work coords

# Verify startup block stored
Write-Host "`n=== Verifying startup block ==="
$port.WriteLine('$N')
Start-Sleep -Milliseconds 500
Write-Host $port.ReadExisting()

# ---------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------
Write-Host "`n=== Final coordinate tables ==="
$port.WriteLine('$#')
Start-Sleep -Milliseconds 800
Write-Host $port.ReadExisting()

$port.Write('?')
Start-Sleep -Milliseconds 400
Write-Host "=== Final status: $($port.ReadExisting().Trim())"

$port.Close()

Write-Host @"

=== HOME POSITION ESTABLISHED ===
  Work (0, 0, 0) = gantry left, table toward user, head fully retracted

Axis reference from home:
  X+  -->  gantry moves right        (0 to 160mm)
  X-  -->  gantry moves left         (returns to home)
  Y+  -->  table moves away from you (0 to 100mm)
  Y-  -->  table moves toward you    (returns to home)
  Z-  -->  head moves DOWN toward work surface (0 to -45mm)
  Z+  -->  head moves UP / retracts  (returns to home)

  To return home at any time:  G28
  On power-up G54 activates automatically via startup block.
"@
