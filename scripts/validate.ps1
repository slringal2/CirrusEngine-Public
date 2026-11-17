param([string]$Configuration = 'Release', [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$cirrusRoot = Split-Path $PSScriptRoot -Parent
Push-Location $cirrusRoot
try {
    if (-not $SkipBuild) {
        & cmake --preset windows
        if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed' }
        & cmake --build build --config $Configuration --parallel
        if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    }
    & ctest --test-dir build -C $Configuration --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'CPU / HLSL checks failed' }
    $cirrusOutput = Join-Path $cirrusRoot 'captures\validation'
    New-Item -ItemType Directory -Path $cirrusOutput -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cirrusOutput 'zero-density.clouds') -Value 'vortex 6400 12000 7000 900 4400 0 2 1.6' -Encoding ASCII
    $cirrusCases = @(
        @{name='day';args=@()},
        @{name='clear';args=@('--weather','clear')},
        @{name='overcast';args=@('--weather','overcast')},
        @{name='rain';args=@('--weather','rain')},
        @{name='storm';args=@('--weather','storm')},
        @{name='sunset';args=@('--sun-elevation','5','--sun-azimuth','-12')},
        @{name='night';args=@('--sun-elevation','-10')},
        @{name='overview';args=@('--camera','overview')},
        @{name='inside';args=@('--camera','inside')},
        @{name='shadows-on';args=@('--camera','shadows')},
        @{name='shadows-off';args=@('--camera','shadows','--no-cloud-shadows')},
        @{name='wind-later';args=@('--fixed-dt','1','--frames','120')},
        @{name='transition-mid';args=@('--weather','clear','--transition','storm','--transition-seconds','2','--frames','60')},
        @{name='transition-end';args=@('--weather','clear','--transition','storm','--transition-seconds','2','--frames','132')},
        @{name='lightning';args=@('--weather','storm','--fixed-dt','0.25','--frames','48','--lightning-at','12')},
        @{name='lightning-off';args=@('--weather','storm','--fixed-dt','0.25','--frames','48','--lightning-at','12','--no-lightning')},
        @{name='night-lightning';args=@('--weather','storm','--sun-elevation','-10','--lightning-at','0.8')},
        @{name='rain-off';args=@('--weather','rain','--no-rain')},
        @{name='rain-particles';args=@('--weather','rain','--debug-view','22')},
        @{name='rain-above-clouds';args=@('--weather','rain','--camera','overview')},
        @{name='rain-low';args=@('--weather','rain','--width','1001','--height','563','--quality','low')},
        @{name='demo-storm';args=@('--weather','clear','--weather-demo','--fixed-dt','0.5','--frames','64')},
        @{name='demo-clearing';args=@('--weather','clear','--weather-demo','--fixed-dt','0.5','--frames','96')},
        @{name='odd-low';args=@('--width','1001','--height','563','--quality','low')},
        @{name='ultra';args=@('--width','1001','--height','563','--quality','ultra')},
        @{name='hud';args=@()},
        @{name='perlin-worley';args=@('--debug-view','7')},
        @{name='worley-detail';args=@('--debug-view','8')},
        @{name='full-lighting';args=@('--full-cloud-lighting')},
        @{name='checker-off';args=@('--no-checkerboard')},
        @{name='cloud-full';args=@('--cloud-buffer','full','--width','1001','--height','563','--quality','low')},
        @{name='cloud-half';args=@('--cloud-buffer','half','--width','1001','--height','563','--quality','ultra')},
        @{name='cloud-quarter';args=@('--cloud-buffer','quarter','--width','1001','--height','563')},
        @{name='checker-pan';args=@('--camera-path','pan','--fixed-dt','0.033333333333','--frames','120')},
        @{name='checker-cut';args=@('--camera-path','cut','--frames','120')},
        @{name='checker-after-cut';args=@('--camera-path','cut','--frames','121')},
        @{name='checker-mask';args=@('--debug-view','23')},
        @{name='cloud-placement';args=@('--weather','partly','--debug-view','26')},
        @{name='cloud-shadow-depth';args=@('--weather','partly','--debug-view','28')},
        @{name='formation-none';args=@('--formations','none','--camera','formations','--weather','overcast')},
        @{name='formation-towers';args=@('--formations','towers','--camera','formations','--weather','overcast')},
        @{name='formation-vortex';args=@('--formations','vortex','--camera','vortex','--weather','overcast')},
        @{name='formation-mixed';args=@('--formations','mixed','--camera','formations','--weather','overcast')},
        @{name='formation-custom';args=@('--formation-file','config/formations.clouds','--camera','formations','--weather','overcast')},
        @{name='formation-zero';args=@('--formations','mixed','--formation-strength','0','--camera','formations','--weather','overcast')},
        @{name='formation-density-zero';args=@('--formation-file','captures/validation/zero-density.clouds','--camera','formations','--weather','overcast')},
        @{name='formation-large';args=@('--formations','mixed','--formation-scale','1.6','--camera','formations','--weather','overcast')},
        @{name='formation-reverse';args=@('--formations','vortex','--formation-speed','-2','--camera','vortex','--weather','overcast')},
        @{name='formation-reference';args=@('--formations','mixed','--no-checkerboard','--camera','formations','--weather','overcast')},
        @{name='tower-close';args=@('--formations','towers','--camera','tower-close','--weather','overcast')},
        @{name='tower-side';args=@('--formations','towers','--camera','tower-side','--weather','overcast')},
        @{name='tower-inside';args=@('--formations','towers','--camera','tower-inside','--weather','overcast')},
        @{name='tower-close-full';args=@('--formations','towers','--camera','tower-close','--weather','overcast','--cloud-buffer','full','--no-checkerboard')},
        @{name='tower-frontlit';args=@('--formations','towers','--camera','tower-close','--weather','overcast','--sun-azimuth','150')},
        @{name='tower-sunset';args=@('--formations','mixed','--camera','formations','--weather','overcast','--sun-elevation','5')},
        @{name='tower-control-x';args=@('--debug-view','24','--texture-axis','x','--texture-slice','0.5','--no-clouds')},
        @{name='tower-control-y';args=@('--debug-view','24','--texture-axis','y','--texture-slice','0.5','--no-clouds')},
        @{name='tower-control-z';args=@('--debug-view','24','--texture-axis','z','--texture-slice','0.5','--no-clouds')},
        @{name='tower-warp-x';args=@('--debug-view','25','--texture-axis','x','--texture-slice','0.5','--no-clouds')},
        @{name='tower-warp-y';args=@('--debug-view','25','--texture-axis','y','--texture-slice','0.5','--no-clouds')},
        @{name='tower-warp-z';args=@('--debug-view','25','--texture-axis','z','--texture-slice','0.5','--no-clouds')},
        @{name='tower-orbit';args=@('--formations','mixed','--camera','tower-close','--camera-path','tower-orbit','--weather','overcast','--fixed-dt','0.033333333333','--frames','120')},
        @{name='formation-off';args=@('--formations','mixed','--no-clouds')},
        @{name='clouds-off';args=@('--no-clouds')},
        @{name='world-day';args=@('--camera','walk','--time','16.4')},
        @{name='world-night';args=@('--camera','walk','--time','0.5')},
        @{name='world-day-wrap';args=@('--camera','walk','--time','23','--day-seconds','8','--fixed-dt','0.06','--frames','40')},
        @{name='walk-before';args=@('--camera-path','walk','--spawn','10','123','--frames','12')},
        @{name='walk-crossing';args=@('--camera-path','walk','--spawn','10','123','--frames','90','--fixed-dt','0.10')},
        @{name='world-distant';args=@('--camera','walk','--spawn','250000','180000','--time','15')},
        @{name='river-mask';args=@('--camera','walk','--time','16.4','--debug-view','31')},
        @{name='river-mask-distant';args=@('--camera','walk','--spawn','250000','180000','--debug-view','31','--no-vegetation')},
        @{name='river-walk';args=@('--camera-path','walk','--spawn','12','-16','--look','90','-10','--frames','75','--fixed-dt','0.10')},
        @{name='river-spawn';args=@('--spawn','35','-16','--look','79','-11','--no-vegetation')},
        @{name='pbr-metallic';args=@('--model','tests/pbr-panel.gltf','--time','15','--debug-view','29')},
        @{name='pbr-roughness';args=@('--model','tests/pbr-panel.gltf','--time','15','--debug-view','21')}
    )
    $cirrusReports = @{}
    foreach ($cirrusCase in $cirrusCases) {
        $cirrusFile = Join-Path $cirrusOutput ($cirrusCase.name+'.png')
        $cirrusArgs = @('--headless','--capture',('"'+$cirrusFile+'"'),'--width','1600','--height','900','--quality','high','--frames','48','--debug-layer')
        if ($cirrusCase.name -ne 'hud') { $cirrusArgs += '--no-ui' }
        $cirrusArgs += $cirrusCase.args
        $cirrusProcess = Start-Process -FilePath (Join-Path $cirrusRoot "build\$Configuration\CirrusEngine.exe") -ArgumentList $cirrusArgs -WindowStyle Hidden -PassThru -Wait
        if ($cirrusProcess.ExitCode -ne 0) { throw ('GPU case failed: '+$cirrusCase.name+'; see logs/cirrus.log') }
        $cirrusReport = Get-Content ([IO.Path]::ChangeExtension($cirrusFile,'.json')) -Raw | ConvertFrom-Json
        if ($cirrusReport.nonfinite_samples -ne 0) { throw ('Non-finite GPU values: '+$cirrusCase.name) }
        if ($cirrusReport.cloud_transmittance.min -lt 0 -or $cirrusReport.cloud_transmittance.max -gt 1.0001) { throw 'Invalid cloud transmittance' }
        if ($cirrusReport.gpu_timing_samples -eq 0) { throw ('No GPU timings: '+$cirrusCase.name) }
        $cirrusReconstruction = $cirrusReport.cloud_reconstruction
        $cirrusPixels = $cirrusReconstruction.logical_size[0] * $cirrusReconstruction.logical_size[1]
        if ($cirrusReconstruction.traced_pixels + $cirrusReconstruction.history_pixels + $cirrusReconstruction.analytical_clear_pixels -ne $cirrusPixels) { throw ('Incomplete cloud reconstruction: '+$cirrusCase.name) }
        if ($cirrusReconstruction.active) {
            if ($cirrusReconstruction.raw_allocation[0] -ne [Math]::Ceiling($cirrusReconstruction.logical_size[0]/2.0)) { throw 'Checkerboard raw buffer was not packed' }
            $cirrusParityCount = [Math]::Floor($cirrusPixels/2.0)
            if ($cirrusReconstruction.parity -eq 0) { $cirrusParityCount = [Math]::Ceiling($cirrusPixels/2.0) }
            if ($cirrusReconstruction.traced_pixels - $cirrusReconstruction.repair_pixels -ne $cirrusParityCount) { throw 'Checkerboard parity did not cover exactly half the grid' }
        }
        $cirrusReports[$cirrusCase.name] = $cirrusReport
        Write-Host ('PASS {0,-17} GPU {1,6:N2} ms' -f $cirrusCase.name,$cirrusReport.gpu_frame_ms)
    }
    if ($cirrusReports['shadows-off'].shadow_transmittance.min -lt 0.999) { throw 'Disabled cloud shadow map is not fully lit' }
    if ($cirrusReports['shadows-on'].shadow_transmittance.min -gt 0.9) { throw 'Cloud shadow map has no meaningful shadow' }
    if ($cirrusReports['wind-later'].wind_offset_m[0] -lt 1000) { throw 'Wind advection did not advance' }
    if ([Math]::Abs($cirrusReports['transition-mid'].weather_state.transition_progress-0.5) -gt 0.01) { throw 'Transition midpoint timing is wrong' }
    if ([Math]::Abs($cirrusReports['transition-end'].weather_state.rain-1) -gt 0.001) { throw 'Storm transition did not complete' }
    if ($cirrusReports['rain'].rain_opacity.mean -le 0.00001) { throw 'Rain particles did not draw' }
    if ($cirrusReports['rain-off'].rain_opacity.max -ne 0) { throw 'Disabled rain did not clear the particle buffer' }
    if ($cirrusReports['rain-above-clouds'].rain_opacity.max -ne 0) { throw 'Rain appeared above the cloud base' }
    if ($cirrusReports['lightning'].lightning.strength -lt 0.9 -or $cirrusReports['lightning-off'].lightning.strength -ne 0) { throw 'Lightning toggle did not affect illumination' }
    if ($cirrusReports['demo-storm'].weather_state.rain -lt 0.99) { throw 'Demo did not reach a thunderstorm' }
    if ($cirrusReports['demo-clearing'].weather_state.rain -gt 0.001 -or $cirrusReports['demo-clearing'].weather_effects.wetness -lt 0.3) { throw 'Clearing weather did not preserve wet ground' }
    if ($cirrusReports['day'].cloud_optimization.atmosphere_updates -ne 1) { throw 'Stable atmosphere LUT was not cached' }
    if ($cirrusReports['day'].cloud_optimization.shadow_updates -gt 14 -or -not $cirrusReports['day'].cloud_optimization.lighting_reuse) { throw 'Stable cloud lighting was not reused' }
    if ($cirrusReports['full-lighting'].cloud_optimization.shadow_updates -ne $cirrusReports['full-lighting'].frames -or $cirrusReports['full-lighting'].cloud_optimization.lighting_reuse) { throw 'Full-lighting reference mode did not refresh every frame' }
    if ($cirrusReports['transition-mid'].cloud_optimization.shadow_updates -lt ($cirrusReports['transition-mid'].frames-1) -or $cirrusReports['transition-mid'].cloud_optimization.atmosphere_updates -lt 2) { throw 'Weather transitions did not invalidate the lighting caches' }
    if ($cirrusReports['clouds-off'].shadow_transmittance.min -lt 0.999) { throw 'Disabling clouds did not clear their shadows' }
    $cirrusDay = $cirrusReports['day'].cloud_reconstruction
    if (-not $cirrusDay.active -or $cirrusDay.full_refresh_frames -ne 1 -or $cirrusDay.history_pixels -lt 50000) { throw 'Stable clouds did not reuse their history' }
    if ($cirrusReports['checker-off'].cloud_reconstruction.enabled -or $cirrusReports['checker-off'].cloud_reconstruction.raw_allocation[0] -ne 800) { throw 'Full-grid reference mode is broken' }
    if (-not $cirrusReports['checker-cut'].cloud_reconstruction.full_refresh -or $cirrusReports['checker-cut'].cloud_reconstruction.full_refresh_frames -ne 2) { throw 'Camera cut retained stale cloud history' }
    if (-not $cirrusReports['checker-after-cut'].cloud_reconstruction.active) { throw 'Checkerboard did not resume after the camera cut' }
    if (-not $cirrusReports['lightning'].cloud_reconstruction.full_refresh) { throw 'Lightning did not refresh all cloud pixels' }
    if ($cirrusReports['cloud-full'].cloud_reconstruction.logical_size[0] -ne 1001 -or $cirrusReports['cloud-half'].cloud_reconstruction.logical_size[0] -ne 501 -or $cirrusReports['cloud-quarter'].cloud_reconstruction.logical_size[0] -ne 251) { throw 'Cloud buffer override ignored the requested resolution' }
    if ($cirrusReports['formation-mixed'].formations.count -ne 2 -or $cirrusReports['formation-custom'].formations.count -ne 2 -or $cirrusReports['formation-custom'].formations.mode -ne 'custom') { throw 'Independent cloud regions did not load' }
    if ($cirrusReports['formation-towers'].formations.top_m -lt 10000 -or $cirrusReports['formation-large'].formations.top_m -lt 15000) { throw 'Tall clouds were clipped to the background cloud layer' }
    if ($cirrusReports['formation-zero'].formations.count -ne 0 -or $cirrusReports['formation-zero'].formations.top_m -ne $cirrusReports['formation-none'].formations.top_m) { throw 'Zero strength did not restore the ordinary cloud layer' }
    if ($cirrusReports['formation-reverse'].formations.phase_seconds -ge 0) { throw 'Reverse vortex rotation did not advance backwards' }
    if ($cirrusReports['formation-density-zero'].formations.top_m -ne $cirrusReports['formation-none'].formations.top_m -or $cirrusReports['formation-density-zero'].cloud_transmittance.mean -ne $cirrusReports['formation-none'].cloud_transmittance.mean) { throw 'Zero-density region still affected the cloud sea' }
    if ($cirrusReports['formation-off'].cloud_transmittance.min -lt 0.999 -or $cirrusReports['formation-off'].shadow_transmittance.min -lt 0.999) { throw 'Cloud disable left local formations visible' }
    $cirrusDaylight = $cirrusReports['world-day']
    $cirrusNight = $cirrusReports['world-night']
    if ($cirrusDaylight.world.trees -eq 0 -or $cirrusDaylight.world.grass_tufts -eq 0 -or
        $cirrusDaylight.world.ferns -eq 0 -or $cirrusDaylight.world.bank_rocks -eq 0 -or
        -not $cirrusDaylight.world.near_shadow) {
        throw 'Walkable scene is missing vegetation or its local shadow pass'
    }
    if ($cirrusDaylight.sun_elevation -le 0 -or $cirrusNight.sun_elevation -ge 0 -or $cirrusNight.world.near_shadow) {
        throw 'Solar altitude and shadow state do not distinguish day from night'
    }
    if ([Math]::Abs($cirrusReports['world-day-wrap'].solar_hour - 6.2) -gt 0.002) {
        throw 'Solar time did not advance through midnight'
    }
    $cirrusBeforeWalk = $cirrusReports['walk-before']
    $cirrusAfterWalk = $cirrusReports['walk-crossing']
    if ($cirrusBeforeWalk.camera_position_m[2] -ge 128 -or $cirrusAfterWalk.camera_position_m[2] -lt 150 -or
        $cirrusAfterWalk.world.tiles_built -le $cirrusBeforeWalk.world.tiles_built -or
        [Math]::Abs($cirrusAfterWalk.world.eye_height_m - 1.68) -gt 0.001) {
        throw 'Walking did not cross the streaming boundary at a stable eye height'
    }
    $cirrusDistantWorld = $cirrusReports['world-distant']
    if ($cirrusDistantWorld.world.active_tiles -lt 80 -or $cirrusDistantWorld.cloud_transmittance.min -ge 0.999) {
        throw 'The world or local atmosphere was missing at the distant spawn'
    }
    $cirrusRiverWalk = $cirrusReports['river-walk']
    $cirrusRiverSpawn = $cirrusReports['river-spawn']
    if ($cirrusRiverWalk.camera_position_m[0] -lt 18 -or $cirrusRiverWalk.camera_position_m[0] -gt 25 -or
        $cirrusRiverWalk.world.ground_m -lt 123.0 -or [Math]::Abs($cirrusRiverWalk.world.eye_height_m - 1.68) -gt 0.001) {
        throw 'Walking did not reach and stop in the shallows'
    }
    if ([Math]::Abs($cirrusRiverSpawn.camera_position_m[0] - 35) -lt 5 -or
        $cirrusRiverSpawn.world.ground_m -lt 123.0 -or $cirrusRiverSpawn.world.trees -ne 0 -or
        $cirrusRiverSpawn.world.grass_tufts -ne 0 -or $cirrusRiverSpawn.world.bank_rocks -eq 0) {
        throw 'Spawning in the river did not find a bank, or vegetation disabling affected the rocks'
    }
    Add-Type -AssemblyName System.Drawing
    foreach ($cirrusViewName in @('river-mask','river-mask-distant')) {
        $cirrusWater = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput ($cirrusViewName+'.png')))
        try {
            $cirrusWetPixels = 0
            $cirrusTestedPixels = 0
            for ($cirrusY=4; $cirrusY -lt $cirrusWater.Height; $cirrusY+=8) {
                for ($cirrusX=4; $cirrusX -lt $cirrusWater.Width; $cirrusX+=8) {
                    if ($cirrusWater.GetPixel($cirrusX,$cirrusY).R -gt 200) { $cirrusWetPixels++ }
                    $cirrusTestedPixels++
                }
            }
            $cirrusFraction = $cirrusWetPixels / $cirrusTestedPixels
            if (($cirrusViewName -eq 'river-mask' -and ($cirrusFraction -lt 0.02 -or $cirrusFraction -gt 0.35)) -or
                ($cirrusViewName -eq 'river-mask-distant' -and $cirrusWetPixels -ne 0)) {
                throw "River failed the terrain depth test: $cirrusViewName"
            }
        } finally { $cirrusWater.Dispose() }
    }
    foreach ($cirrusChannel in @('metallic','roughness')) {
        $cirrusMaterialReport = $cirrusReports["pbr-$cirrusChannel"]
        if ($cirrusMaterialReport.world.model_primitives -ne 1) { throw 'The glTF mesh did not load' }
        $cirrusView = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput "pbr-$cirrusChannel.png"))
        try {
            $cirrusLeft = $cirrusView.GetPixel(700,450).R
            $cirrusRight = $cirrusView.GetPixel(900,450).R
            if ($cirrusChannel -eq 'metallic' -and ($cirrusLeft -ne 255 -or $cirrusRight -ne 0)) {
                throw 'glTF metallic texture blue channel was not drawn'
            }
            if ($cirrusChannel -eq 'roughness' -and ($cirrusLeft -ne 60 -or $cirrusRight -ne 204)) {
                throw 'glTF roughness texture green channel was not drawn'
            }
        } finally { $cirrusView.Dispose() }
    }
    $cirrusPlacement = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput 'cloud-placement.png'))
    $cirrusShadowDepth = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput 'cloud-shadow-depth.png'))
    try {
        $cirrusChannelDifference = 0
        $cirrusOccluders = 0
        $cirrusOpenSky = 0
        for ($cirrusY=32; $cirrusY -lt $cirrusPlacement.Height-32; $cirrusY+=16) {
            for ($cirrusX=400; $cirrusX -lt $cirrusPlacement.Width-400; $cirrusX+=16) {
                $cirrusPixel = $cirrusPlacement.GetPixel($cirrusX,$cirrusY)
                if ([Math]::Abs([int]$cirrusPixel.R-[int]$cirrusPixel.G) -gt 12) { ++$cirrusChannelDifference }
                $cirrusDepth = $cirrusShadowDepth.GetPixel($cirrusX,$cirrusY).R
                if ($cirrusDepth -lt 230) { ++$cirrusOccluders }
                if ($cirrusDepth -eq 255) { ++$cirrusOpenSky }
            }
        }
        if ($cirrusChannelDifference -lt 100) { throw 'The two cloud placement channels are missing or identical' }
        if ($cirrusOccluders -lt 100 -or $cirrusOpenSky -lt 100) { throw 'Cloud shadow depth has no occluder or open sky samples' }
    } finally { $cirrusPlacement.Dispose(); $cirrusShadowDepth.Dispose() }
    foreach ($cirrusVolume in @('control','warp')) {
      foreach ($cirrusAxis in @('x','y','z')) {
        $cirrusVolumeView = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput ("tower-$cirrusVolume-$cirrusAxis.png")))
        try {
            $cirrusWhiteSamples = 0
            for ($cirrusY=0; $cirrusY -lt $cirrusVolumeView.Height; $cirrusY+=8) {
                for ($cirrusX=0; $cirrusX -lt $cirrusVolumeView.Width; $cirrusX+=8) {
                    if ($cirrusVolumeView.GetPixel($cirrusX,$cirrusY).R -gt 180) { ++$cirrusWhiteSamples }
                }
            }
            if ($cirrusWhiteSamples -lt 100) { throw "3D $cirrusVolume texture is empty or unbound on axis $cirrusAxis" }
        } finally { $cirrusVolumeView.Dispose() }
      }
    }
    $cirrusOn = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput 'shadows-on.png'))
    $cirrusOff = [System.Drawing.Bitmap]::new((Join-Path $cirrusOutput 'shadows-off.png'))
    try {
        $cirrusDelta = 0.0; $cirrusSigned = 0.0; $cirrusCount = 0
        for ($cirrusY=[int]($cirrusOn.Height*0.55); $cirrusY -lt $cirrusOn.Height; $cirrusY+=8) {
            for ($cirrusX=0; $cirrusX -lt $cirrusOn.Width; $cirrusX+=8) {
                $cirrusA = $cirrusOn.GetPixel($cirrusX,$cirrusY); $cirrusB = $cirrusOff.GetPixel($cirrusX,$cirrusY)
                $cirrusDifference = (0.2126*($cirrusB.R-$cirrusA.R)+0.7152*($cirrusB.G-$cirrusA.G)+0.0722*($cirrusB.B-$cirrusA.B))
                $cirrusSigned += $cirrusDifference; $cirrusDelta += [Math]::Abs($cirrusDifference); $cirrusCount++
            }
        }
        $cirrusDelta /= $cirrusCount; $cirrusSigned /= $cirrusCount
        if ($cirrusDelta -lt 2 -or $cirrusSigned -lt 1) { throw 'Cloud shadows have no visible ground-lighting effect' }
    } finally { $cirrusOn.Dispose(); $cirrusOff.Dispose() }
    $cirrusSummary = [ordered]@{gpu_cases=$cirrusCases.Count;ground_shadow_mean_absolute_delta_255=$cirrusDelta;ground_shadow_mean_darkening_255=$cirrusSigned;reports=$cirrusReports}
    $cirrusSummary | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $cirrusOutput 'summary.json') -Encoding UTF8
    Write-Host ('PASS visible ground cloud shadow: mean difference {0:N2}/255' -f $cirrusDelta)
    Write-Host ('All checks passed. Captures: '+$cirrusOutput)
} finally { Pop-Location }
