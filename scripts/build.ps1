param([ValidateSet('Release','Debug')][string]$Configuration='Release',[switch]$Test)
$ErrorActionPreference='Stop'
$cirrusRoot=Split-Path $PSScriptRoot -Parent
Push-Location $cirrusRoot
try {
    & cmake --preset windows
    if($LASTEXITCODE -ne 0) {throw 'CMake configuration failed'}
    & cmake --build build --config $Configuration --parallel
    if($LASTEXITCODE -ne 0) {throw 'C++ build failed'}
    if($Test) {
        & ctest --test-dir build -C $Configuration --output-on-failure
        if($LASTEXITCODE -ne 0) {throw 'Tests failed'}
    }
} finally {Pop-Location}
