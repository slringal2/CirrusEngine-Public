#include "renderer.hpp"
#include <shellapi.h>
#include <windowsx.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <exception>
#include <fstream>
#include <iomanip>
#include <numeric>
#include <sstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
cirrus::Renderer *renderer = nullptr;
bool dragging = false, leftDown = false, minimized = false;
POINT lastPointer{};
std::exception_ptr callbackError;

std::string ascii(const std::wstring &value)
{
    std::string result;
    result.reserve(value.size());
    for (wchar_t c : value)
    {
        if (c > 127)
            throw std::runtime_error("Option names and enum values must use ASCII");
        result.push_back(static_cast<char>(c));
    }
    return result;
}

cirrus::Options arguments()
{
    cirrus::Options o;
    bool manualSun = false, customSpawn = false, dayLengthSet = false;
    int count = 0;
    LPWSTR *raw = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!raw)
        throw std::runtime_error("Cannot parse command line");
    std::vector<std::wstring> args(raw, raw + count);
    LocalFree(raw);
    wchar_t exe[32768];
    GetModuleFileNameW(nullptr, exe, 32768);
    o.shaderDirectory = std::filesystem::path(exe).parent_path() / L"shaders";
    for (int i = 1; i < count; i++)
    {
        const auto &a = args[i];
        auto next = [&]()
        {
            if (i + 1 >= count)
                throw std::runtime_error("Missing command-line value");
            return args[++i];
        };
        if (a == L"--width")
            o.width = std::stoi(next());
        else if (a == L"--height")
            o.height = std::stoi(next());
        else if (a == L"--frames")
            o.frames = std::stoi(next());
        else if (a == L"--fixed-dt")
            o.fixedDt = std::stod(next());
        else if (a == L"--benchmark-seconds")
            o.benchmarkSeconds = std::stod(next());
        else if (a == L"--benchmark-output")
            o.benchmarkOutput = next();
        else if (a == L"--capture")
            o.capture = next();
        else if (a == L"--record")
            o.recordDirectory = next();
        else if (a == L"--weather-demo")
            o.weatherDemo = true;
        else if (a == L"--lightning-at")
            o.lightningAt = std::stod(next());
        else if (a == L"--no-rain")
            o.rain = false;
        else if (a == L"--no-lightning")
            o.lightning = false;
        else if (a == L"--full-cloud-lighting")
            o.fullCloudLighting = true;
        else if (a == L"--no-checkerboard")
            o.checkerboard = false;
        else if (a == L"--formations")
        {
            o.formationMode = ascii(next());
            cirrus::formationPreset(o.formationMode);
        }
        else if (a == L"--formation-file")
            o.formationFile = next();
        else if (a == L"--formation-strength")
            o.formationStrength = std::stof(next());
        else if (a == L"--formation-scale")
            o.formationScale = std::stof(next());
        else if (a == L"--formation-speed")
            o.formationSpeed = std::stof(next());
        else if (a == L"--cloud-buffer")
        {
            const auto size = next();
            if (size == L"auto")
                o.cloudDivisor = 0;
            else if (size == L"full")
                o.cloudDivisor = 1;
            else if (size == L"half")
                o.cloudDivisor = 2;
            else if (size == L"quarter")
                o.cloudDivisor = 4;
            else
                throw std::runtime_error("Cloud buffer must be auto, full, half or quarter");
        }
        else if (a == L"--shader-dir")
            o.shaderDirectory = next();
        else if (a == L"--camera")
            o.camera = ascii(next());
        else if (a == L"--camera-path")
        {
            o.cameraPath = ascii(next());
            if (o.cameraPath != "pan" && o.cameraPath != "cut" && o.cameraPath != "tower-orbit"
                && o.cameraPath != "walk")
                throw std::runtime_error("Camera path must be pan, cut, tower-orbit or walk");
        }
        else if (a == L"--sun-elevation")
        {
            o.elevation = std::stof(next());
            manualSun = true;
        }
        else if (a == L"--sun-azimuth")
        {
            o.azimuth = std::stof(next());
            manualSun = true;
        }
        else if (a == L"--time")
        {
            o.timeOfDay = std::stof(next());
            if (!std::isfinite(o.timeOfDay) || o.timeOfDay < 0 || o.timeOfDay >= 24)
                throw std::runtime_error("Time must be in [0,24) solar hours");
        }
        else if (a == L"--day-seconds")
        {
            o.daySeconds = std::stod(next());
            dayLengthSet = true;
        }
        else if (a == L"--spawn")
        {
            o.spawnX = std::stof(next());
            o.spawnZ = std::stof(next());
            customSpawn = true;
        }
        else if (a == L"--model")
            o.modelPath = next();
        else if (a == L"--model-scale")
            o.modelScale = std::stof(next());
        else if (a == L"--no-vegetation")
            o.vegetation = false;
        else if (a == L"--exposure")
            o.exposure = std::stof(next());
        else if (a == L"--weather")
            o.weather = cirrus::parseWeather(ascii(next()));
        else if (a == L"--transition")
            o.transition = static_cast<int>(cirrus::parseWeather(ascii(next())));
        else if (a == L"--transition-seconds")
            o.transitionSeconds = std::stod(next());
        else if (a == L"--quality")
        {
            auto q = next();
            if (q == L"low")
                o.quality = cirrus::Quality::Low;
            else if (q == L"medium")
                o.quality = cirrus::Quality::Medium;
            else if (q == L"high")
                o.quality = cirrus::Quality::High;
            else if (q == L"ultra")
                o.quality = cirrus::Quality::Ultra;
            else
                throw std::runtime_error("Quality must be low, medium, high or ultra");
        }
        else if (a == L"--debug-view")
            o.debugView = std::stoi(next());
        else if (a == L"--texture-viewer")
            o.textureViewer = true;
        else if (a == L"--texture-slice")
            o.textureSlice = std::stof(next());
        else if (a == L"--texture-axis")
        {
            auto axis = next();
            if (axis == L"x")
                o.textureAxis = 0;
            else if (axis == L"y")
                o.textureAxis = 1;
            else if (axis == L"z")
                o.textureAxis = 2;
            else
                throw std::runtime_error("Texture axis must be x, y or z");
        }
        else if (a == L"--headless")
            o.headless = true;
        else if (a == L"--warp")
            o.warp = true;
        else if (a == L"--check-shaders")
        {
            o.checkShaders = true;
            o.headless = true;
        }
        else if (a == L"--debug-layer")
            o.debugLayer = true;
        else if (a == L"--no-ui")
            o.ui = false;
        else if (a == L"--no-clouds")
            o.clouds = false;
        else if (a == L"--no-cloud-shadows")
            o.shadows = false;
        else if (a == L"--auto-weather")
            o.automatic = true;
        else if (a == L"--no-vsync")
            o.vsync = false;
        else
            throw std::runtime_error("Unknown option: " + ascii(a));
    }
    if (o.width < 160 || o.width > 7680 || o.height < 90 || o.height > 4320 || o.frames < 1
        || o.frames > 1000000)
        throw std::runtime_error("Invalid resolution or capture frame count");
    if (!std::isfinite(o.transitionSeconds) || o.transitionSeconds < 0 || o.transitionSeconds > 3600
        || !std::isfinite(o.fixedDt) || o.fixedDt < 0 || o.fixedDt > 1
        || !std::isfinite(o.elevation) || o.elevation < -14 || o.elevation > 85
        || !std::isfinite(o.azimuth) || o.azimuth < -180 || o.azimuth > 180
        || !std::isfinite(o.exposure) || o.exposure < 0.05f || o.exposure > 10)
        throw std::runtime_error("Invalid time step, sun, exposure or debug view");
    if (o.debugView < 0 || o.debugView >= static_cast<int>(cirrus::DebugView::Count))
        throw std::runtime_error("Unknown texture debug view");
    if (!std::isfinite(o.formationStrength) || o.formationStrength < 0 || o.formationStrength > 2
        || !std::isfinite(o.formationScale) || o.formationScale < 0.5f || o.formationScale > 1.6f
        || !std::isfinite(o.formationSpeed) || o.formationSpeed < -3 || o.formationSpeed > 3)
        throw std::runtime_error(
            "Invalid formation strength [0,2], scale [0.5,1.6] or speed [-3,3]");
    if (!std::isfinite(o.textureSlice) || o.textureSlice < 0 || o.textureSlice > 1)
        throw std::runtime_error("Texture slice must be between 0 and 1");
    if (!std::isfinite(o.spawnX) || !std::isfinite(o.spawnZ)
        || std::abs(o.spawnX) > cirrus::worldLimit || std::abs(o.spawnZ) > cirrus::worldLimit
        || !std::isfinite(o.daySeconds) || o.daySeconds < 0
        || (o.daySeconds > 0 && o.daySeconds < 1) || !std::isfinite(o.modelScale)
        || o.modelScale <= 0)
        throw std::runtime_error("Invalid world position, day length or model scale");
    if (manualSun && (o.timeOfDay >= 0 || dayLengthSet))
        throw std::runtime_error("Choose a solar time or manual sun angles");
    if (o.camera.empty())
    {
        bool typicalLaunch = !o.headless && o.capture.empty() && o.recordDirectory.empty()
                             && o.cameraPath.empty() && o.formationMode == "none"
                             && o.formationFile.empty() && !o.weatherDemo
                             && o.benchmarkSeconds == 0;
        o.camera = typicalLaunch || customSpawn || !o.modelPath.empty() || o.cameraPath == "walk"
                       ? "walk"
                       : "valley";
    }
    if ((customSpawn || o.cameraPath == "walk") && o.camera != "walk")
        throw std::runtime_error("A world spawn and the walking path require --camera walk");
    if (o.camera == "walk" && !o.cameraPath.empty() && o.cameraPath != "walk")
        throw std::runtime_error("Exploration supports --camera-path walk");
    o.openWorld = o.camera == "walk" || !o.modelPath.empty();
    if ((o.openWorld || dayLengthSet) && o.timeOfDay < 0 && !manualSun)
        o.timeOfDay = 16.4f;
    if (o.timeOfDay >= 0 && !dayLengthSet && !o.headless && o.capture.empty()
        && o.recordDirectory.empty())
        o.daySeconds = 720;
    if (o.camera != "walk" && o.camera != "valley" && o.camera != "clouds" && o.camera != "overview"
        && o.camera != "inside" && o.camera != "shadows" && o.camera != "formations"
        && o.camera != "vortex" && o.camera != "tower-close" && o.camera != "tower-side"
        && o.camera != "tower-inside")
        throw std::runtime_error(
            "Unknown camera. Use walk, valley, clouds, overview, inside, shadows, "
            "formations, vortex, tower-close, tower-side or tower-inside");
    if (!o.recordDirectory.empty() && !o.capture.empty())
        throw std::runtime_error("Choose --capture or --record");
    if (!std::isfinite(o.lightningAt) || (o.lightningAt < 0 && o.lightningAt != -1)
        || o.lightningAt > 3600)
        throw std::runtime_error("Invalid lightning trigger time");
    if (o.fixedDt == 0 && (!o.capture.empty() || !o.recordDirectory.empty()))
        o.fixedDt = o.recordDirectory.empty() ? 1.0 / 60.0 : 1.0 / 24.0;
    if (o.headless && o.capture.empty() && o.recordDirectory.empty() && !o.checkShaders)
        throw std::runtime_error("--headless requires --capture, --record or --check-shaders");
    if (!std::isfinite(o.benchmarkSeconds) || o.benchmarkSeconds < 0 || o.benchmarkSeconds > 600
        || (o.benchmarkSeconds > 0
            && (o.headless || !o.capture.empty() || !o.recordDirectory.empty())))
        throw std::runtime_error(
            "Windowed benchmark requires 0 < seconds <= 600 and no capture/headless flag");
    return o;
}

void saveBenchmark(const cirrus::Options &options, const std::string &adapter,
                   const std::vector<double> &times)
{
    auto sorted = times;
    std::sort(sorted.begin(), sorted.end());
    const double seconds = std::accumulate(times.begin(), times.end(), 0.0);
    auto percentile = [&](double p)
    {
        return sorted[std::min(sorted.size() - 1,
                               static_cast<size_t>(std::ceil(p * sorted.size()) - 1))]
               * 1000;
    };
    const char *quality[] = {"Low", "Medium", "High", "Ultra"};
    if (!options.benchmarkOutput.parent_path().empty())
        std::filesystem::create_directories(options.benchmarkOutput.parent_path());
    std::ofstream file(options.benchmarkOutput);
    file << std::fixed << std::setprecision(6);
    file << "{\n  \"adapter\": \"" << adapter << "\",\n  \"width\": " << options.width
         << ", \"height\": " << options.height << ",\n";
    file << "  \"quality\": \"" << quality[static_cast<int>(options.quality)]
         << "\", \"vsync\": " << (options.vsync ? "true" : "false") << ",\n";
    file << "  \"checkerboard\": " << (options.checkerboard ? "true" : "false")
         << ", \"cloud_buffer_divisor\": " << options.cloudDivisor << ", \"camera_path\": \""
         << options.cameraPath << "\",\n";
    file << "  \"formations\": \""
         << (options.formationFile.empty() ? options.formationMode : "custom")
         << "\", \"formation_strength\": " << options.formationStrength
         << ", \"formation_scale\": " << options.formationScale << ",\n";
    file << "  \"warmup_frames\": 120, \"measured_frames\": " << times.size()
         << ",\n  \"duration_seconds\": " << seconds << ",\n";
    file << "  \"average_fps\": " << times.size() / seconds
         << ", \"mean_frame_ms\": " << seconds * 1000 / times.size() << ",\n";
    file << "  \"p95_frame_ms\": " << percentile(0.95) << ", \"p99_frame_ms\": " << percentile(0.99)
         << ",\n";
    file << "  \"measurement\": \"Windowed wall time including message pump, rendering and "
            "Present; excludes startup, 120 warmup frames and PNG capture\"\n}\n";
    if (!file)
        throw std::runtime_error("Cannot write benchmark output");
    cirrus::log("Windowed benchmark: " + std::to_string(times.size() / seconds) + " FPS; saved "
                + options.benchmarkOutput.string());
}

LRESULT CALLBACK windowProcedure(HWND w, UINT message, WPARAM wp, LPARAM lp)
{
    try
    {
        switch (message)
        {
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_SIZE:
            minimized = wp == SIZE_MINIMIZED;
            if (renderer && !minimized)
                renderer->resize(LOWORD(lp), HIWORD(lp));
            return 0;
        case WM_KEYDOWN:
            if (wp == VK_ESCAPE)
                DestroyWindow(w);
            else if (renderer && !(lp & (1LL << 30)))
                renderer->key(static_cast<UINT>(wp));
            return 0;
        case WM_RBUTTONDOWN:
            dragging = true;
            lastPointer = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            SetCapture(w);
            return 0;
        case WM_RBUTTONUP:
            dragging = false;
            if (!leftDown)
                ReleaseCapture();
            return 0;
        case WM_LBUTTONDOWN:
            leftDown = true;
            SetCapture(w);
            if (renderer)
                renderer->pointer(GET_X_LPARAM(lp), GET_Y_LPARAM(lp), true, true);
            return 0;
        case WM_LBUTTONUP:
            leftDown = false;
            if (!dragging)
                ReleaseCapture();
            if (renderer)
                renderer->pointer(GET_X_LPARAM(lp), GET_Y_LPARAM(lp), false, false);
            return 0;
        case WM_MOUSEMOVE:
        {
            POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            if (renderer)
            {
                if (dragging)
                    renderer->look(static_cast<float>(p.x - lastPointer.x),
                                   static_cast<float>(p.y - lastPointer.y));
                renderer->pointer(p.x, p.y, leftDown, false);
            }
            lastPointer = p;
            return 0;
        }
        case WM_KILLFOCUS:
            dragging = leftDown = false;
            ReleaseCapture();
            if (renderer)
                renderer->pointer(0, 0, false, false);
            return 0;
        }
        return DefWindowProcW(w, message, wp, lp);
    }
    catch (...)
    {
        callbackError = std::current_exception();
        PostQuitMessage(1);
        return 0;
    }
}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR, int show)
{
    HANDLE inheritedOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    // Keep MSBuild/CTest's inherited output pipe so shader diagnostics reach the IDE.
    if ((!inheritedOutput || inheritedOutput == INVALID_HANDLE_VALUE)
        && AttachConsole(ATTACH_PARENT_PROCESS))
    {
        FILE *f = nullptr;
        freopen_s(&f, "CONOUT$", "w", stdout);
        freopen_s(&f, "CONOUT$", "w", stderr);
    }
    bool quiet = false;
    HWND window = nullptr;
    HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    try
    {
        cirrus::require(apartment, "COM initialize");
        auto options = arguments();
        quiet = options.headless;
        cirrus::log("CirrusEngine 0.2.0 / C++20 / Direct3D 11");
        SetProcessDPIAware();
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = windowProcedure;
        wc.hInstance = instance;
        wc.lpszClassName = L"CirrusAtmosphereWindow";
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        if (!RegisterClassExW(&wc))
            throw std::runtime_error("Cannot register window");
        RECT rect{0, 0, options.width, options.height};
        AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
        window = CreateWindowExW(0, wc.lpszClassName, L"CirrusEngine | Volumetric Atmosphere",
                                 WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                                 rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr,
                                 instance, nullptr);
        if (!window)
            throw std::runtime_error("Cannot create rendering window");
        auto engine = std::make_unique<cirrus::Renderer>(window, options);
        renderer = engine.get();
        if (options.checkShaders)
        {
            engine->finishValidation();
            renderer = nullptr;
            engine.reset();
            DestroyWindow(window);
            CoUninitialize();
            return 0;
        }
        if (!options.headless)
            ShowWindow(window, show);
        auto last = std::chrono::steady_clock::now();
        int rendered = 0;
        bool running = true;
        std::vector<double> benchmarkTimes;
        double benchmarkElapsed = 0;
        std::ofstream weatherTimeline;
        if (!options.recordDirectory.empty())
        {
            std::filesystem::create_directories(options.recordDirectory);
            weatherTimeline.open(options.recordDirectory / "timeline.csv");
            if (!weatherTimeline)
                throw std::runtime_error("Cannot open weather timeline");
            weatherTimeline << "frame,seconds,demo_seconds,target,rain,wetness,lightning,serial,"
                               "wind_x,wind_z\n";
        }
        // Windowsメッセージを処理してから、天候更新と描画を1フレーム進める。
        while (running)
        {
            auto loopBegin = std::chrono::steady_clock::now();
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE))
            {
                if (message.message == WM_QUIT)
                {
                    running = false;
                    break;
                }
                TranslateMessage(&message);
                DispatchMessageW(&message);
                if (callbackError)
                    std::rethrow_exception(callbackError);
            }
            if (!running)
                break;
            if (minimized)
            {
                WaitMessage();
                last = std::chrono::steady_clock::now();
                continue;
            }
            auto now = std::chrono::steady_clock::now();
            double dt = std::chrono::duration<double>(now - last).count();
            last = now;
            // キャプチャ時は固定dtで再現性を確保し、通常時は実際の経過時間を使う。
            dt = options.fixedDt > 0 ? options.fixedDt : std::min(dt, 0.1);
            engine->frame(dt, GetForegroundWindow() == window);
            ++rendered;
            // 初期120フレームを除き、メッセージ処理からPresentまでの実時間を測る。
            if (options.benchmarkSeconds > 0 && rendered > 120)
            {
                double interval =
                    std::chrono::duration<double>(std::chrono::steady_clock::now() - loopBegin)
                        .count();
                benchmarkTimes.push_back(interval);
                benchmarkElapsed += interval;
                if (benchmarkElapsed >= options.benchmarkSeconds)
                {
                    saveBenchmark(options, engine->adapter(), benchmarkTimes);
                    running = false;
                }
            }
            if (engine->wantsCapture())
                engine->capture(std::filesystem::path("captures")
                                / ("cirrus_" + std::to_string(GetTickCount64()) + ".png"));
            if (!options.recordDirectory.empty())
            {
                std::ostringstream frameName;
                frameName << std::setfill('0') << std::setw(6) << rendered - 1 << ".png";
                engine->capture(options.recordDirectory / frameName.str(),
                                rendered >= options.frames);
                engine->recordWeather(weatherTimeline, rendered - 1);
                if (rendered >= options.frames)
                    running = false;
            }
            if (!options.capture.empty() && rendered >= options.frames)
            {
                engine->capture(options.capture);
                running = false;
            }
        }
        engine->finishValidation();
        renderer = nullptr;
        engine.reset();
        if (IsWindow(window))
            DestroyWindow(window);
        CoUninitialize();
        return 0;
    }
    catch (const std::exception &error)
    {
        renderer = nullptr;
        cirrus::log(std::string("ERROR: ") + error.what());
        if (!quiet)
            MessageBoxA(window, error.what(), "CirrusEngine error", MB_OK | MB_ICONERROR);
        if (window && IsWindow(window))
            DestroyWindow(window);
        if (SUCCEEDED(apartment))
            CoUninitialize();
        return 1;
    }
}
