param([string]$ReferenceShaders = '', [switch]$SkipMotion)
$ErrorActionPreference = 'Stop'
$cirrusRoot = Split-Path $PSScriptRoot -Parent
$cirrusEngine = Join-Path $cirrusRoot 'build\Release\CirrusEngine.exe'
if (-not (Test-Path -LiteralPath $cirrusEngine)) { throw 'Build the Release preset first.' }
if ($ReferenceShaders) { $ReferenceShaders = (Resolve-Path -LiteralPath $ReferenceShaders).Path }
function Invoke-CloudVolume([string[]]$Arguments) {
    $cirrusProcess = Start-Process -FilePath $cirrusEngine -WorkingDirectory $cirrusRoot -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($cirrusProcess.ExitCode -ne 0) { throw "Cloud capture failed; see logs/cirrus.log: $($Arguments -join ' ')" }
}
Push-Location $cirrusRoot
try {
    New-Item -ItemType Directory -Path 'captures\cloud-volume' -Force | Out-Null
    $cirrusCommon = @('--headless','--no-ui','--width','1600','--height','900','--quality','high','--frames','60','--weather','overcast','--debug-layer')
    $cirrusCases = @(
        @{name='far';args=@('--formations','towers','--camera','formations')},
        @{name='close';args=@('--formations','towers','--camera','tower-close')},
        @{name='frontlit';args=@('--formations','towers','--camera','tower-close','--sun-azimuth','150')},
        @{name='side';args=@('--formations','towers','--camera','tower-side')},
        @{name='inside';args=@('--formations','towers','--camera','tower-inside')},
        @{name='mixed';args=@('--formations','mixed','--camera','formations')},
        @{name='vortex';args=@('--formations','vortex','--camera','vortex')},
        @{name='none';args=@('--formations','none','--camera','formations')}
    )
    foreach ($cirrusCase in $cirrusCases) {
        $cirrusView = $cirrusCommon + $cirrusCase.args
        Invoke-CloudVolume ($cirrusView + @('--capture',"captures/cloud-volume/$($cirrusCase.name)-after.png"))
        if ($ReferenceShaders) {
            # 同じ実行ファイル・カメラ・設定で旧HLSLだけを使う。定数バッファ互換の版を指定する。
            Invoke-CloudVolume ($cirrusView + @('--shader-dir',('"'+$ReferenceShaders+'"'),'--capture',"captures/cloud-volume/$($cirrusCase.name)-before.png"))
        }
        if ($cirrusCase.name -in @('close','frontlit')) {
            Invoke-CloudVolume ($cirrusView + @('--cloud-buffer','full','--no-checkerboard','--capture',"captures/cloud-volume/$($cirrusCase.name)-full.png"))
        }
    }
    if (-not $SkipMotion) {
        $cirrusMotion = @('--headless','--no-ui','--width','960','--height','540','--quality','high','--frames','192','--fixed-dt','0.0416666666666667','--formations','mixed','--weather','overcast','--sun-azimuth','150','--camera','tower-close','--camera-path','tower-orbit','--debug-layer')
        Invoke-CloudVolume ($cirrusMotion + @('--record','captures/cloud-volume/orbit-checker'))
        Invoke-CloudVolume ($cirrusMotion + @('--record','captures/cloud-volume/orbit-reference','--no-checkerboard'))
    }
    Write-Host '3D cloud comparison captures saved in captures/cloud-volume.'
} finally { Pop-Location }
