param([string]$ReferenceExecutable = '', [switch]$SkipMotion)
$ErrorActionPreference = 'Stop'
$cirrusRoot = Split-Path $PSScriptRoot -Parent
$cirrusEngine = Join-Path $cirrusRoot 'build\Release\CirrusEngine.exe'
if (-not (Test-Path -LiteralPath $cirrusEngine)) { throw 'Build the Release preset first.' }
if ($ReferenceExecutable) { $ReferenceExecutable = (Resolve-Path -LiteralPath $ReferenceExecutable).Path }

function Invoke-CloudCapture([string]$Executable, [string[]]$CaptureArguments) {
    $cirrusProcess = Start-Process -FilePath $Executable -ArgumentList $CaptureArguments -WorkingDirectory $cirrusRoot -WindowStyle Hidden -Wait -PassThru
    if ($cirrusProcess.ExitCode -ne 0) { throw "GPU capture failed: $($CaptureArguments -join ' '); see logs/cirrus.log" }
}

Push-Location $cirrusRoot
try {
    New-Item -ItemType Directory -Path 'captures\research' -Force | Out-Null
    $cirrusCommon = @('--headless','--no-ui','--width','1600','--height','900','--quality','high','--frames','60','--weather','overcast','--debug-layer')
    foreach ($cirrusScene in @('mixed','vortex')) {
        $cirrusCamera = if ($cirrusScene -eq 'mixed') { 'formations' } else { 'vortex' }
        $cirrusView = @('--formations',$cirrusScene,'--camera',$cirrusCamera)
        Invoke-CloudCapture $cirrusEngine ($cirrusCommon + $cirrusView + @('--capture',"captures/research/$cirrusScene-after.png"))
        Invoke-CloudCapture $cirrusEngine ($cirrusCommon + $cirrusView + @('--capture',"captures/research/$cirrusScene-full.png",'--cloud-buffer','full','--no-checkerboard'))
        if ($ReferenceExecutable) {
            Invoke-CloudCapture $ReferenceExecutable ($cirrusCommon + $cirrusView + @('--capture',"captures/research/$cirrusScene-before.png"))
        }
    }
    Invoke-CloudCapture $cirrusEngine ($cirrusCommon + @('--formations','mixed','--camera','formations','--sun-elevation','5','--capture','captures/research/mixed-sunset.png'))
    $cirrusNone = @('--headless','--no-ui','--width','1600','--height','900','--quality','high','--frames','48','--weather','overcast','--formations','none','--camera','formations','--debug-layer')
    Invoke-CloudCapture $cirrusEngine ($cirrusNone + @('--capture','captures/research/none-after.png'))
    if ($ReferenceExecutable) {
        Invoke-CloudCapture $ReferenceExecutable ($cirrusNone + @('--capture','captures/research/none-before.png'))
    }
    if (-not $SkipMotion) {
        $cirrusMotion = @('--headless','--no-ui','--width','960','--height','540','--quality','high','--frames','192','--fixed-dt','0.0416666666666667','--weather','overcast','--formations','vortex','--camera','vortex','--formation-speed','2','--debug-layer')
        Invoke-CloudCapture $cirrusEngine ($cirrusMotion + @('--record','captures/research/motion-checker'))
        Invoke-CloudCapture $cirrusEngine ($cirrusMotion + @('--record','captures/research/motion-reference','--no-checkerboard'))
    }
    Write-Host 'Cloud research captures saved in captures/research.'
} finally { Pop-Location }
