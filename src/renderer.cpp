#include "renderer.hpp"
#include <d3dcompiler.h>
#include <d3d11sdklayers.h>
#include <DirectXPackedVector.h>
#include <wincodec.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace cirrus
{
using namespace DirectX;

namespace
{
// Low / Medium / High / Ultra の順。視線と太陽方向の積分回数を別々に制御する。
constexpr std::array<int, 4> samples{160, 224, 384, 640};
constexpr std::array<int, 4> lightSamples{6, 8, 12, 16};
constexpr std::array<int, 4> shadowSizes{256, 512, 768, 1536};
constexpr int cloudOcclusionXZ = 128, cloudOcclusionY = 24;
constexpr float flightStartHeight = 32.0f;
// 視錐台内のセルに照明を共有し、奥行き方向に散乱光と透過率を積み上げる。
constexpr int nearCloudWidth = 80, nearCloudHeight = 44, nearCloudSlices = 32;
constexpr float nearCloudDepth = 160.0f;
constexpr std::array<const char *, 4> qualityNames{"Low", "Medium", "High", "Ultra"};
constexpr std::array<const char *, 7> stageNames{
    "cloud_shadow", "geometry", "sky", "cloud_march", "temporal", "aerial_fog", "composite_ui"};

struct TextureViewInfo
{
    const char *name;
    const char *format;
    const char *description;
    bool volume = false;
};

// DebugViewの列挙順と一致させる。表示名・値の意味は一覧パネルでも確認できる。
constexpr std::array<TextureViewInfo, static_cast<size_t>(DebugView::Count)> textureViews{{
    {"FINAL COMPOSITION", "RGBA8", "Scene lighting, clouds, atmosphere and height fog."},
    {"CLOUD TRANSMITTANCE", "RGBA16F / A", "White: clear. Black: opaque. Temporal result."},
    {"CLOUD SHADOW", "RG16F / R", "Sunlight transmission through the entire cloud layer."},
    {"GBUFFER NORMAL", "RGBA16F / RGB", "World normal encoded from [-1,1] to [0,1]."},
    {"GBUFFER ALBEDO", "RGBA8 / RGB", "Linear surface color, shown with display gamma."},
    {"HEIGHT FOG SCATTER", "RGBA16F / RGB", "Height-fog radiance, shown with exposure."},
    {"REGIONAL WEATHER", "RGBA16F / RGB", "R: coverage. G: moisture. B: cloud type."},
    {"PERLIN-WORLEY R", "RGBA16F / R", "Base cloud shape. Grayscale density before erosion.", true},
    {"DETAIL WORLEY RGB", "RGBA16F / RGB", "Visible bands: 4/8/16 cells. Alpha stores 32 cells.",
     true},
    {"BASE WORLEY GBA", "RGBA16F / GBA", "Cellular noise bands in the base volume.", true},
    {"SCENE DEPTH", "R32F / distance", "Log distance: black is near, white is far."},
    {"TERRAIN SHADOW", "D32 / R32F", "Directional shadow depth. White is the far plane."},
    {"SKY RADIANCE", "RGBA16F / RGB", "Atmospheric sky radiance before composition."},
    {"CLOUD RADIANCE", "RGBA16F / RGB", "Premultiplied cloud light after temporal resolve."},
    {"CLOUD DISTANCE", "RG32F / R", "Log of the opacity-weighted cloud distance."},
    {"AERIAL SCATTER", "RGBA16F / RGB", "Air scattering up to the representative depth."},
    {"AERIAL TRANSMITTANCE", "RGBA16F / RGB", "RGB transmission through the atmosphere."},
    {"HEIGHT FOG TRANSMIT", "RGBA16F / A", "White: transparent fog. Black: strong extinction."},
    {"ATMOSPHERE LUT", "RGBA16F / RGB", "X: sun angle. Y: sqrt(altitude / atmosphere height)."},
    {"CLOUD RAW RADIANCE", "RGBA16F / RGB", "Current ray-march radiance before temporal resolve."},
    {"CLOUD RAW TRANSMIT", "RGBA16F / A",
     "Current ray-march transmission before temporal resolve."},
    {"GBUFFER ROUGHNESS", "RGBA8 / A", "Surface roughness. Rain lowers it for wet ground."},
    {"RAIN PARTICLES", "RGBA16F / RGB", "World-space rain scatter before final composition."},
    {"CLOUD RECONSTRUCTION", "R32_UINT", "Green: traced. Blue: history. Red: repair. Gray: clear."},
    {"TOWER CONTROL VOLUME", "R16F", "Baked 3D convective-cell profile before noise erosion.",
     true},
    {"SMOOTH CLOUD WARP", "RGBA16F / RGB", "Periodic smooth XYZ displacement, encoded in [0,1].",
     true},
    {"CLOUD PLACEMENT", "RGBA16F / RG", "R/G: lower/upper cloud coverage. Period: 65.536 km."},
    {"CLOUD HEIGHT LUT", "RGBA8 / RGB", "RG: density thresholds. B: softness. Height goes down."},
    {"CLOUD SHADOW DEPTH", "RG16F / G", "Light-space occluder depth. White: clear or far."},
    {"METALLIC", "RGBA16F / A", "White: metal. Black: dielectric."},
    {"NEAR SHADOW DEPTH", "D32 / R32F", "Local terrain and tree shadows for walking."},
    {"RIVER SURFACE", "Depth test", "White: water in front of the terrain. Black: dry or hidden."},
}};

std::string narrow(const wchar_t *text)
{
    int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<size_t>(size), 0);
    WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
    if (!result.empty())
        result.pop_back();
    return result;
}

struct NoiseDdsHeader
{
    uint32_t magic, size, flags, height, width, pitch, depth, mipCount;
    uint32_t reserved[11];
    uint32_t pixelFormatSize, pixelFormatFlags, fourCC, colorBits, channelMasks[4];
    uint32_t caps, caps2, caps3, caps4, reserved2;
    uint32_t format, resourceDimension, miscFlag, arraySize, alphaMode;
};
static_assert(sizeof(NoiseDdsHeader) == 148);

struct NoiseDds
{
    UINT size = 0, pitch = 0;
    std::vector<uint16_t> texels;
};

NoiseDds readNoiseDds(const std::filesystem::path &path, DXGI_FORMAT format, bool volume)
{
    std::ifstream file(path, std::ios::binary);
    const std::string name = path.filename().string();
    if (!file)
        throw std::runtime_error("Cloud texture pack is missing " + name);

    // Studioが出力する、単一ミップ・非圧縮のDX10 DDSに対応する。寸法は確保前に検証する。
    NoiseDdsHeader header{};
    if (!file.read(reinterpret_cast<char *>(&header), sizeof(header)))
        throw std::runtime_error("Incomplete DDS header: " + name);
    const bool supportedSize = volume ? header.width == 32 || header.width == 64 || header.width == 128
                                      : header.width == 512;
    const UINT channels = format == DXGI_FORMAT_R16G16_FLOAT ? 2 : 4;
    const UINT dimension =
        volume ? D3D11_RESOURCE_DIMENSION_TEXTURE3D : D3D11_RESOURCE_DIMENSION_TEXTURE2D;
    if (header.magic != 0x20534444 || header.size != 124 || header.pixelFormatSize != 32
        || (header.pixelFormatFlags & 4) == 0 || header.fourCC != 0x30315844
        || !supportedSize || header.height != header.width
        || header.format != static_cast<uint32_t>(format)
        || header.resourceDimension != dimension || header.arraySize != 1 || header.miscFlag != 0
        || header.mipCount > 1 || header.depth != (volume ? header.width : 0)
        || header.pitch != header.width * channels * sizeof(uint16_t))
        throw std::runtime_error("Unsupported cloud texture DDS header: " + name);

    NoiseDds data;
    data.size = header.width;
    data.pitch = header.pitch;
    const size_t depth = volume ? header.width : 1;
    data.texels.resize(static_cast<size_t>(data.size) * data.size * depth * channels);
    const auto bytes = static_cast<std::streamsize>(data.texels.size() * sizeof(uint16_t));
    if (!file.read(reinterpret_cast<char *>(data.texels.data()), bytes)
        || file.peek() != std::char_traits<char>::eof())
        throw std::runtime_error("Unexpected cloud texture DDS data length: " + name);
    // 半精度の0～1だけを許可し、NaNや負の密度がレイマーチへ入るのを防ぐ。
    if (std::any_of(data.texels.begin(), data.texels.end(), [](uint16_t value) { return value > 0x3c00; }))
        throw std::runtime_error("Cloud texture texels must be finite values between 0 and 1: " + name);
    return data;
}

float hash(int x, int y)
{
    uint32_t h = static_cast<uint32_t>(x) * 374761393u + static_cast<uint32_t>(y) * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return static_cast<float>(h ^ (h >> 16)) / 4294967295.0f;
}

float noise(float x, float y)
{
    int ix = static_cast<int>(std::floor(x)), iy = static_cast<int>(std::floor(y));
    float fx = x - ix, fy = y - iy;
    fx = fx * fx * (3 - 2 * fx);
    fy = fy * fy * (3 - 2 * fy);
    return std::lerp(std::lerp(hash(ix, iy), hash(ix + 1, iy), fx),
                     std::lerp(hash(ix, iy + 1), hash(ix + 1, iy + 1), fx), fy);
}

float fbm(float x, float z)
{
    float f = 0, w = 0.516129f;
    for (int i = 0; i < 5; i++)
    {
        f += noise(x, z) * w;
        x = x * 2.03f + 7.1f;
        z = z * 2.03f - 4.3f;
        w *= 0.5f;
    }
    return f;
}

float terrainHeight(float x, float z)
{
    float hills = 45 + 220 * fbm(x * 0.00045f, z * 0.00045f);
    float distant = 1 - std::exp(-std::max(z - 2500.0f, 0.0f) / 8500);
    float ridge = std::pow(1 - std::abs(fbm(x * 0.00009f, z * 0.00009f) * 2 - 1), 5.0f);
    return hills + distant * (ridge * 2200 + fbm(x * 0.00022f, z * 0.00022f) * 450);
}

ComPtr<ID3DBlob> compile(const std::filesystem::path &path, const char *entry, const char *profile,
                        const D3D_SHADER_MACRO *defines = nullptr)
{
    ComPtr<ID3DBlob> shader, errors;
    HRESULT hr =
        D3DCompileFromFile(path.c_str(), defines, D3D_COMPILE_STANDARD_FILE_INCLUDE, entry, profile,
                           D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3
                               | D3DCOMPILE_WARNINGS_ARE_ERRORS,
                           0, &shader, &errors);
    if (FAILED(hr))
        throw std::runtime_error(
            path.filename().string() + " / " + entry + ": "
            + (errors ? std::string(static_cast<char *>(errors->GetBufferPointer()),
                                    errors->GetBufferSize())
                      : "HLSL compilation failed"));
    return shader;
}
}

void require(HRESULT hr, const char *operation)
{
    if (FAILED(hr))
    {
        std::ostringstream out;
        out << operation << " failed (HRESULT 0x" << std::hex << static_cast<uint32_t>(hr) << ')';
        throw std::runtime_error(out.str());
    }
}

void log(const std::string &message)
{
    static std::ofstream file = []
    {
        std::filesystem::create_directories("logs");
        return std::ofstream("logs/cirrus.log", std::ios::app);
    }();
    file << message << '\n';
    file.flush();
    const std::string line = message + "\n";
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output && output != INVALID_HANDLE_VALUE)
    {
        DWORD written = 0;
        WriteFile(output, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
    }
    OutputDebugStringA(line.c_str());
}

Renderer::Renderer(HWND window, const Options &options)
    : options_(options), weather_(options.weather)
{
    createDevice(window);
    shaders_ = compileShaders();
    log(shaders_.cloudOcclusionCS ? "Compiled rendering shaders, including voxels and Classic Fast."
                                  : "Compiled rendering shaders, including near cloud voxels.");
    if (options_.checkShaders)
        return;
    if (options_.formationFile.empty())
        setFormations(options_.formationMode);
    else
    {
        formations_ = loadFormationFile();
        options_.formationMode = "custom";
    }
    weather_.setAutomatic(options_.automatic);
    if (options_.transition >= 0)
        weather_.transitionTo(static_cast<WeatherKind>(options_.transition),
                              options_.transitionSeconds);
    if (options_.weatherDemo)
        weather_.setDemo(true);
    if (options_.openWorld)
        world_ = std::make_unique<World>(device_.Get(), context_.Get(),
                                         options_.assetsDirectory / L"world", options_.vegetation);
    timeLapse_ = options_.timeOfDay >= 0 && options_.daySeconds > 0;
    resetCamera();
    initializeResources();
    if (!options_.modelPath.empty())
    {
        float x = camera_.position.x + std::sin(camera_.yaw) * 9;
        float z = camera_.position.z + std::cos(camera_.yaw) * 9;
        float y = world_ ? world_->ground(x, z) : terrainHeight(x, z);
        model_ = loadStaticModel(device_.Get(), context_.Get(), options_.modelPath, {x, y, z},
                                 options_.modelScale);
    }
    resize(options.width, options.height);
}

Renderer::~Renderer()
{
    if (context_)
    {
        context_->ClearState();
        context_->Flush();
    }
}

void Renderer::createDevice(HWND window)
{
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if (options_.debugLayer)
        flags |= D3D11_CREATE_DEVICE_DEBUG;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL level;
    ComPtr<IDXGIFactory1> factory;
    require(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory");
    ComPtr<IDXGIAdapter1> adapter;
    if (!options_.warp)
    {
        SIZE_T best = 0;
        for (UINT i = 0;; i++)
        {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(i, &candidate) == DXGI_ERROR_NOT_FOUND)
                break;
            DXGI_ADAPTER_DESC1 desc{};
            candidate->GetDesc1(&desc);
            if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)
                && (!adapter || desc.DedicatedVideoMemory > best))
            {
                adapter = candidate;
                best = desc.DedicatedVideoMemory;
            }
        }
    }
    auto create = [&](UINT f)
    {
        return D3D11CreateDevice(adapter.Get(),
                                 adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_WARP, nullptr,
                                 f, levels, 1, D3D11_SDK_VERSION, &device_, &level, &context_);
    };
    HRESULT hr = create(flags);
    if (hr == DXGI_ERROR_SDK_COMPONENT_MISSING && (flags & D3D11_CREATE_DEVICE_DEBUG))
    {
        log("D3D11 debug layer unavailable; continuing without it.");
        flags &= ~D3D11_CREATE_DEVICE_DEBUG;
        hr = create(flags);
    }
    require(hr, "D3D11 device (feature level 11_0)");
    ComPtr<IDXGIDevice> dxgi;
    require(device_.As(&dxgi), "DXGI device");
    ComPtr<IDXGIAdapter> actual;
    require(dxgi->GetAdapter(&actual), "Get adapter");
    DXGI_ADAPTER_DESC desc{};
    actual->GetDesc(&desc);
    adapter_ = narrow(desc.Description);
    log("Adapter: " + adapter_);
    require(actual->GetParent(IID_PPV_ARGS(&factory)), "Adapter factory");
    DXGI_SWAP_CHAIN_DESC sc{};
    sc.BufferDesc.Width = options_.width;
    sc.BufferDesc.Height = options_.height;
    sc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sc.SampleDesc.Count = 1;
    sc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sc.BufferCount = 2;
    sc.OutputWindow = window;
    sc.Windowed = TRUE;
    sc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    require(factory->CreateSwapChain(device_.Get(), &sc, &swapchain_), "Swap chain");
    factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER);
    for (auto &slot : timing_)
    {
        D3D11_QUERY_DESC q{D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
        require(device_->CreateQuery(&q, &slot.disjoint), "Timer disjoint");
        q.Query = D3D11_QUERY_TIMESTAMP;
        for (auto &stamp : slot.stamps)
            require(device_->CreateQuery(&q, &stamp), "Timer timestamp");
    }
}

ShaderSet Renderer::compileShaders()
{
    // 一式をローカルに作り、全コンパイル成功後にだけ呼び出し元へ渡す。
    // F5で途中のシェーダーが失敗しても、描画中のセットはそのまま残せる。
    ShaderSet s;
    auto path = [&](const wchar_t *name)
    {
        return options_.shaderDirectory / name;
    };
    auto vs = [&](const wchar_t *file, const char *entry, ComPtr<ID3D11VertexShader> &result)
    {
        auto code = compile(path(file), entry, "vs_5_0");
        require(device_->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(),
                                            nullptr, &result),
                entry);
        return code;
    };
    auto ps = [&](const wchar_t *file, const char *entry, ComPtr<ID3D11PixelShader> &result)
    {
        auto code = compile(path(file), entry, "ps_5_0");
        require(device_->CreatePixelShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr,
                                           &result),
                entry);
    };
    auto cs = [&](const wchar_t *file, const char *entry, ComPtr<ID3D11ComputeShader> &result,
                  const D3D_SHADER_MACRO *defines = nullptr)
    {
        auto code = compile(path(file), entry, "cs_5_0", defines);
        require(device_->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(),
                                             nullptr, &result),
                entry);
    };
    auto geometry = vs(L"scene.hlsl", "GeometryVS", s.geometryVS);
    vs(L"scene.hlsl", "ShadowVS", s.shadowVS);
    vs(L"scene.hlsl", "FullscreenVS", s.fullscreenVS);
    ps(L"scene.hlsl", "GeometryPS", s.geometryPS);
    ps(L"scene.hlsl", "CompositePS", s.compositePS);
    ps(L"scene.hlsl", "ResolveEdgesPS", s.resolveEdgesPS);
    vs(L"rain.hlsl", "RainVS", s.rainVS);
    ps(L"rain.hlsl", "RainPS", s.rainPS);
    auto mesh = vs(L"mesh.hlsl", "MeshVS", s.meshVS);
    ps(L"mesh.hlsl", "MeshPS", s.meshPS);
    ps(L"mesh.hlsl", "MeshShadowPS", s.meshShadowPS);
    vs(L"grass.hlsl", "GrassVS", s.grassVS);
    ps(L"grass.hlsl", "GrassPS", s.grassPS);
    cs(L"grass.hlsl", "GrassPlacementCS", s.grassPlacementCS);
    cs(L"noise.hlsl", "NoiseCS", s.noiseCS);
    cs(L"noise.hlsl", "WeatherCS", s.weatherCS);
    cs(L"atmosphere.hlsl", "TransmittanceCS", s.transmittanceCS);
    cs(L"atmosphere.hlsl", "SkyCS", s.skyCS);
    cs(L"atmosphere.hlsl", "SkyAmbientCS", s.skyAmbientCS);
    cs(L"atmosphere.hlsl", "AerialCS", s.aerialCS);
    cs(L"clouds.hlsl", "TemporalCS", s.temporalCS);
    cs(L"clouds.hlsl", "IntegrateNearCloudCS", s.nearCloudIntegrateCS);
    // 雲の配置・影・描画・画素修復を同じ密度モデルの組で切り替える。
    const D3D_SHADER_MACRO cumulus[] = {{"CIRRUS_CUMULUS_CLOUDS", "1"}, {nullptr, nullptr}};
    for (size_t i = 0; i < s.cloudStyles.size(); ++i)
    {
        auto &style = s.cloudStyles[i];
        const auto *defines = i == static_cast<size_t>(CloudStyle::Cumulus) ? cumulus : nullptr;
        cs(L"noise.hlsl", "CloudMapCS", style.mapCS, defines);
        cs(L"clouds.hlsl", "LightNearCloudCS", style.nearCloudCS, defines);
        cs(L"clouds.hlsl", "ShadowCS", style.shadowCS, defines);
        cs(L"clouds.hlsl", "CloudCS", style.marchCS, defines);
        cs(L"clouds.hlsl", "RepairCS", style.repairCS, defines);
    }
    if (options_.classicFast || options_.checkShaders)
    {
        const D3D_SHADER_MACRO fast[] = {{"CIRRUS_CLASSIC_FAST", "1"}, {nullptr, nullptr}};
        cs(L"clouds.hlsl", "CloudCS", s.fastClassicMarchCS, fast);
        cs(L"clouds.hlsl", "TemporalCS", s.fastClassicTemporalCS, fast);
        cs(L"clouds.hlsl", "RepairCS", s.fastClassicRepairCS, fast);
        cs(L"clouds.hlsl", "CloudOcclusionCS", s.cloudOcclusionCS, fast);
    }
    D3D11_INPUT_ELEMENT_DESC layout[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0}};
    require(device_->CreateInputLayout(layout, 3, geometry->GetBufferPointer(),
                                       geometry->GetBufferSize(), &s.geometryLayout),
            "Geometry layout");
    const D3D11_INPUT_ELEMENT_DESC meshLayout[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, offsetof(MeshVertex, position),
         D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, offsetof(MeshVertex, normal),
         D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TANGENT", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, offsetof(MeshVertex, tangent),
         D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, offsetof(MeshVertex, uv),
         D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 1, DXGI_FORMAT_R32G32_FLOAT, 0, offsetof(MeshVertex, uv1),
         D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, offsetof(MeshVertex, color),
         D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"INSTANCE", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, offsetof(MeshInstance, positionScale),
         D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"INSTANCE", 1, DXGI_FORMAT_R32G32B32A32_FLOAT, 1,
         offsetof(MeshInstance, rotationVariation), D3D11_INPUT_PER_INSTANCE_DATA, 1}};
    require(device_->CreateInputLayout(meshLayout, static_cast<UINT>(std::size(meshLayout)),
                                       mesh->GetBufferPointer(), mesh->GetBufferSize(),
                                       &s.meshLayout),
            "PBR mesh layout");
    return s;
}

VolumeTexture Renderer::makeVolume(int width, int height, int depth, DXGI_FORMAT format)
{
    D3D11_TEXTURE3D_DESC desc{};
    desc.Width = width;
    desc.Height = height;
    desc.Depth = depth;
    desc.MipLevels = 1;
    desc.Format = format;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;
    ComPtr<ID3D11Texture3D> volume;
    require(device_->CreateTexture3D(&desc, nullptr, &volume), "Cloud volume texture");
    VolumeTexture result;
    require(device_->CreateShaderResourceView(volume.Get(), nullptr, &result.srv), "Cloud volume SRV");
    require(device_->CreateUnorderedAccessView(volume.Get(), nullptr, &result.uav), "Cloud volume UAV");
    return result;
}

Texture Renderer::makeTexture(int w, int h, DXGI_FORMAT format, bool target, bool unordered,
                              bool mipmaps)
{
    Texture result;
    D3D11_TEXTURE2D_DESC d{};
    d.Width = w;
    d.Height = h;
    d.MipLevels = mipmaps ? 0 : 1;
    d.ArraySize = 1;
    d.Format = format;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    if (target || mipmaps)
        d.BindFlags |= D3D11_BIND_RENDER_TARGET;
    if (unordered)
        d.BindFlags |= D3D11_BIND_UNORDERED_ACCESS;
    if (mipmaps)
        d.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
    require(device_->CreateTexture2D(&d, nullptr, &result.texture), "Texture2D");
    require(device_->CreateShaderResourceView(result.texture.Get(), nullptr, &result.srv),
            "Texture SRV");
    if (target)
        require(device_->CreateRenderTargetView(result.texture.Get(), nullptr, &result.rtv),
                "Texture RTV");
    if (unordered)
    {
        D3D11_UNORDERED_ACCESS_VIEW_DESC u{};
        u.Format = format;
        u.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
        require(device_->CreateUnorderedAccessView(result.texture.Get(), &u, &result.uav),
                "Texture UAV");
    }
    return result;
}

void Renderer::initializeResources()
{
    D3D11_BLEND_DESC rainBlend{};
    auto &blend = rainBlend.RenderTarget[0];
    blend.BlendEnable = TRUE;
    blend.SrcBlend = D3D11_BLEND_ONE;
    blend.DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.BlendOp = D3D11_BLEND_OP_ADD;
    blend.SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend.BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    require(device_->CreateBlendState(&rainBlend, &rainBlend_), "Rain premultiplied blend");
    D3D11_BUFFER_DESC b{};
    b.ByteWidth = sizeof(FrameData);
    b.Usage = D3D11_USAGE_DYNAMIC;
    b.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    b.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    require(device_->CreateBuffer(&b, nullptr, &frameBuffer_), "Frame constants");
    b.ByteWidth = sizeof(XMFLOAT4X4);
    require(device_->CreateBuffer(&b, nullptr, &passBuffer_), "Geometry pass constants");
    b.ByteWidth = 16;
    require(device_->CreateBuffer(&b, nullptr, &noiseBuffer_), "Noise constants");
    D3D11_SAMPLER_DESC sd{};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    require(device_->CreateSamplerState(&sd, &linearClamp_), "Clamp sampler");
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
    require(device_->CreateSamplerState(&sd, &linearWrap_), "Wrap sampler");
    sd.Filter = D3D11_FILTER_ANISOTROPIC;
    sd.MaxAnisotropy = 8;
    require(device_->CreateSamplerState(&sd, &terrainSampler_), "Anisotropic terrain sampler");
    // 地形の深度シャドウ用。雲影は通常の線形サンプラーで指数モーメントを読む。
    sd.Filter = D3D11_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT;
    sd.ComparisonFunc = D3D11_COMPARISON_LESS_EQUAL;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_BORDER;
    for (float &v : sd.BorderColor)
        v = 1;
    require(device_->CreateSamplerState(&sd, &shadowSampler_), "Shadow sampler");
    D3D11_RASTERIZER_DESC rd{};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    require(device_->CreateRasterizerState(&rd, &raster_), "Raster state");
    rd.CullMode = D3D11_CULL_BACK;
    require(device_->CreateRasterizerState(&rd, &meshRaster_), "Mesh raster state");
    // 地形シャドウの自己遮蔽による縞を抑えるラスタライズ時の深度バイアス。
    rd.DepthBias = 200;
    rd.SlopeScaledDepthBias = 1.5f;
    require(device_->CreateRasterizerState(&rd, &meshShadowRaster_), "Mesh shadow raster state");
    rd.CullMode = D3D11_CULL_NONE;
    require(device_->CreateRasterizerState(&rd, &shadowRaster_), "Shadow raster state");
    D3D11_DEPTH_STENCIL_DESC dd{};
    dd.DepthEnable = TRUE;
    dd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    dd.DepthFunc = D3D11_COMPARISON_LESS_EQUAL;
    require(device_->CreateDepthStencilState(&dd, &depthOn_), "Depth state");
    dd.DepthFunc = D3D11_COMPARISON_GREATER_EQUAL;
    require(device_->CreateDepthStencilState(&dd, &reversedDepth_), "Reversed depth state");
    dd.DepthEnable = FALSE;
    require(device_->CreateDepthStencilState(&dd, &depthOff_), "No depth state");
    weatherMap_ = makeTexture(512, 512, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true, true);
    cloudDisplacement_ = makeTexture(512, 512, DXGI_FORMAT_R16G16_FLOAT, false, true, true);
    cloudMap_ = makeTexture(512, 512, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    cloudHeightLut_ = makeTexture(1, 128, DXGI_FORMAT_R8G8B8A8_UNORM, false, true);
    // 透過率 LUT は高度×太陽光の角度。背景の空はカメラ視線ごとに計算する。
    // 空の環境光は上半球の散乱を平均した 1 テクセルを霧と地表で共有する。
    transmittance_ = makeTexture(256, 64, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    sky_ = makeTexture(320, 180, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    skyAmbient_ = makeTexture(1, 1, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    const bool voxels = options_.nearCloudVoxels && options_.clouds;
    const int voxelWidth = voxels ? nearCloudWidth : 1;
    const int voxelHeight = voxels ? nearCloudHeight : 1;
    const int voxelDepth = voxels ? nearCloudSlices : 1;
    nearCloudLight_ = makeVolume(voxelWidth, voxelHeight, voxelDepth, DXGI_FORMAT_R16G16B16A16_FLOAT);
    nearCloud_ = makeVolume(voxelWidth, voxelHeight, voxelDepth, DXGI_FORMAT_R16G16B16A16_FLOAT);
    nearCloudMoment_ = makeVolume(voxelWidth, voxelHeight, voxelDepth, DXGI_FORMAT_R16_FLOAT);
    const float clearCloud[] = {0, 0, 0, 1};
    const float clearMoment[] = {0, 0, 0, 0};
    context_->ClearUnorderedAccessViewFloat(nearCloud_.uav.Get(), clearCloud);
    context_->ClearUnorderedAccessViewFloat(nearCloudMoment_.uav.Get(), clearMoment);
    if (options_.classicFast)
    {
        cloudOcclusion_ = makeVolume(cloudOcclusionXZ, cloudOcclusionY, cloudOcclusionXZ,
                                     DXGI_FORMAT_R32G32B32A32_FLOAT);
        const float clear[] = {0, 0, 0, 16};
        context_->ClearUnorderedAccessViewFloat(cloudOcclusion_.uav.Get(), clear);
    }
    const auto &packDirectory = options_.cloudTextureDirectory;
    auto makeCloudNoise = [&](const wchar_t *name, UINT &size, UINT kind,
                              ComPtr<ID3D11ShaderResourceView> &output)
    {
        NoiseDds imported;
        if (!packDirectory.empty())
        {
            imported = readNoiseDds(packDirectory / name, DXGI_FORMAT_R16G16B16A16_FLOAT, true);
            size = imported.size;
        }
        D3D11_TEXTURE3D_DESC d{};
        d.Width = d.Height = d.Depth = size;
        d.MipLevels = 0;
        d.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
        d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags =
            D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_RENDER_TARGET;
        d.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
        ComPtr<ID3D11Texture3D> texture;
        require(device_->CreateTexture3D(&d, nullptr, &texture), "Noise texture");
        require(device_->CreateShaderResourceView(texture.Get(), nullptr, &output), "Noise SRV");
        if (!imported.texels.empty())
        {
            context_->UpdateSubresource(texture.Get(), 0, nullptr, imported.texels.data(),
                                        imported.pitch, imported.pitch * size);
            context_->GenerateMips(output.Get());
            return;
        }
        D3D11_UNORDERED_ACCESS_VIEW_DESC ud{};
        ud.Format = d.Format;
        ud.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE3D;
        ud.Texture3D.WSize = size;
        ComPtr<ID3D11UnorderedAccessView> uav;
        require(device_->CreateUnorderedAccessView(texture.Get(), &ud, &uav), "Noise UAV");
        D3D11_MAPPED_SUBRESOURCE m{};
        require(context_->Map(noiseBuffer_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m),
                "Noise parameters");
        const std::array<UINT, 4> parameters{size, kind, 0, 0};
        std::memcpy(m.pData, parameters.data(), 16);
        context_->Unmap(noiseBuffer_.Get(), 0);
        ID3D11Buffer *cb = noiseBuffer_.Get();
        context_->CSSetConstantBuffers(1, 1, &cb);
        compute(shaders_.noiseCS.Get(), (size + 7) / 8, (size + 7) / 8, (size + 7) / 8, {uav.Get()},
                {});
        context_->GenerateMips(output.Get());
    };
    // 通常は128³をGPUで生成し、パックが指定されたときはDDSからミップ0を読む。
    makeCloudNoise(L"base-noise.dds", baseNoiseSize_, 0, baseNoise_);
    makeCloudNoise(L"detail-noise.dds", detailNoiseSize_, 1, detailNoise_);
    // 解析的なセル群は起動時だけ評価。レイの各点では共有3Dテクスチャを1回読む。
    const auto bakeBegin = std::chrono::steady_clock::now();
    const auto control = bakeCloudControlVolume();
    std::vector<DirectX::PackedVector::HALF> packedControl(control.size());
    for (std::size_t i = 0; i < control.size(); ++i)
        packedControl[i] = DirectX::PackedVector::XMConvertFloatToHalf(control[i]);
    D3D11_TEXTURE3D_DESC volumeDesc{};
    volumeDesc.Width = volumeDesc.Height = volumeDesc.Depth = cloudControlSize;
    volumeDesc.MipLevels = 1;
    volumeDesc.Format = DXGI_FORMAT_R16_FLOAT;
    volumeDesc.Usage = D3D11_USAGE_IMMUTABLE;
    volumeDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA volumeData{};
    volumeData.pSysMem = packedControl.data();
    volumeData.SysMemPitch = cloudControlSize * sizeof(packedControl[0]);
    volumeData.SysMemSlicePitch = cloudControlSize * volumeData.SysMemPitch;
    ComPtr<ID3D11Texture3D> volumeTexture;
    require(device_->CreateTexture3D(&volumeDesc, &volumeData, &volumeTexture),
            "Tower control volume");
    require(device_->CreateShaderResourceView(volumeTexture.Get(), nullptr, &towerControl_),
            "Tower control SRV");
    const auto warp = bakeCloudWarpVolume();
    std::vector<DirectX::PackedVector::HALF> packedWarp(warp.size() * 4);
    for (std::size_t i = 0; i < warp.size(); ++i)
        for (int channel = 0; channel < 4; ++channel)
            packedWarp[i * 4 + channel] =
                DirectX::PackedVector::XMConvertFloatToHalf(warp[i][channel]);
    volumeDesc.Width = volumeDesc.Height = volumeDesc.Depth = cloudWarpSize;
    volumeDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    volumeData.pSysMem = packedWarp.data();
    volumeData.SysMemPitch = cloudWarpSize * 4 * sizeof(packedWarp[0]);
    volumeData.SysMemSlicePitch = cloudWarpSize * volumeData.SysMemPitch;
    require(device_->CreateTexture3D(&volumeDesc, &volumeData, &volumeTexture),
            "Cloud warp volume");
    require(device_->CreateShaderResourceView(volumeTexture.Get(), nullptr, &cloudWarp_),
            "Cloud warp SRV");
    towerBakeMs_ =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - bakeBegin)
            .count();
    if (packDirectory.empty())
        compute(shaders_.weatherCS.Get(), 64, 64, 1,
                {weatherMap_.uav.Get(), cloudDisplacement_.uav.Get()}, {});
    else
    {
        const auto weather = readNoiseDds(packDirectory / L"weather-map.dds",
                                          DXGI_FORMAT_R16G16B16A16_FLOAT, false);
        const auto displacement = readNoiseDds(packDirectory / L"cloud-displacement.dds",
                                               DXGI_FORMAT_R16G16_FLOAT, false);
        context_->UpdateSubresource(weatherMap_.texture.Get(), 0, nullptr, weather.texels.data(),
                                    weather.pitch, 0);
        context_->UpdateSubresource(cloudDisplacement_.texture.Get(), 0, nullptr,
                                    displacement.texels.data(), displacement.pitch, 0);
    }
    context_->GenerateMips(weatherMap_.srv.Get());
    context_->GenerateMips(cloudDisplacement_.srv.Get());
    makeShadowDepth(terrainDepthView_, terrainDepthSRV_);
    if (world_)
        makeShadowDepth(nearDepthView_, nearDepthSRV_);
    else
        makeTerrain();
    ui_.initialize(device_.Get());
    if (packDirectory.empty())
        log("Generated periodic Perlin-Worley 128^3 / Worley 128^3 noise and weather field.");
    else
        log("Loaded cloud texture DDS pack (base " + std::to_string(baseNoiseSize_) + "^3, detail "
            + std::to_string(detailNoiseSize_) + "^3, weather/displacement 512^2).");
}

void Renderer::makeShadowDepth(ComPtr<ID3D11DepthStencilView> &dsv,
                               ComPtr<ID3D11ShaderResourceView> &srv)
{
    D3D11_TEXTURE2D_DESC td{};
    // 地形用は2048²の深度マップ。DSVではD32、シェーダーからはR32で読む。
    td.Width = td.Height = 2048;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R32_TYPELESS;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_DEPTH_STENCIL | D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> texture;
    require(device_->CreateTexture2D(&td, nullptr, &texture), "Terrain shadow depth");
    D3D11_DEPTH_STENCIL_VIEW_DESC dv{};
    dv.Format = DXGI_FORMAT_D32_FLOAT;
    dv.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2D;
    require(device_->CreateDepthStencilView(texture.Get(), &dv, &dsv), "Terrain shadow DSV");
    D3D11_SHADER_RESOURCE_VIEW_DESC sv{};
    sv.Format = DXGI_FORMAT_R32_FLOAT;
    sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    sv.Texture2D.MipLevels = 1;
    require(device_->CreateShaderResourceView(texture.Get(), &sv, &srv), "Terrain shadow SRV");
}

void Renderer::makeTerrain()
{
    constexpr int n = 400;
    std::vector<TerrainVertex> v;
    v.reserve((n + 1) * (n + 1));
    auto coordinate = [](int i)
    {
        float t = i / 400.0f * 2 - 1;
        return std::copysign(std::pow(std::abs(t), 1.5f) * 42000, t);
    };
    for (int z = 0; z <= n; z++)
        for (int x = 0; x <= n; x++)
        {
            float px = coordinate(x), pz = coordinate(z), height = terrainHeight(px, pz);
            XMVECTOR norm = XMVector3Normalize(
                XMVectorSet(terrainHeight(px - 5, pz) - terrainHeight(px + 5, pz), 10,
                            terrainHeight(px, pz - 5) - terrainHeight(px, pz + 5), 0));
            XMFLOAT3 normal;
            XMStoreFloat3(&normal, norm);
            float green = fbm(px * 0.0007f, pz * 0.0007f);
            float rock = std::clamp((height - 1100) / 900 + (1 - normal.y) * 1.8f, 0.0f, 1.0f);
            XMFLOAT3 grass{std::lerp(0.27f, 0.095f, green), std::lerp(0.22f, 0.16f, green),
                           std::lerp(0.095f, 0.055f, green)};
            XMFLOAT4 material{std::lerp(grass.x, 0.24f, rock), std::lerp(grass.y, 0.23f, rock),
                              std::lerp(grass.z, 0.22f, rock), 0.91f};
            v.push_back({{px, height, pz}, normal, material});
        }
    std::vector<uint32_t> indices;
    indices.reserve(n * n * 6);
    for (int z = 0; z < n; z++)
        for (int x = 0; x < n; x++)
        {
            uint32_t a = z * (n + 1) + x, b = a + 1, c = a + n + 1, d = c + 1;
            indices.insert(indices.end(), {a, c, b, b, c, d});
        }
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = static_cast<UINT>(v.size() * sizeof(TerrainVertex));
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA data{v.data(), 0, 0};
    require(device_->CreateBuffer(&bd, &data, &vertices_), "Terrain vertices");
    bd.ByteWidth = static_cast<UINT>(indices.size() * sizeof(uint32_t));
    bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
    data.pSysMem = indices.data();
    require(device_->CreateBuffer(&bd, &data, &indices_), "Terrain indices");
    indexCount_ = static_cast<UINT>(indices.size());
}

void Renderer::resize(int w, int h)
{
    if (w <= 0 || h <= 0 || options_.checkShaders)
        return;
    context_->ClearState();
    backbuffer_.Reset();
    depthView_.Reset();
    depthSRV_.Reset();
    depth_.Reset();
    width_ = w;
    height_ = h;
    require(swapchain_->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0), "Resize swap chain");
    ComPtr<ID3D11Texture2D> back;
    require(swapchain_->GetBuffer(0, IID_PPV_ARGS(&back)), "Back buffer");
    require(device_->CreateRenderTargetView(back.Get(), nullptr, &backbuffer_), "Back buffer RTV");
    D3D11_TEXTURE2D_DESC td{};
    td.Width = w;
    td.Height = h;
    td.ArraySize = td.MipLevels = 1;
    td.Format = DXGI_FORMAT_R32_TYPELESS;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_DEPTH_STENCIL | D3D11_BIND_SHADER_RESOURCE;
    require(device_->CreateTexture2D(&td, nullptr, &depth_), "Scene depth");
    D3D11_DEPTH_STENCIL_VIEW_DESC dv{};
    dv.Format = DXGI_FORMAT_D32_FLOAT;
    dv.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2D;
    require(device_->CreateDepthStencilView(depth_.Get(), &dv, &depthView_), "Scene DSV");
    D3D11_SHADER_RESOURCE_VIEW_DESC sv{};
    sv.Format = DXGI_FORMAT_R32_FLOAT;
    sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    sv.Texture2D.MipLevels = 1;
    require(device_->CreateShaderResourceView(depth_.Get(), &sv, &depthSRV_), "Scene depth SRV");
    makeTargets();
}

bool Renderer::fastClassic() const
{
    return options_.classicFast && options_.cloudStyle == CloudStyle::Classic;
}

void Renderer::makeCloudRawTargets()
{
    const int width = options_.checkerboard ? (cloudWidth_ + 1) / 2 : cloudWidth_;
    const int height = options_.checkerboard && fastClassic() ? (cloudHeight_ + 1) / 2 : cloudHeight_;
    auto color = makeTexture(width, height, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    auto metadata = makeTexture(width, height, DXGI_FORMAT_R32G32_FLOAT, false, true);
    cloudRaw_ = std::move(color);
    metaRaw_ = std::move(metadata);
    rawCloudWidth_ = width;
    rawCloudHeight_ = height;
}

void Renderer::makeTargets()
{
    context_->ClearState();
    int q = static_cast<int>(options_.quality);
    // 雲の縦横解像度はLow=1/4、Medium/High=1/2、Ultra=等倍。
    int divisor = q == 0 ? 4 : (q == 3 ? 1 : 2);
    if (options_.cloudDivisor != 0)
        divisor = options_.cloudDivisor;
    cloudWidth_ = (width_ + divisor - 1) / divisor;
    cloudHeight_ = (height_ + divisor - 1) / divisor;
    aerialWidth_ = (width_ + 3) / 4;
    aerialHeight_ = (height_ + 3) / 4;
    shadowSize_ = shadowSizes[q];
    finalColor_ = makeTexture(width_, height_, DXGI_FORMAT_R8G8B8A8_UNORM, true, false);
    if (world_)
        sceneColor_ = makeTexture(width_, height_, DXGI_FORMAT_R8G8B8A8_UNORM, true, false);
    albedo_ = makeTexture(width_, height_, DXGI_FORMAT_R8G8B8A8_UNORM, true, false);
    normals_ = makeTexture(width_, height_, DXGI_FORMAT_R16G16B16A16_FLOAT, true, false);
    surface_ = makeTexture(width_, height_, DXGI_FORMAT_R16G16B16A16_FLOAT, true, false);
    // RG16Fに雲層全体の透過率と、太陽から見た遮蔽深度の指数値を保存する。
    shadowMap_ = makeTexture(shadowSize_, shadowSize_, DXGI_FORMAT_R16G16_FLOAT, false, true, true);
    makeCloudRawTargets();
    reconstruction_ = makeTexture(cloudWidth_, cloudHeight_, DXGI_FORMAT_R32_UINT, false, true);
    if (options_.classicFast)
        previousReconstruction_ =
            makeTexture(cloudWidth_, cloudHeight_, DXGI_FORMAT_R32_UINT, false, true);
    for (int i = 0; i < 2; i++)
    {
        history_[i] =
            makeTexture(cloudWidth_, cloudHeight_, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
        historyMeta_[i] =
            makeTexture(cloudWidth_, cloudHeight_, DXGI_FORMAT_R32G32_FLOAT, false, true);
        const float cloudClear[] = {0, 0, 0, 1}, metaClear[] = {150000, 150000, 0, 0};
        context_->ClearUnorderedAccessViewFloat(history_[i].uav.Get(), cloudClear);
        context_->ClearUnorderedAccessViewFloat(historyMeta_[i].uav.Get(), metaClear);
    }
    aerialScatter_ =
        makeTexture(aerialWidth_, aerialHeight_, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    aerialTransmittance_ =
        makeTexture(aerialWidth_, aerialHeight_, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    fog_ = makeTexture(aerialWidth_, aerialHeight_, DXGI_FORMAT_R16G16B16A16_FLOAT, false, true);
    rain_ = makeTexture(width_, height_, DXGI_FORMAT_R16G16B16A16_FLOAT, true, false);
    cloudOcclusionSource_.region.w = 0;
    shadowValid_ = false;
    historyValid_ = false;
    checkerActive_ = false;
    fullCloudRefresh_ = true;
    historyIndex_ = 0;
}

ShaderResources Renderer::resources() const
{
    return {baseNoise_.Get(),
            detailNoise_.Get(),
            weatherMap_.srv.Get(),
            shadowMap_.srv.Get(),
            depthSRV_.Get(),
            albedo_.srv.Get(),
            normals_.srv.Get(),
            sky_.srv.Get(),
            history_[historyIndex_].srv.Get(),
            historyMeta_[historyIndex_].srv.Get(),
            nullptr,
            nullptr,
            aerialScatter_.srv.Get(),
            aerialTransmittance_.srv.Get(),
            fog_.srv.Get(),
            terrainDepthSRV_.Get(),
            transmittance_.srv.Get(),
            nullptr,
            rain_.srv.Get(),
            reconstruction_.srv.Get(),
            towerControl_.Get(),
            cloudWarp_.Get(),
            cloudMap_.srv.Get(),
            cloudHeightLut_.srv.Get(),
            cloudDisplacement_.srv.Get(),
            skyAmbient_.srv.Get(),
            nearDepthSRV_.Get(),
            surface_.srv.Get(),
            nullptr,
            nullptr,
            nullptr,
            nearCloud_.srv.Get()};
}

void Renderer::compute(ID3D11ComputeShader *shader, int x, int y, int z,
                       const std::vector<ID3D11UnorderedAccessView *> &output,
                       ShaderResources input)
{
    // SRVは読み出し、UAVは書き込み。同じテクスチャを両方へ同時に束縛しない。
    // パスの前後で不要な束縛を外し、次の処理へ安全に受け渡す。
    context_->OMSetRenderTargets(0, nullptr, nullptr);
    const ShaderResources empty{};
    context_->PSSetShaderResources(0, shaderResourceCount, empty.data());
    context_->CSSetShader(shader, nullptr, 0);
    context_->CSSetShaderResources(0, shaderResourceCount, input.data());
    context_->CSSetUnorderedAccessViews(0, static_cast<UINT>(output.size()), output.data(),
                                        nullptr);
    context_->Dispatch(x, y, z);
    const std::array<ID3D11UnorderedAccessView *, 3> nullUav{};
    context_->CSSetUnorderedAccessViews(0, 3, nullUav.data(), nullptr);
    context_->CSSetShaderResources(0, shaderResourceCount, empty.data());
}

void Renderer::updateNearClouds()
{
    const bool wasActive = constants_.nearCloudParams.x > 0;
    const bool hadWarp = constants_.nearCloudParams.y > 0;
    constants_.nearCloudParams = {};
    if (!options_.nearCloudVoxels || !options_.clouds)
        return;

    const auto &eye = camera_.position;
    constexpr double planetRadius = 6360000;
    const double vertical = planetRadius + eye.y;
    const float height = world_ ? eye.y : static_cast<float>(
        std::sqrt(vertical * vertical + static_cast<double>(eye.x) * eye.x
                  + static_cast<double>(eye.z) * eye.z) - planetRadius);

    const auto &layer = constants_.cloudLayer;
    const float top = layer.x + layer.y;
    const float gap = std::max({layer.x - height, height - top, 0.0f});
    const float ramp = std::clamp((1100.0f - gap) / 600.0f, 0.0f, 1.0f);
    const float warpStrength = ramp * ramp * (3 - 2 * ramp);
    constexpr float warpMargin = 430;
    if (warpStrength > 0)
        constants_.formationLayer.y = std::max(constants_.formationLayer.y, top + warpMargin);

    // 視錐台の隅でも格子内に雲が来る可能性があるときは近距離を積分する。
    const float aspect = static_cast<float>(width_) / height_;
    const float cornerRayLength = nearCloudDepth * std::sqrt(1 + 0.361f * (1 + aspect * aspect));
    const bool active = height + cornerRayLength >= constants_.formationLayer.x - warpMargin
                        && height - cornerRayLength <= constants_.formationLayer.y;
    constants_.nearCloudParams = {active ? nearCloudDepth : 0, warpStrength,
                                  static_cast<float>(nearCloudSlices), 1100.0f};
    if (active != wasActive)
        historyValid_ = false;
    if ((warpStrength > 0) != hadWarp)
        shadowValid_ = false;
}

void Renderer::updateCloudOcclusion(bool shareLighting, const XMFLOAT4 &previousSun)
{
    constants_.cloudOcclusionRegion = {};
    rebuildCloudOcclusion_ = false;
    // 天候の遷移中と局所形状があるときは、その時点の密度を直接積分する。
    if (!fastClassic() || !shareLighting || !historyValid_ || !options_.clouds
        || constants_.nearCloudParams.y > 0 || constants_.formationControls.x > 0
        || constants_.sunDirection.y <= 0.05f
        || weather_.transitionProgress() < 1.0)
        return;

    const auto &sun = constants_.sunDirection;
    const auto sunMotionSquared = [&sun](const XMFLOAT4 &from)
    {
        const float x = sun.x - from.x, y = sun.y - from.y, z = sun.z - from.z;
        return x * x + y * y + z * z;
    };
    // 急な時刻変更では直接積分へ戻す。通常の時刻進行は角度が変わるまで共有する。
    constexpr float maxChangePerFrame = 0.001f, maxChangeSinceBake = 0.004f;
    if (sunMotionSquared(previousSun) > maxChangePerFrame * maxChangePerFrame)
        return;

    // 風の移動を引いたXZに格子を置く。カメラの近くで安定した範囲を複数のレイが共有する。
    constexpr float span = 32000.0f, snap = 8000.0f;
    const auto &wind = constants_.wind;
    const auto &position = camera_.position;
    const XMFLOAT4 region{std::round((position.x - wind.x) / snap) * snap,
                          std::round((position.z - wind.y) / snap) * snap, span, 1};
    constants_.cloudOcclusionRegion = region;
    auto &source = cloudOcclusionSource_;
    rebuildCloudOcclusion_ =
        std::memcmp(&source.region, &region, sizeof(region)) != 0
        || std::memcmp(&source.layer, &constants_.cloudLayer, sizeof(source.layer)) != 0
        || sunMotionSquared(source.sun) > maxChangeSinceBake * maxChangeSinceBake
        || source.cloudType != constants_.weather.x || std::abs(wind.x - source.wind.x) > 128
        || std::abs(wind.y - source.wind.y) > 128 || std::abs(wind.z - source.wind.z) > 4
        || (world_ && (std::abs(position.x - source.cameraXZ.x) > 256
                       || std::abs(position.z - source.cameraXZ.y) > 256));
    if (rebuildCloudOcclusion_)
        source = {region, constants_.cloudLayer, constants_.sunDirection, wind,
                  {position.x, position.z}, constants_.weather.x};
}

void Renderer::updateConstants()
{
    const auto &w = weather_.state();
    auto drift = weather_.wind();
    const auto oldFormations = constants_.formations;
    const auto oldFormationControls = constants_.formationControls;
    const auto previousSun = constants_.sunDirection;
    constants_.formations = formations_.items;
    float cloudBottom = w.cloudBase, cloudTop = w.cloudBase + w.cloudThickness;
    bool rotatingFormation = false;
    const bool formationsEnabled = options_.formationStrength > 0.0001f;
    for (size_t i = 0; i < formations_.count; ++i)
    {
        auto &f = constants_.formations[i];
        f.radius *= options_.formationScale;
        f.height *= options_.formationScale;
        if (formationsEnabled && f.density > 0)
        {
            cloudBottom = std::min(cloudBottom, f.base);
            cloudTop = std::max(cloudTop, f.base + f.height);
            rotatingFormation |= f.kind > 0.5f && std::abs(f.spin * options_.formationSpeed) > 0;
        }
    }
    const float phaseStep =
        static_cast<float>((weather_.time() - previousTime_) * options_.formationSpeed);
    formationPhase_ += phaseStep;
    constants_.formationControls = {formationsEnabled ? static_cast<float>(formations_.count) : 0,
                                    options_.formationStrength, static_cast<float>(formationPhase_),
                                    phaseStep};
    // 曲率で地平線側の世界Yが下がる分も、雲底側の影の積分へ含める。
    const float shadowPlane = cloudBottom - 500;
    constants_.formationLayer = {cloudBottom, cloudTop, shadowPlane, 0};
    const bool formationChanged =
        oldFormationControls.x != constants_.formationControls.x
        || oldFormationControls.y != constants_.formationControls.y
        || std::memcmp(oldFormations.data(), constants_.formations.data(), sizeof(oldFormations))
               != 0;
    if (formationChanged)
    {
        historyValid_ = false;
        shadowValid_ = false;
    }
    float cp = std::cos(camera_.pitch);
    XMVECTOR direction = XMVectorSet(std::sin(camera_.yaw) * cp, std::sin(camera_.pitch),
                                     std::cos(camera_.yaw) * cp, 0);
    XMStoreFloat4(&constants_.cameraForward, direction);
    XMMATRIX view =
        XMMatrixLookToLH(XMLoadFloat3(&camera_.position), direction, XMVectorSet(0, 1, 0, 0));
    // Float reversed-Z preserves ground-level depth precision over the streamed horizon.
    XMMATRIX projection =
        XMMatrixPerspectiveFovLH(XMConvertToRadians(62), static_cast<float>(width_) / height_,
                                 world_ ? 150000.0f : 10.0f, world_ ? 0.15f : 150000.0f);
    XMMATRIX vp = view * projection;
    XMStoreFloat4x4(&constants_.viewProjection, XMMatrixTranspose(vp));
    XMStoreFloat4x4(&constants_.inverseViewProjection,
                    XMMatrixTranspose(XMMatrixInverse(nullptr, vp)));
    constants_.previousViewProjection = historyValid_ ? previousVP_ : constants_.viewProjection;
    constants_.cameraTime = {camera_.position.x, camera_.position.y, camera_.position.z,
                             static_cast<float>(weather_.time())};
    constants_.previousCamera = {previousCamera_.x, previousCamera_.y, previousCamera_.z, 0};
    const float elevation = XMConvertToRadians(options_.elevation),
                azimuth = XMConvertToRadians(options_.azimuth);
    XMFLOAT3 sun{std::sin(azimuth) * std::cos(elevation), std::sin(elevation),
                 std::cos(azimuth) * std::cos(elevation)};
    if (options_.timeOfDay >= 0)
    {
        sun = solarDirection(options_.timeOfDay);
        options_.elevation = XMConvertToDegrees(std::asin(std::clamp(sun.y, -1.0f, 1.0f)));
        options_.azimuth = XMConvertToDegrees(std::atan2(sun.x, sun.z));
    }
    constants_.sunDirection = {sun.x, sun.y, sun.z, 0};
    // RGB は散乱や地表の照明に使う太陽光。w は最後のトーンマップで使う表示露出。
    constants_.solarExposure = {10, 9.65f, 9.1f, options_.exposure};
    constants_.resolution = {static_cast<float>(width_), static_cast<float>(height_), 1.0f / width_,
                             1.0f / height_};
    constants_.cloudLayer = {w.cloudBase, w.cloudThickness, w.coverage, w.density};
    constants_.weather = {w.cloudType, w.precipitation, w.humidity, w.fogDensity};
    constants_.wind = {static_cast<float>(drift.x), static_cast<float>(drift.z),
                       static_cast<float>(weather_.time() * 0.6),
                       static_cast<float>(frameNumber_ % 1024)};
    updateNearClouds();
    float mx = camera_.position.x - previousCamera_.x, my = camera_.position.y - previousCamera_.y,
          mz = camera_.position.z - previousCamera_.z;
    float motion = std::sqrt(mx * mx + my * my + mz * mz);
    const float rotation = std::abs(std::remainder(camera_.yaw - previousYaw_, XM_2PI))
                           + std::abs(camera_.pitch - previousPitch_);
    // 通常移動は画素単位で再投影する。大きな視点・天候・時刻の変更は全体を更新する。
    if (motion > 120 || rotation > 0.12f || weather_.time() - previousTime_ > 0.12
        || std::abs(w.coverage - previousLayer_.z) > 0.025f
        || std::abs(w.cloudBase - previousLayer_.x) > 80
        || std::abs(w.cloudThickness - previousLayer_.y) > 100
        || std::abs(w.density - previousLayer_.w) > 0.08f)
        historyValid_ = false;
    float flash = options_.lightning ? weather_.lightning() : 0;
    if (lightningSerial_ != weather_.lightningSerial())
    {
        lightningSerial_ = weather_.lightningSerial();
        const auto seed = weather_.lightningSeed();
        const float angle = camera_.yaw + (static_cast<float>(seed & 65535) / 65535 - 0.5f) * 0.8f;
        const float distance = 6500 + ((seed >> 16) & 65535) * (7000.0f / 65535);
        const float x = camera_.position.x + std::sin(angle) * distance;
        const float z = camera_.position.z + std::cos(angle) * distance;
        lightningTarget_ = {x, (world_ ? world_->ground(x, z) : terrainHeight(x, z)) + 2, z};
        lightningSource_ = {
            x + 180, std::max(w.cloudBase + w.cloudThickness * 0.42f, lightningTarget_.y + 1200),
            z - 100};
        historyValid_ = false;
    }
    if (std::abs(lastElevation_ - options_.elevation) > 0.4f || flash > 0.002f
        || lastLightning_ > 0.002f)
        historyValid_ = false;
    constants_.previousWind = {static_cast<float>(previousWind_.x),
                               static_cast<float>(previousWind_.z), motion > 15 ? 0.65f : 0.89f,
                               historyValid_ ? 1.0f : 0.0f};
    fullCloudRefresh_ = options_.checkerboard && !historyValid_;
    checkerActive_ = options_.checkerboard && historyValid_;
    const bool fourPhase = options_.checkerboard && fastClassic();
    const uint64_t phaseMask = fourPhase ? 3 : 1;
    constants_.checkerboard = {checkerActive_ ? (fourPhase ? 2.0f : 1.0f) : 0.0f,
                               static_cast<float>(frameNumber_ & phaseMask),
                               static_cast<float>(rawCloudWidth_), static_cast<float>(rawCloudHeight_)};
    // 雲影は48km四方。中心をテクセル単位に揃え、カメラ移動時のちらつきを抑える。
    constexpr float span = 48000;
    float texel = span / shadowSize_;
    float centerX =
        camera_.position.x + sun.x * (shadowPlane - camera_.position.y) / std::max(sun.y, 0.02f);
    float centerZ =
        camera_.position.z + sun.z * (shadowPlane - camera_.position.y) / std::max(sun.y, 0.02f);
    constants_.shadowRegion = {std::floor(centerX / texel) * texel,
                               std::floor(centerZ / texel) * texel, span,
                               static_cast<float>(shadowSize_)};
    int q = static_cast<int>(options_.quality);
    constants_.renderSize = {static_cast<float>(cloudWidth_), static_cast<float>(cloudHeight_),
                             static_cast<float>(samples[q]), static_cast<float>(lightSamples[q])};
    constants_.controls = {static_cast<float>(options_.debugView), flash,
                           options_.shadows ? 1.0f : 0.0f, options_.clouds ? 1.0f : 0.0f};
    // 雲影は最大4フレーム共有する。風による移動はサンプル時に毎フレーム補正する。
    // 雲形・太陽・地図範囲が変わったときと、時間が大きく進んだときは即座に更新する。
    const bool shareLighting = !options_.fullCloudLighting && options_.quality != Quality::Ultra;
    const uint64_t shadowInterval = shareLighting ? 4 : 1;
    const float controlKey = constants_.controls.z + constants_.controls.w * 2;
    updateShadow_ =
        !shadowValid_ || rotatingFormation || frameNumber_ - shadowFrame_ >= shadowInterval
        || weather_.time() - shadowTime_ >= 1.0 / 15.0 - 1e-6
        || std::memcmp(&shadowLayer_, &constants_.cloudLayer, sizeof(shadowLayer_)) != 0
        || std::memcmp(&shadowRegion_, &constants_.shadowRegion, sizeof(shadowRegion_)) != 0
        || std::memcmp(&shadowSun_, &constants_.sunDirection, sizeof(shadowSun_)) != 0
        || shadowType_ != constants_.weather.x || shadowControls_ != controlKey
        || cachedCloudMapWeather_.z != constants_.weather.y;
    if (updateShadow_)
    {
        shadowLayer_ = constants_.cloudLayer;
        shadowRegion_ = constants_.shadowRegion;
        shadowSun_ = constants_.sunDirection;
        shadowType_ = constants_.weather.x;
        shadowControls_ = controlKey;
        shadowWind_ = {constants_.wind.x, constants_.wind.y};
        shadowTime_ = weather_.time();
        shadowFrame_ = frameNumber_;
        shadowValid_ = true;
    }
    constants_.cloudPerformance = {constants_.wind.x - shadowWind_.x,
                                   constants_.wind.y - shadowWind_.y, shareLighting ? 1.0f : 0.0f,
                                   static_cast<float>(weather_.time() - shadowTime_)};
    // 湿度でエアロゾルを増やす。x が変われば太陽透過率 LUT も同じ係数で更新する。
    constants_.atmosphere = {1 + w.humidity * 1.5f, 0, 150000, 0};
    constants_.weatherEffects = {weather_.wetness(), w.windX, w.windZ, options_.rain ? 1.0f : 0};
    constants_.lightningSource = {lightningSource_.x, lightningSource_.y, lightningSource_.z,
                                  static_cast<float>(weather_.lightningSeed() & 4095)};
    constants_.lightningTarget = {lightningTarget_.x, lightningTarget_.y, lightningTarget_.z,
                                  static_cast<float>(std::min(weather_.lightningAge(), 1000.0))};
    // 幅に余裕があるときは一覧の右側にプレビューを収め、テクスチャ全体を見せる。
    const float previewLeft = options_.ui && options_.textureViewer && width_ >= 1000 ? 608.0f : 0;
    constants_.textureInspection = {options_.textureSlice, static_cast<float>(options_.textureAxis),
                                    previewLeft, 0};
    // 地形シャドウは太陽方向から65km四方を正射影する単一の深度マップ。
    XMVECTOR center = XMVectorSet(camera_.position.x, 0, camera_.position.z + 5000, 1);
    XMVECTOR light = XMVectorSet(sun.x, sun.y, sun.z, 0);
    XMMATRIX lightView = XMMatrixLookAtLH(center + light * 45000, center,
                                          std::abs(sun.y) > 0.98f ? XMVectorSet(0, 0, 1, 0)
                                                                  : XMVectorSet(0, 1, 0, 0));
    XMStoreFloat4x4(
        &constants_.lightViewProjection,
        XMMatrixTranspose(lightView * XMMatrixOrthographicLH(65000, 65000, 100, 100000)));
    bool localShadows = false;
    if (world_ && sun.y > 0.02f)
    {
        float x = camera_.position.x + std::sin(camera_.yaw) * 76;
        float z = camera_.position.z + std::cos(camera_.yaw) * 76;
        float y = world_->ground(x, z);
        localShadows = camera_.position.y - y < 480;
        if (localShadows)
        {
            center = XMVectorSet(x, y, z, 1);
            XMVECTOR up =
                std::abs(sun.y) > 0.98f ? XMVectorSet(0, 0, 1, 0) : XMVectorSet(0, 1, 0, 0);
            XMMATRIX nearView = XMMatrixLookAtLH(center + light * 750, center, up);
            constexpr float spanNear = 384;
            // Snap the shadow projection to the same world-space texels during walking.
            XMVECTOR origin = XMVector3TransformCoord(XMVectorZero(), nearView);
            constexpr float texelNear = spanNear / 2048;
            nearView.r[3] += XMVectorSet(
                std::round(XMVectorGetX(origin) / texelNear) * texelNear - XMVectorGetX(origin),
                std::round(XMVectorGetY(origin) / texelNear) * texelNear - XMVectorGetY(origin), 0,
                0);
            XMStoreFloat4x4(
                &constants_.nearLightViewProjection,
                XMMatrixTranspose(nearView * XMMatrixOrthographicLH(spanNear, spanNear, 10, 1600)));
        }
    }
    constants_.worldRendering = {world_ ? 1.0f : 0.0f, localShadows ? 1.0f : 0.0f,
                                 options_.timeOfDay >= 0 ? 1.0f : 0.0f, 0};
    updateCloudOcclusion(shareLighting, previousSun);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    require(context_->Map(frameBuffer_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped),
            "Map frame constants");
    std::memcpy(mapped.pData, &constants_, sizeof(constants_));
    context_->Unmap(frameBuffer_.Get(), 0);
    ID3D11Buffer *cb = frameBuffer_.Get();
    context_->VSSetConstantBuffers(0, 1, &cb);
    context_->PSSetConstantBuffers(0, 1, &cb);
    context_->CSSetConstantBuffers(0, 1, &cb);
    ID3D11SamplerState *samplers[] = {linearClamp_.Get(), linearWrap_.Get(), shadowSampler_.Get()};
    context_->PSSetSamplers(0, 3, samplers);
    ID3D11SamplerState *terrainSampler = terrainSampler_.Get();
    context_->PSSetSamplers(8, 1, &terrainSampler);
    context_->CSSetSamplers(0, 3, samplers);
    previousVP_ = constants_.viewProjection;
    previousWind_ = drift;
    previousCamera_ = camera_.position;
    previousYaw_ = camera_.yaw;
    previousPitch_ = camera_.pitch;
    previousTime_ = weather_.time();
    previousLayer_ = constants_.cloudLayer;
    lastElevation_ = options_.elevation;
    lastLightning_ = flash;
}

void Renderer::drawGeometry(bool shadow, bool localPass)
{
    const ShaderResources empty{};
    context_->PSSetShaderResources(0, shaderResourceCount, empty.data());
    D3D11_VIEWPORT viewport{0,
                            0,
                            static_cast<float>(shadow ? 2048 : width_),
                            static_cast<float>(shadow ? 2048 : height_),
                            0,
                            1};
    context_->RSSetViewports(1, &viewport);
    context_->RSSetState(shadow ? shadowRaster_.Get() : raster_.Get());
    context_->OMSetDepthStencilState(!shadow && world_ ? reversedDepth_.Get() : depthOn_.Get(), 0);
    context_->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    const XMFLOAT4X4 &projection = localPass ? constants_.nearLightViewProjection
                                   : shadow  ? constants_.lightViewProjection
                                             : constants_.viewProjection;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    require(context_->Map(passBuffer_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped),
            "Map geometry pass");
    std::memcpy(mapped.pData, &projection, sizeof(projection));
    context_->Unmap(passBuffer_.Get(), 0);
    ID3D11Buffer *pass = passBuffer_.Get();
    context_->VSSetConstantBuffers(2, 1, &pass);
    if (shadow)
    {
        ID3D11DepthStencilView *depth = localPass ? nearDepthView_.Get() : terrainDepthView_.Get();
        context_->ClearDepthStencilView(depth, D3D11_CLEAR_DEPTH, 1, 0);
        context_->OMSetRenderTargets(0, nullptr, depth);
        context_->VSSetShader(shaders_.shadowVS.Get(), nullptr, 0);
        context_->PSSetShader(nullptr, nullptr, 0);
    }
    else
    {
        const float clear[] = {0, 0, 0, 0};
        context_->ClearRenderTargetView(albedo_.rtv.Get(), clear);
        context_->ClearRenderTargetView(normals_.rtv.Get(), clear);
        context_->ClearRenderTargetView(surface_.rtv.Get(), clear);
        context_->ClearDepthStencilView(depthView_.Get(), D3D11_CLEAR_DEPTH, world_ ? 0.0f : 1.0f,
                                        0);
        ID3D11RenderTargetView *rt[] = {albedo_.rtv.Get(), normals_.rtv.Get(), surface_.rtv.Get()};
        context_->OMSetRenderTargets(3, rt, depthView_.Get());
        context_->VSSetShader(shaders_.geometryVS.Get(), nullptr, 0);
        context_->PSSetShader(shaders_.geometryPS.Get(), nullptr, 0);
        ID3D11ShaderResourceView *maps[] = {world_ ? detailNoise_.Get() : nullptr,
                                            weatherMap_.srv.Get()};
        context_->PSSetShaderResources(1, 2, maps);
        if (world_)
            world_->bindTerrainMaterials(context_.Get());
    }
    context_->IASetInputLayout(shaders_.geometryLayout.Get());
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    if (world_)
        world_->drawTerrain(context_.Get(), XMMatrixTranspose(XMLoadFloat4x4(&projection)));
    else
    {
        const UINT stride = sizeof(TerrainVertex), offset = 0;
        ID3D11Buffer *vertex = vertices_.Get();
        context_->IASetVertexBuffers(0, 1, &vertex, &stride, &offset);
        context_->IASetIndexBuffer(indices_.Get(), DXGI_FORMAT_R32_UINT, 0);
        context_->DrawIndexed(indexCount_, 0, 0);
    }
    context_->IASetInputLayout(shaders_.meshLayout.Get());
    context_->VSSetShader(shaders_.meshVS.Get(), nullptr, 0);
    context_->PSSetShader(shadow ? nullptr : shaders_.meshPS.Get(), nullptr, 0);
    if (world_ && (localPass || !shadow))
        world_->drawPlants(context_.Get(), shadow, shaders_.meshShadowPS.Get());
    for (const Mesh &mesh : model_.meshes)
    {
        auto *raster = mesh.doubleSided ? (shadow ? shadowRaster_.Get() : raster_.Get())
                                        : (shadow ? meshShadowRaster_.Get() : meshRaster_.Get());
        context_->RSSetState(raster);
        if (shadow)
            context_->PSSetShader(mesh.alphaMask ? shaders_.meshShadowPS.Get() : nullptr, nullptr,
                                  0);
        mesh.draw(context_.Get(), model_.instance.Get(), 1, shadow);
    }
    if (world_ && world_->grass() && (localPass || !shadow))
    {
        context_->RSSetState(shadow ? shadowRaster_.Get() : raster_.Get());
        context_->IASetInputLayout(nullptr);
        context_->VSSetShader(shaders_.grassVS.Get(), nullptr, 0);
        context_->PSSetShader(shadow ? nullptr : shaders_.grassPS.Get(), nullptr, 0);
        world_->grass()->draw(context_.Get(), shadow);
    }
    ID3D11ShaderResourceView *emptyMaterials[12]{};
    context_->PSSetShaderResources(32, 12, emptyMaterials);
    context_->OMSetRenderTargets(0, nullptr, nullptr);
    context_->PSSetShaderResources(0, shaderResourceCount, empty.data());
}

void Renderer::drawRain()
{
    const ShaderResources empty{};
    context_->PSSetShaderResources(0, shaderResourceCount, empty.data());
    const float clear[] = {0, 0, 0, 0};
    context_->ClearRenderTargetView(rain_.rtv.Get(), clear);
    if (!options_.rain || weather_.state().precipitation <= 0.001f)
        return;
    D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width_), static_cast<float>(height_), 0, 1};
    context_->RSSetViewports(1, &viewport);
    context_->RSSetState(raster_.Get());
    context_->OMSetDepthStencilState(depthOff_.Get(), 0);
    context_->OMSetBlendState(rainBlend_.Get(), nullptr, 0xffffffff);
    ID3D11RenderTargetView *target = rain_.rtv.Get();
    context_->OMSetRenderTargets(1, &target, nullptr);
    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(shaders_.rainVS.Get(), nullptr, 0);
    context_->PSSetShader(shaders_.rainPS.Get(), nullptr, 0);
    auto input = resources();
    input[18] = nullptr;
    context_->PSSetShaderResources(0, shaderResourceCount, input.data());
    constexpr std::array<UINT, 4> particles{4096, 8192, 12288, 16384};
    context_->DrawInstanced(6, particles[static_cast<int>(options_.quality)], 0, 0);
    context_->PSSetShaderResources(0, shaderResourceCount, empty.data());
    context_->OMSetRenderTargets(0, nullptr, nullptr);
    context_->OMSetBlendState(nullptr, nullptr, 0xffffffff);
}

void Renderer::moveCamera(float forward, float side, float vertical, double dt, bool fast)
{
    if (forward == 0 && side == 0 && (walking_ || vertical == 0))
        return;
    if (walking_)
    {
        float length = std::max(std::hypot(forward, side), 1.0f);
        forward /= length;
        side /= length;
    }
    else if (world_)
    {
        // 飛行中の前進は視線方向。EとQはカメラの傾きに依存せず垂直に動く。
        vertical += forward * std::sin(camera_.pitch);
        forward *= std::cos(camera_.pitch);
    }
    float speed =
        static_cast<float>(dt) * (walking_ ? (fast ? 8.4f : 4.2f) : (fast ? 2200.0f : 400.0f));
    float x = speed * (forward * std::sin(camera_.yaw) + side * std::cos(camera_.yaw));
    float z = speed * (forward * std::cos(camera_.yaw) - side * std::sin(camera_.yaw));
    if (walking_)
        world_->walk(camera_.position, x, z);
    else
    {
        camera_.position.x += x;
        camera_.position.z += z;
        if (world_)
        {
            camera_.position.x = std::clamp(camera_.position.x, -worldLimit, worldLimit);
            camera_.position.z = std::clamp(camera_.position.z, -worldLimit, worldLimit);
        }
        camera_.position.y += speed * vertical;
        float ground = world_ ? world_->ground(camera_.position.x, camera_.position.z)
                              : terrainHeight(camera_.position.x, camera_.position.z);
        camera_.position.y = std::max(camera_.position.y, ground + (world_ ? eyeHeight : 12.0f));
    }
}

void Renderer::frame(double dt, bool focused)
{
    auto begin = std::chrono::steady_clock::now();
    if (focused && !options_.headless && options_.cameraPath.empty())
    {
        float forward = static_cast<float>((GetAsyncKeyState('W') & 0x8000) != 0)
                        - static_cast<float>((GetAsyncKeyState('S') & 0x8000) != 0);
        float side = static_cast<float>((GetAsyncKeyState('D') & 0x8000) != 0)
                     - static_cast<float>((GetAsyncKeyState('A') & 0x8000) != 0);
        float vertical = static_cast<float>((GetAsyncKeyState('E') & 0x8000) != 0)
                         - static_cast<float>((GetAsyncKeyState('Q') & 0x8000) != 0);
        moveCamera(forward, side, vertical, std::min(dt, 0.1),
                   (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0);
    }
    if (!paused_)
    {
        weather_.update(dt);
        if (timeLapse_ && options_.timeOfDay >= 0)
        {
            double day = options_.daySeconds > 0 ? options_.daySeconds : 720;
            options_.timeOfDay =
                static_cast<float>(std::fmod(options_.timeOfDay + dt * 24 / day, 24));
        }
        else if (timeLapse_)
        {
            options_.elevation += static_cast<float>(dt) * 0.8f;
            if (options_.elevation > 85)
                options_.elevation = -14;
        }
    }
    if (options_.lightningAt >= 0 && weather_.time() + 1e-8 >= options_.lightningAt)
    {
        weather_.triggerLightning();
        options_.lightningAt = -1;
    }
    // 固定時刻でA/B比較できる、移動・視点切り替え用の検証経路。
    const float pathTime = static_cast<float>(weather_.time());
    if (options_.cameraPath == "walk")
    {
        // Follow the same path and grounded motion as interactive walking.
        float z = camera_.position.z;
        if (!options_.startLook)
            camera_.yaw = std::atan(0.088f * (std::cos(z * 0.022f) + std::cos(z * 0.008f)));
        moveCamera(1, 0, 0, dt, false);
    }
    if (options_.cameraPath == "pan")
    {
        camera_.position = {450 * std::sin(pathTime * 0.45f), 330, -1600};
        camera_.yaw = 0.35f * std::sin(pathTime * 0.9f);
        camera_.pitch = 0.11f + 0.08f * std::sin(pathTime * 0.5f);
        camera_.position.y = std::max(camera_.position.y,
                                      terrainHeight(camera_.position.x, camera_.position.z) + 12);
    }
    if (options_.cameraPath == "tower-orbit")
    {
        const float angle = pathTime * 0.18f;
        camera_.position = {-5600 + 10000 * std::sin(angle), 5600, 7000 - 10000 * std::cos(angle)};
        camera_.yaw = -angle;
        camera_.pitch = 0.16f;
    }
    if (options_.cameraPath == "cut")
    {
        const int cut = static_cast<int>((weather_.time() + 1e-6) / 2) % 3;
        if (cut != cameraCut_)
        {
            cameraCut_ = cut;
            options_.camera = cut == 1 ? "overview" : (cut == 2 ? "inside" : "valley");
            resetCamera();
        }
    }
    // UIの変更を先に適用し、そのフレームで使う天候・カメラ定数をGPUへ送る。
    if (options_.ui)
        drawUi();
    if (world_)
        world_->update(context_.Get(), camera_.position);
    updateConstants();
    startTiming();

    const auto &cloudShaders = shaders_.cloudStyles[static_cast<size_t>(options_.cloudStyle)];
    const bool fast = fastClassic();
    auto *march = fast ? shaders_.fastClassicMarchCS.Get() : cloudShaders.marchCS.Get();
    auto *temporal = fast ? shaders_.fastClassicTemporalCS.Get() : shaders_.temporalCS.Get();
    auto *repair = fast ? shaders_.fastClassicRepairCS.Get() : cloudShaders.repairCS.Get();

    // 1. 大気の太陽透過率LUT → 雲の配置・高度LUT → 雲影。
    auto input = resources();
    // LUTの内容は湿度由来のエアロゾル倍率だけに依存する。静止天候では再利用する。
    // 太陽が動いたときは参照する角度が変わる。LUT 自体は全角度を保持している。
    if (cachedAerosol_ != constants_.atmosphere.x)
    {
        // 書き込む LUT を SRV 一覧から外し、このディスパッチでは UAV として使う。
        input[16] = nullptr;
        compute(shaders_.transmittanceCS.Get(), 32, 8, 1, {transmittance_.uav.Get()}, input);
        cachedAerosol_ = constants_.atmosphere.x;
        ++atmosphereUpdates_;
    }
    const XMFLOAT4 cloudMapWeather{constants_.cloudLayer.z, constants_.weather.x,
                                   constants_.weather.y, constants_.sunDirection.y};
    if (std::memcmp(&cachedCloudMapWeather_, &cloudMapWeather, sizeof(cloudMapWeather)) != 0)
    {
        input = resources();
        input[22] = input[23] = nullptr;
        compute(cloudShaders.mapCS.Get(), 64, 64, 1,
                {cloudMap_.uav.Get(), cloudHeightLut_.uav.Get()}, input);
        cachedCloudMapWeather_ = cloudMapWeather;
    }
    if (updateShadow_)
    {
        input = resources();
        input[3] = nullptr;
        compute(cloudShaders.shadowCS.Get(), (shadowSize_ + 7) / 8, (shadowSize_ + 7) / 8, 1,
                {shadowMap_.uav.Get()}, input);
        // 地面や霧のサンプルは、雲から遠いほど粗いミップを読んで軟らかい影を作る。
        context_->GenerateMips(shadowMap_.srv.Get());
        ++shadowUpdates_;
    }
    stamp(1);

    // 2. 地形の深度シャドウ → ディファード描画用G-buffer。
    if (world_ && world_->grass())
        world_->grass()->select(context_.Get(), shaders_.grassPlacementCS.Get(), camera_.position,
                                constants_.viewProjection);
    drawGeometry(true);
    if (constants_.worldRendering.y > 0.5f)
        drawGeometry(true, true);
    drawGeometry(false);
    stamp(2);

    // 3. 背景の空 → 視線方向の雲レイマーチ。
    // 背景の空と、後段で地表と霧に使う環境光を準備する。
    input = resources();
    input[7] = nullptr;
    compute(shaders_.skyCS.Get(), 40, 23, 1, {sky_.uav.Get()}, input);
    input[25] = nullptr;
    compute(shaders_.skyAmbientCS.Get(), 1, 1, 1, {skyAmbient_.uav.Get()}, input);
    stamp(3);
    if (constants_.nearCloudParams.x > 0)
    {
        compute(cloudShaders.nearCloudCS.Get(), (nearCloudWidth + 3) / 4,
                (nearCloudHeight + 3) / 4, (nearCloudSlices + 3) / 4,
                {nearCloudLight_.uav.Get()}, resources());
        input = resources();
        input[28] = nearCloudLight_.srv.Get();
        input[31] = nullptr;
        compute(shaders_.nearCloudIntegrateCS.Get(), (nearCloudWidth + 7) / 8,
                (nearCloudHeight + 7) / 8, 1, {nearCloud_.uav.Get(), nearCloudMoment_.uav.Get()},
                input);
        ++nearCloudUpdates_;
    }
    if (rebuildCloudOcclusion_)
    {
        compute(shaders_.cloudOcclusionCS.Get(), cloudOcclusionXZ / 4, cloudOcclusionY / 4,
                cloudOcclusionXZ / 4, {cloudOcclusion_.uav.Get()}, resources());
        ++cloudOcclusionUpdates_;
    }
    // 再投影先の経過フレーム数も、色と深度の履歴と同じタイミングで交換する。
    if (options_.classicFast)
        std::swap(reconstruction_, previousReconstruction_);
    input = resources();
    input[19] = nullptr;
    if (fast)
        input[29] = cloudOcclusion_.srv.Get();
    const UINT clearMask[4]{};
    const int write = 1 - historyIndex_;
    if (fullCloudRefresh_)
    {
        // 最初のフレームと視点切り替え時は履歴側へ全画素を直接描く。
        // これにより、通常フレームの生バッファは半分の容量でよい。
        context_->ClearUnorderedAccessViewUint(reconstruction_.uav.Get(), clearMask);
        compute(march, (cloudWidth_ + 7) / 8, (cloudHeight_ + 7) / 8, 1,
                {history_[write].uav.Get(), historyMeta_[write].uav.Get()}, input);
        ++fullCloudFrames_;
    }
    else
    {
        compute(march, (rawCloudWidth_ + 7) / 8, (rawCloudHeight_ + 7) / 8, 1,
                {cloudRaw_.uav.Get(), metaRaw_.uav.Get()}, input);
        if (checkerActive_)
            ++checkerFrames_;
    }
    stamp(4);

    // 4. 風とカメラ移動を補正して履歴を再投影し、未計算画素を再構成する。
    if (!fullCloudRefresh_)
    {
        input = resources();
        input[8] = cloudRaw_.srv.Get();
        input[9] = metaRaw_.srv.Get();
        input[10] = history_[historyIndex_].srv.Get();
        input[11] = historyMeta_[historyIndex_].srv.Get();
        input[19] = nullptr;
        if (fast)
            input[30] = previousReconstruction_.srv.Get();
        compute(
            temporal, (cloudWidth_ + 7) / 8, (cloudHeight_ + 7) / 8, 1,
            {history_[write].uav.Get(), historyMeta_[write].uav.Get(), reconstruction_.uav.Get()},
            input);
        if (checkerActive_)
        {
            // 履歴が成立しなかった未計算画素だけ、同じ積分で埋め直す。
            // historyIndex_は修復完了まで切り替えず、出力とのSRV競合を防ぐ。
            input = resources();
            // 位相による明るさの差を避けるため、通常描画と同じ照明の共有条件を使う。
            if (fast)
                input[29] = cloudOcclusion_.srv.Get();
            compute(repair, (cloudWidth_ + 7) / 8, (cloudHeight_ + 7) / 8, 1,
                    {history_[write].uav.Get(), historyMeta_[write].uav.Get()}, input);
        }
    }
    // 補完済みの雲の RGB・透過率・代表距離を、以降の大気計算と最終合成で使う。
    historyIndex_ = write;
    stamp(5);

    // 5. 雲の代表距離・地形深度までの大気散乱と、影を受ける地表霧。
    // 縦横 1/4 解像度で出力し、CompositePS が地形との深度差を見ながら補間する。
    input = resources();
    input[12] = input[13] = input[14] = nullptr;
    input[28] = nearCloudMoment_.srv.Get();
    compute(shaders_.aerialCS.Get(), (aerialWidth_ + 7) / 8, (aerialHeight_ + 7) / 8, 1,
            {aerialScatter_.uav.Get(), aerialTransmittance_.uav.Get(), fog_.uav.Get()}, input);
    stamp(6);

    // 6. 奥行きで遮蔽される雨粒をHDRバッファへ描き、すべての照明と一緒に合成する。
    drawRain();
    D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width_), static_cast<float>(height_), 0, 1};
    context_->RSSetViewports(1, &viewport);
    context_->RSSetState(raster_.Get());
    context_->OMSetDepthStencilState(depthOff_.Get(), 0);
    const bool filterEdges = world_ && options_.debugView == 0;
    ID3D11RenderTargetView *rt = filterEdges ? sceneColor_.rtv.Get() : finalColor_.rtv.Get();
    context_->OMSetRenderTargets(1, &rt, nullptr);
    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(shaders_.fullscreenVS.Get(), nullptr, 0);
    // 全画面で地表・空・雲・霧・雨を線形色のまま合成し、最後に表示用へ変換する。
    context_->PSSetShader(shaders_.compositePS.Get(), nullptr, 0);
    input = resources();
    // 生の雲は合成パスでだけ読む。CloudCSのUAVと同時に束縛しない。
    input[17] = fullCloudRefresh_ ? history_[historyIndex_].srv.Get() : cloudRaw_.srv.Get();
    context_->PSSetShaderResources(0, shaderResourceCount, input.data());
    context_->Draw(3, 0);
    if (filterEdges)
    {
        rt = finalColor_.rtv.Get();
        context_->OMSetRenderTargets(1, &rt, nullptr);
        context_->PSSetShader(shaders_.resolveEdgesPS.Get(), nullptr, 0);
        ID3D11ShaderResourceView *color = sceneColor_.srv.Get();
        context_->PSSetShaderResources(28, 1, &color);
        context_->Draw(3, 0);
    }
    if (options_.ui)
        ui_.draw(context_.Get());

    // 7. 完成画像をスワップチェーンへコピーして表示する。
    const ShaderResources empty{};
    context_->PSSetShaderResources(0, shaderResourceCount, empty.data());
    context_->OMSetRenderTargets(0, nullptr, nullptr);
    ComPtr<ID3D11Texture2D> back;
    require(swapchain_->GetBuffer(0, IID_PPV_ARGS(&back)), "Present buffer");
    context_->CopyResource(back.Get(), finalColor_.texture.Get());
    stamp(7);
    endTiming();
    if (!options_.headless)
        require(swapchain_->Present(options_.vsync ? 1 : 0, 0), "Present");
    require(device_->GetDeviceRemovedReason(), "Device health");
    historyValid_ = true;
    ++frameNumber_;
    pointerPressed_ = false;
    double measured =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
    cpuMs_ = cpuMs_ == 0 ? measured : std::lerp(cpuMs_, measured, 0.08);
}

void Renderer::startTiming()
{
    auto &slot = timing_[frameNumber_ % timing_.size()];
    timingActive_ = false;
    activeTiming_ = nullptr;
    if (slot.pending)
    {
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT d{};
        // Bound the queue to six frames, including offscreen runs without Present.
        context_->Flush();
        HRESULT status = S_FALSE;
        while ((status = context_->GetData(slot.disjoint.Get(), &d, sizeof(d),
                                           D3D11_ASYNC_GETDATA_DONOTFLUSH))
               == S_FALSE)
            Sleep(1);
        require(status, "GPU timer resolve");
        std::array<uint64_t, 8> times{};
        bool ready = true;
        for (size_t i = 0; i < times.size(); i++)
            if (context_->GetData(slot.stamps[i].Get(), &times[i], sizeof(uint64_t),
                                  D3D11_ASYNC_GETDATA_DONOTFLUSH)
                != S_OK)
                ready = false;
        if (!ready)
            return;
        if (!d.Disjoint && d.Frequency > 0)
        {
            for (size_t i = 0; i < gpuMs_.size(); i++)
            {
                double ms = (times[i + 1] - times[i]) * 1000.0 / d.Frequency;
                gpuMs_[i] = timingSamples_ ? std::lerp(gpuMs_[i], ms, 0.12) : ms;
            }
            ++timingSamples_;
        }
        slot.pending = false;
    }
    activeTiming_ = &slot;
    timingActive_ = true;
    context_->Begin(slot.disjoint.Get());
    stamp(0);
}

void Renderer::stamp(int index)
{
    if (timingActive_)
        context_->End(activeTiming_->stamps[index].Get());
}

void Renderer::endTiming()
{
    if (timingActive_)
    {
        context_->End(activeTiming_->disjoint.Get());
        activeTiming_->pending = true;
    }
}

void Renderer::drawUi()
{
    ui_.begin(width_, height_, pointerX_, pointerY_, pointerDown_, pointerPressed_);
    if (options_.textureViewer)
    {
        drawTextureInspector();
    }
    else
    {
        ui_.rect(24, 24, 298, 467, 0xda171d19);
        ui_.rect(24, 24, 298, 3, 0xffa5dbb8);
        ui_.text(44, 41, "C I R R U S", 0xffe9fff1, 1.18f);
        if (ui_.button(44, 77, 122, 28, "DEMO [F6]", weather_.demo(), 0.68f))
        {
            weather_.setDemo(!weather_.demo());
            options_.debugView = 0;
        }
        if (ui_.button(176, 77, 122, 28, "FLASH [L]", false, 0.68f))
            weather_.triggerLightning();
        char line[256];
        double gpu = 0;
        for (double ms : gpuMs_)
            gpu += ms;
        std::snprintf(line, sizeof(line), "FPS %5.1f | GPU %5.2f ms",
                      cpuMs_ > 0 ? 1000 / cpuMs_ : 0, gpu);
        ui_.text(44, 112, line, 0xffc5d2c9, 0.73f);
        std::snprintf(line, sizeof(line), "Frame %4.2f | Cloud %4.2f ms", cpuMs_, gpuMs_[3]);
        ui_.text(44, 138, line, 0xff9bafa4, 0.73f);
        std::snprintf(line, sizeof(line), "RAIN %3.0f%% | WET %3.0f%%",
                      weather_.state().precipitation * 100, weather_.wetness() * 100);
        ui_.text(44, 160, line, 0xff9bafa4, 0.66f);
        std::snprintf(line, sizeof(line), "%s  %3.0f%%", weatherName(weather_.target()).data(),
                      weather_.transitionProgress() * 100);
        ui_.text(44, 178, line, 0xffc5e3cf, 0.80f);
        if (options_.timeOfDay >= 0)
        {
            const int minutes = static_cast<int>(options_.timeOfDay * 60) % 1440;
            std::snprintf(line, sizeof(line), "SOLAR TIME %02d:%02d", minutes / 60, minutes % 60);
            if (ui_.slider(44, 214, 254, line, options_.timeOfDay, 0, 23.999f))
                historyValid_ = false;
            if (ui_.button(44, 275, 130, 30, timeLapse_ ? "STOP TIME [T]" : "RUN TIME [T]",
                           timeLapse_, 0.66f))
                timeLapse_ = !timeLapse_;
            if (world_ && options_.cameraPath.empty()
                && ui_.button(179, 275, 119, 30, walking_ ? "TAKE OFF [G]" : "LAND [G]", false,
                              0.66f))
                key('G');
        }
        else
        {
            std::snprintf(line, sizeof(line), "SUN ELEVATION  %.1f deg", options_.elevation);
            if (ui_.slider(44, 214, 254, line, options_.elevation, -14, 85))
                historyValid_ = false;
            std::snprintf(line, sizeof(line), "SUN AZIMUTH    %.1f deg", options_.azimuth);
            if (ui_.slider(44, 273, 254, line, options_.azimuth, -180, 180))
                historyValid_ = false;
        }
        std::snprintf(line, sizeof(line), "EXPOSURE       %.2f", options_.exposure);
        ui_.slider(44, 332, 254, line, options_.exposure, 0.2f, 3.0f);
        if (ui_.button(44, 397, 80, 34, qualityNames[static_cast<int>(options_.quality)], false,
                       0.7f))
        {
            options_.quality = static_cast<Quality>((static_cast<int>(options_.quality) + 1) % 4);
            makeTargets();
        }
        if (ui_.button(132, 397, 64, 34, "AUTO", weather_.automatic(), 0.7f))
            weather_.setAutomatic(!weather_.automatic());
        const char *checkerLabel = fastClassic() ? "CB4 [F7]" : "CB [F7]";
        if (ui_.button(204, 397, 94, 34, checkerLabel, options_.checkerboard, 0.7f))
        {
            options_.checkerboard = !options_.checkerboard;
            makeTargets();
        }
        const char *styleLabel =
            options_.cloudStyle == CloudStyle::Classic ? "CLASSIC [F4]" : "CUMULUS [F4]";
        if (ui_.button(44, 447, 122, 32, styleLabel, false, 0.7f))
            key(VK_F4);
        if (ui_.button(176, 447, 122, 32, "TEXTURES [F3]", false, 0.7f))
            options_.textureViewer = true;
        if (width_ >= 920)
        {
            constexpr std::array labels{"CLEAR", "PARTLY", "OVERCAST", "RAIN", "STORM"};
            float x = static_cast<float>(width_) - 592;
            for (int i = 0; i < 5; i++)
                if (ui_.button(x + i * 112, 28, 104, 34, labels[i],
                               static_cast<int>(weather_.target()) == i))
                    weather_.transitionTo(static_cast<WeatherKind>(i));
        }
        if (width_ >= 1000)
        {
            const float x = static_cast<float>(width_) - 322;
            ui_.rect(x, 82, 298, 332, 0xda171d19);
            ui_.text(x + 18, 97, "CLOUD FORMATIONS [F8]", 0xffe9fff1, 0.78f);
            constexpr std::array modes{"none", "towers", "vortex", "mixed"};
            constexpr std::array labels{"OFF", "TOWERS", "VORTEX", "MIXED"};
            for (int i = 0; i < 4; ++i)
                if (ui_.button(x + 18 + (i % 2) * 134, 128.0f + (i / 2) * 37.0f, 126, 29, labels[i],
                               options_.formationMode == modes[i], 0.68f))
                    setFormations(modes[i]);
            std::snprintf(line, sizeof(line), "STRENGTH  %.2f", options_.formationStrength);
            ui_.slider(x + 18, 207, 260, line, options_.formationStrength, 0, 2);
            std::snprintf(line, sizeof(line), "SIZE      %.2f", options_.formationScale);
            ui_.slider(x + 18, 252, 260, line, options_.formationScale, 0.5f, 1.6f);
            std::snprintf(line, sizeof(line), "SPIN      %.2f", options_.formationSpeed);
            ui_.slider(x + 18, 297, 260, line, options_.formationSpeed, -3, 3);
            if (ui_.button(x + 18, 365, 260, 29, "FOCUS FORMATIONS [F9]", false, 0.67f))
            {
                options_.camera = options_.formationMode == "vortex" ? "vortex" : "formations";
                resetCamera();
            }
        }
    }
    ui_.rect(24, static_cast<float>(height_) - 61, static_cast<float>(width_) - 48, 37, 0xc7171d19);
    const char *help =
        "1-5 Weather | F6 Demo | F8 Formations | F9 Focus | P Pause | F3 Textures | F12 Save";
    if (options_.cameraPath.empty())
    {
        if (walking_)
            help = "WASD Walk | Shift Run | RMB Look | G Take Off | T Time | 1-5 Weather";
        else if (world_)
            help = "WASD Fly | E Up / Q Down | Shift Fast | RMB Look | G Land | T Time";
        else
            help = "WASD Fly | E Up / Q Down | Shift Fast | RMB Look | F8 Formations | F9 Focus";
    }
    ui_.text(38, static_cast<float>(height_) - 56, help, 0xffbdccc3, 0.72f);
    if (!status_.empty())
        ui_.text(38, static_cast<float>(height_) - 39, status_, 0xffc4dfca, 0.73f);
    if (paused_)
        ui_.text(350, weather_.demo() ? 108.0f : 80.0f, "PAUSED", 0xffd3e9cc, 0.85f);
    if (weather_.demo() && !options_.textureViewer)
    {
        char line[128];
        std::snprintf(line, sizeof(line), "WEATHER DEMO  %04.1f / 48s", weather_.demoTime());
        ui_.text(350, 78, line, 0xffc5e3cf, 0.82f);
    }
}

void Renderer::drawTextureInspector()
{
    constexpr float x = 24, y = 24;
    const float panelWidth = std::max(280.0f, std::min(560.0f, width_ - 48.0f));
    const float panelHeight = std::max(296.0f, std::min(604.0f, height_ - 134.0f));
    const int rows = std::clamp(static_cast<int>((panelHeight - 236) / 30), 2, 12);
    const int perPage = rows * 2;
    const int count = static_cast<int>(DebugView::Count);
    const int pageCount = (count + perPage - 1) / perPage;
    const int page = options_.debugView / perPage;
    const auto view = static_cast<DebugView>(options_.debugView);
    const auto &info = textureViews[options_.debugView];

    // 画面サイズに合わせて一覧をページ分割する。選択中の表示を含むページを開く。
    ui_.rect(x, y, panelWidth, panelHeight, 0xf0171d19);
    ui_.rect(x, y, panelWidth, 3, 0xffa5dbb8);
    ui_.text(x + 18, y + 13, "TEXTURE INSPECTOR", 0xffe9fff1, 0.92f);
    if (ui_.button(x + panelWidth - 134, y + 12, 118, 29, "HIDE [F3]", false, 0.66f))
        options_.textureViewer = false;

    int textureWidth = width_, textureHeight = height_;
    if (info.volume)
    {
        switch (view)
        {
        case DebugView::PerlinWorley:
        case DebugView::BaseWorley:
            textureWidth = textureHeight = static_cast<int>(baseNoiseSize_);
            break;
        case DebugView::DetailWorley:
            textureWidth = textureHeight = static_cast<int>(detailNoiseSize_);
            break;
        case DebugView::CloudWarp:
            textureWidth = textureHeight = cloudWarpSize;
            break;
        default:
            textureWidth = textureHeight = cloudControlSize;
            break;
        }
    }
    else
        switch (view)
        {
        case DebugView::CloudShadow:
        case DebugView::CloudShadowDepth:
            textureWidth = textureHeight = shadowSize_;
            break;
        case DebugView::Weather:
        case DebugView::CloudMap:
            textureWidth = textureHeight = 512;
            break;
        case DebugView::CloudHeightLut:
            textureWidth = 1;
            textureHeight = 128;
            break;
        case DebugView::TerrainShadow:
        case DebugView::NearShadow:
            textureWidth = textureHeight = 2048;
            break;
        case DebugView::Sky:
            textureWidth = 320;
            textureHeight = 180;
            break;
        case DebugView::AtmosphereLut:
            textureWidth = 256;
            textureHeight = 64;
            break;
        case DebugView::CloudTransmittance:
        case DebugView::CloudRadiance:
        case DebugView::CloudDistance:
        case DebugView::CloudReconstruction:
            textureWidth = cloudWidth_;
            textureHeight = cloudHeight_;
            break;
        case DebugView::RawCloudRadiance:
        case DebugView::RawCloudTransmittance:
            textureWidth = fullCloudRefresh_ ? cloudWidth_ : rawCloudWidth_;
            textureHeight = fullCloudRefresh_ ? cloudHeight_ : rawCloudHeight_;
            break;
        case DebugView::FogScattering:
        case DebugView::FogTransmittance:
        case DebugView::AerialScattering:
        case DebugView::AerialTransmittance:
            textureWidth = aerialWidth_;
            textureHeight = aerialHeight_;
            break;
        default:
            break;
        }

    char line[256];
    if (info.volume)
        std::snprintf(line, sizeof(line), "%02d  %s | %d x %d x %d", options_.debugView,
                      info.format, textureWidth, textureHeight, textureWidth);
    else
        std::snprintf(line, sizeof(line), "%02d  %s | %d x %d", options_.debugView, info.format,
                      textureWidth, textureHeight);
    ui_.text(x + 18, y + 51, line, 0xffc5e3cf, 0.67f);
    ui_.text(x + 18, y + 78, info.description, 0xffa9bab3, 0.64f);

    const float columnWidth = (panelWidth - 44) / 2;
    for (int slot = 0; slot < perPage; ++slot)
    {
        const int index = page * perPage + slot;
        if (index >= count)
            break;
        const float bx = x + 18 + (slot % 2) * (columnWidth + 8);
        const float by = y + 110 + (slot / 2) * 30.0f;
        if (ui_.button(bx, by, columnWidth, 26, textureViews[index].name,
                       options_.debugView == index, 0.65f))
            options_.debugView = index;
    }

    const float controlsY = y + 114 + rows * 30.0f;
    if (pageCount > 1)
    {
        if (ui_.button(x + 18, controlsY, 100, 28, "PREV PAGE", false, 0.64f))
            options_.debugView = ((page + pageCount - 1) % pageCount) * perPage;
        std::snprintf(line, sizeof(line), "PAGE %d / %d", page + 1, pageCount);
        ui_.text(x + 140, controlsY, line, 0xffa9bab3, 0.66f);
        if (ui_.button(x + panelWidth - 118, controlsY, 100, 28, "NEXT PAGE", false, 0.64f))
            options_.debugView = ((page + 1) % pageCount) * perPage;
    }
    else
        ui_.text(x + 18, controlsY, "F2 NEXT VIEW | F1 HIDE HUD | F12 SAVE PNG", 0xffa9bab3, 0.66f);

    // 断面の向きは固定する座標軸。XならYZ面、YならXZ面、ZならXY面を表示する。
    if (info.volume)
    {
        ui_.text(x + 18, controlsY + 38, "SLICE AXIS", 0xffa9bab3, 0.70f);
        constexpr std::array axes{"X", "Y", "Z"};
        for (int axis = 0; axis < 3; ++axis)
            if (ui_.button(x + 170 + axis * 60.0f, controlsY + 37, 52, 28, axes[axis],
                           options_.textureAxis == axis, 0.66f))
                options_.textureAxis = axis;
        std::snprintf(line, sizeof(line), "SLICE POSITION  %.3f", options_.textureSlice);
        ui_.slider(x + 18, controlsY + 75, panelWidth - 36, line, options_.textureSlice, 0, 1);
    }
    else
        ui_.text(x + 18, controlsY + 44, "Select a noise volume for X / Y / Z slicing.", 0xffa9bab3,
                 0.66f);
}

FormationSet Renderer::loadFormationFile() const
{
    std::ifstream input(options_.formationFile);
    if (!input)
        throw std::runtime_error("Cannot open cloud formation file: "
                                 + options_.formationFile.string());
    return readFormations(input);
}

void Renderer::setFormations(std::string_view mode)
{
    auto candidate = formationPreset(mode);
    formations_ = candidate;
    options_.formationMode = mode;
    historyValid_ = false;
    shadowValid_ = false;
}

void Renderer::resetCamera()
{
    camera_ = {};
    walking_ = options_.camera == "walk";
    if (walking_ || options_.camera == "fly")
    {
        float x = options_.spawnX, z = options_.spawnZ;
        camera_.position = {x, 0, z};
        if (walking_)
            world_->placeWalker(camera_.position);
        else
            camera_.position.y = world_->ground(x, z) + flightStartHeight;
        if (options_.startLook)
        {
            camera_.yaw = XMConvertToRadians(options_.startLook->x);
            camera_.pitch = XMConvertToRadians(options_.startLook->y);
        }
        else
        {
            camera_.yaw = options_.modelPath.empty() ? 0.43f : 0.0f;
            camera_.pitch = options_.modelPath.empty() ? -0.095f : -0.035f;
        }
    }
    else if (options_.camera == "clouds")
        camera_.pitch = 0.40f;
    else if (options_.camera == "overview")
    {
        camera_.position = {0, 6800, -12500};
        camera_.pitch = -0.23f;
    }
    else if (options_.camera == "formations")
    {
        camera_.position = {0, 6900, -11500};
        camera_.pitch = -0.10f;
    }
    else if (options_.camera == "vortex")
    {
        camera_.position = {6400, 17000, 8000};
        camera_.pitch = -1.28f;
    }
    else if (options_.camera == "tower-close")
    {
        camera_.position = {-5600, 5600, -3000};
        camera_.pitch = 0.16f;
    }
    else if (options_.camera == "tower-side")
    {
        camera_.position = {5000, 6500, 7000};
        camera_.yaw = -1.57079632679f;
        camera_.pitch = 0.05f;
    }
    else if (options_.camera == "tower-inside")
    {
        camera_.position = {-5600, 6500, 6500};
        camera_.pitch = 0.15f;
    }
    else if (options_.camera == "inside")
    {
        camera_.position = {0, 2900, -7000};
        camera_.pitch = 0.04f;
    }
    else if (options_.camera == "shadows")
    {
        camera_.position = {0, 1700, -6500};
        camera_.pitch = -0.30f;
    }
    historyValid_ = false;
}

void Renderer::key(UINT k)
{
    if (k >= '1' && k <= '5')
        weather_.transitionTo(static_cast<WeatherKind>(k - '1'));
    if (k == VK_F1)
        options_.ui = !options_.ui;
    if (k == VK_F2)
        options_.debugView = (options_.debugView + 1) % static_cast<int>(DebugView::Count);
    if (k == VK_F3)
        options_.textureViewer = !options_.textureViewer;
    if (k == VK_F4)
    {
        options_.cloudStyle =
            options_.cloudStyle == CloudStyle::Classic ? CloudStyle::Cumulus : CloudStyle::Classic;
        if (options_.classicFast && options_.checkerboard)
            makeCloudRawTargets();
        // 切り替えたフレームから、新しい密度で配置・影・全画素を計算する。
        cloudOcclusionSource_.region.w = 0;
        cachedCloudMapWeather_ = {-1, -1, -1, -1};
        shadowValid_ = false;
        historyValid_ = false;
    }
    if (k == VK_F12)
        captureRequested_ = true;
    if (k == VK_F7)
    {
        options_.checkerboard = !options_.checkerboard;
        makeTargets();
    }
    if (k == VK_F8)
    {
        constexpr std::array modes{"none", "towers", "vortex", "mixed"};
        auto found = std::find(modes.begin(), modes.end(), options_.formationMode);
        const size_t next = found == modes.end()
                                ? 0
                                : (static_cast<size_t>(found - modes.begin()) + 1) % modes.size();
        setFormations(modes[next]);
    }
    if (k == VK_F9)
    {
        options_.camera = options_.formationMode == "vortex" ? "vortex" : "formations";
        resetCamera();
    }
    if (k == 'P')
        paused_ = !paused_;
    if (k == 'T')
        timeLapse_ = !timeLapse_;
    if (k == 'G' && world_ && options_.cameraPath.empty())
    {
        walking_ = !walking_;
        if (walking_)
            world_->placeWalker(camera_.position);
        else
            camera_.position.y = world_->ground(camera_.position.x, camera_.position.z)
                                 + flightStartHeight;
        historyValid_ = false;
    }
    if (k == VK_F6)
    {
        weather_.setDemo(!weather_.demo());
        options_.debugView = 0;
        options_.textureViewer = false;
    }
    if (k == 'L')
        weather_.triggerLightning();
    if (k == VK_SPACE)
        weather_.setAutomatic(!weather_.automatic());
    if (k == 'R')
        resetCamera();
    if (k == 'C')
    {
        options_.quality = static_cast<Quality>((static_cast<int>(options_.quality) + 1) % 4);
        makeTargets();
    }
    if (k == 'H')
        options_.shadows = !options_.shadows;
    if (k == VK_OEM_4 || k == VK_OEM_6)
    {
        float sign = k == VK_OEM_4 ? -1.0f : 1.0f;
        if (options_.timeOfDay >= 0)
        {
            options_.timeOfDay = std::fmod(options_.timeOfDay + sign * 0.5f + 24, 24.0f);
            historyValid_ = false;
        }
        else
            options_.elevation = std::clamp(options_.elevation + sign * 2, -14.0f, 85.0f);
    }
    if (k == VK_F5)
    {
        try
        {
            auto candidate = compileShaders();
            const auto formationCandidate =
                options_.formationMode == "custom" ? loadFormationFile() : formations_;
            shaders_ = std::move(candidate);
            formations_ = formationCandidate;
            historyValid_ = false;
            cachedAerosol_ = -1;
            cloudOcclusionSource_.region.w = 0;
            cachedCloudMapWeather_ = {-1, -1, -1, -1};
            shadowValid_ = false;
            status_ = "Shaders reloaded.";
        }
        catch (const std::exception &e)
        {
            status_ = "Reload failed. Previous shaders retained. See logs/cirrus.log";
            log(e.what());
        }
    }
}

void Renderer::look(float dx, float dy)
{
    camera_.yaw += dx * 0.003f;
    camera_.pitch = std::clamp(camera_.pitch - dy * 0.003f, -1.50f, 1.50f);
}

void Renderer::pointer(int x, int y, bool down, bool pressed)
{
    pointerX_ = x;
    pointerY_ = y;
    pointerDown_ = down;
    pointerPressed_ |= pressed;
}

std::string Renderer::diagnostics()
{
    struct Stats
    {
        double minimum = std::numeric_limits<double>::max(),
               maximum = -std::numeric_limits<double>::max(), mean = 0;
        uint64_t pixels = 0, nonfinite = 0;

        void add(double value)
        {
            if (!std::isfinite(value))
            {
                ++nonfinite;
                return;
            }
            minimum = std::min(minimum, value);
            maximum = std::max(maximum, value);
            mean += value;
            ++pixels;
        }

        void finish()
        {
            if (pixels)
                mean /= pixels;
        }
    };

    auto read = [&](ID3D11Texture2D *source, int channels, int selected, bool half)
    {
        Stats stats;
        D3D11_TEXTURE2D_DESC d{};
        source->GetDesc(&d);
        d.Usage = D3D11_USAGE_STAGING;
        d.BindFlags = 0;
        d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        d.MiscFlags = 0;
        d.MipLevels = 1;
        ComPtr<ID3D11Texture2D> staging;
        require(device_->CreateTexture2D(&d, nullptr, &staging), "Diagnostics staging");
        context_->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, source, 0, nullptr);
        D3D11_MAPPED_SUBRESOURCE m{};
        require(context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &m), "Diagnostics map");
        for (UINT y = 0; y < d.Height; y++)
            for (UINT x = 0; x < d.Width; x++)
            {
                const auto *row = static_cast<const uint8_t *>(m.pData) + y * m.RowPitch;
                size_t index = x * channels + selected;
                double value = half ? PackedVector::XMConvertHalfToFloat(
                                   reinterpret_cast<const uint16_t *>(row)[index])
                                    : reinterpret_cast<const float *>(row)[index];
                stats.add(value);
            }
        context_->Unmap(staging.Get(), 0);
        stats.finish();
        return stats;
    };

    const bool nearActive = constants_.nearCloudParams.x > 0;
    Stats nearTransmittance;
    if (nearActive)
    {
        // 最奥面の累積透過率を取り出し、近景ボクセルが実際に遮蔽したか確認する。
        ComPtr<ID3D11Resource> resource;
        nearCloud_.srv->GetResource(&resource);
        ComPtr<ID3D11Texture3D> source;
        require(resource.As(&source), "Near cloud diagnostics source");
        D3D11_TEXTURE3D_DESC desc{};
        source->GetDesc(&desc);
        const D3D11_BOX lastSlice{0, 0, desc.Depth - 1, desc.Width, desc.Height, desc.Depth};
        desc.Depth = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture3D> staging;
        require(device_->CreateTexture3D(&desc, nullptr, &staging), "Near cloud diagnostics staging");
        context_->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, source.Get(), 0, &lastSlice);

        D3D11_MAPPED_SUBRESOURCE mapped{};
        require(context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped),
                "Near cloud diagnostics map");
        for (UINT y = 0; y < desc.Height; ++y)
        {
            const auto *row = reinterpret_cast<const uint16_t *>(
                static_cast<const uint8_t *>(mapped.pData) + y * mapped.RowPitch);
            for (UINT x = 0; x < desc.Width; ++x)
                nearTransmittance.add(PackedVector::XMConvertHalfToFloat(row[x * 4 + 3]));
        }
        context_->Unmap(staging.Get(), 0);
        nearTransmittance.finish();
    }
    Stats clouds = read(history_[historyIndex_].texture.Get(), 4, 3, true),
          shadow = read(shadowMap_.texture.Get(), 2, 0, true),
          shadowDepth = read(shadowMap_.texture.Get(), 2, 1, true);
    Stats r = read(history_[historyIndex_].texture.Get(), 4, 0, true),
          g = read(history_[historyIndex_].texture.Get(), 4, 1, true),
          b = read(history_[historyIndex_].texture.Get(), 4, 2, true);
    Stats sky = read(sky_.texture.Get(), 4, 0, true), fog = read(fog_.texture.Get(), 4, 3, true);
    Stats rainR = read(rain_.texture.Get(), 4, 0, true),
          rainG = read(rain_.texture.Get(), 4, 1, true),
          rainB = read(rain_.texture.Get(), 4, 2, true),
          rainAlpha = read(rain_.texture.Get(), 4, 3, true);
    uint64_t invalid = nearTransmittance.nonfinite + clouds.nonfinite + shadow.nonfinite
                       + shadowDepth.nonfinite + r.nonfinite + g.nonfinite + b.nonfinite
                       + sky.nonfinite + fog.nonfinite
                       + rainR.nonfinite + rainG.nonfinite + rainB.nonfinite + rainAlpha.nonfinite;
    if (invalid)
        throw std::runtime_error("Non-finite GPU values in cloud/sky/fog/rain buffers");
    // 再構成マスクをGPUから読み、実際に再利用・修復した画素数を記録する。
    // ベンチマーク中は呼ばれないため、FPS測定にリードバックは含まれない。
    std::array<uint64_t, 4> reconstructionCounts{};
    D3D11_TEXTURE2D_DESC maskDesc{};
    reconstruction_.texture->GetDesc(&maskDesc);
    maskDesc.Usage = D3D11_USAGE_STAGING;
    maskDesc.BindFlags = 0;
    maskDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> maskStaging;
    require(device_->CreateTexture2D(&maskDesc, nullptr, &maskStaging), "Mask staging");
    context_->CopyResource(maskStaging.Get(), reconstruction_.texture.Get());
    D3D11_MAPPED_SUBRESOURCE maskData{};
    require(context_->Map(maskStaging.Get(), 0, D3D11_MAP_READ, 0, &maskData), "Mask readback");
    for (UINT y = 0; y < maskDesc.Height; ++y)
    {
        const auto *row = reinterpret_cast<const uint32_t *>(
            static_cast<const uint8_t *>(maskData.pData) + y * maskData.RowPitch);
        for (UINT x = 0; x < maskDesc.Width; ++x)
        {
            const uint32_t encoded = row[x];
            const uint32_t state = encoded & 3u;
            if (encoded > 15u || (encoded > 3u && state != 1u))
            {
                context_->Unmap(maskStaging.Get(), 0);
                throw std::runtime_error("Invalid cloud reconstruction state");
            }
            ++reconstructionCounts[state];
        }
    }
    context_->Unmap(maskStaging.Get(), 0);
    double gpu = 0;
    for (double ms : gpuMs_)
        gpu += ms;
    std::ostringstream out;
    out << std::fixed << std::setprecision(6);
    out << "{\n  \"adapter\": \"" << adapter_ << "\",\n  \"width\": " << width_
        << ", \"height\": " << height_ << ",\n";
    out << "  \"weather\": \"" << weatherName(weather_.target()) << "\", \"quality\": \""
        << qualityNames[static_cast<int>(options_.quality)] << "\",\n";
    out << "  \"cloud_style\": \""
        << (options_.cloudStyle == CloudStyle::Classic ? "classic" : "cumulus") << "\",\n";
    out << "  \"classic_fast\": " << (fastClassic() ? "true" : "false") << ",\n";
    out << "  \"sun_elevation\": " << options_.elevation
        << ", \"sun_azimuth\": " << options_.azimuth << ",\n";
    out << "  \"solar_hour\": " << options_.timeOfDay << ",\n";
    out << "  \"camera_position_m\": [" << camera_.position.x << ", " << camera_.position.y << ", "
        << camera_.position.z << "],\n";
    if (world_)
    {
        float ground = world_->ground(camera_.position.x, camera_.position.z);
        std::array<UINT, GrassField::lodCount> grass{};
        if (world_->grass())
            grass = world_->grass()->counts(context_.Get());
        out << "  \"world\": {\"walking\": " << (walking_ ? "true" : "false")
            << ", \"ground_m\": " << ground << ", \"eye_height_m\": " << camera_.position.y - ground
            << ", \"active_tiles\": " << world_->tiles()
            << ", \"tiles_built\": " << world_->tilesBuilt() << ", \"trees\": " << world_->trees()
            << ", \"grass_tufts\": " << grass[0] + grass[1] + grass[2] << ", \"grass_lods\": ["
            << grass[0] << ", " << grass[1] << ", " << grass[2] << "]"
            << ", \"ferns\": " << world_->ferns() << ", \"bank_rocks\": " << world_->rocks()
            << ", \"near_shadow\": " << (constants_.worldRendering.y > 0.5f ? "true" : "false")
            << ", \"model_primitives\": " << model_.meshes.size() << "},\n";
    }
    out << "  \"frames\": " << frameNumber_ << ", \"simulation_seconds\": " << weather_.time()
        << ",\n";
    const auto &state = weather_.state();
    out << "  \"weather_state\": {\"coverage\": " << state.coverage
        << ", \"density\": " << state.density << ", \"base_m\": " << state.cloudBase
        << ", \"thickness_m\": " << state.cloudThickness << ", \"rain\": " << state.precipitation
        << ", \"transition_progress\": " << weather_.transitionProgress() << "},\n";
    out << "  \"wind_offset_m\": [" << weather_.wind().x << ", " << weather_.wind().z << "],\n";
    out << "  \"weather_effects\": {\"wetness\": " << weather_.wetness()
        << ", \"demo\": " << (weather_.demo() ? "true" : "false")
        << ", \"demo_seconds\": " << weather_.demoTime()
        << ", \"rain_enabled\": " << (options_.rain ? "true" : "false") << "},\n";
    out << "  \"lightning\": {\"serial\": " << weather_.lightningSerial()
        << ", \"strength\": " << lastLightning_ << ", \"age_seconds\": " << weather_.lightningAge()
        << ", \"source_m\": [" << lightningSource_.x << ", " << lightningSource_.y << ", "
        << lightningSource_.z << "], \"target_m\": [" << lightningTarget_.x << ", "
        << lightningTarget_.y << ", " << lightningTarget_.z << "]},\n";
    out << "  \"rain_opacity\": {\"min\": " << rainAlpha.minimum
        << ", \"max\": " << rainAlpha.maximum << ", \"mean\": " << rainAlpha.mean << "},\n";
    const bool nearVoxels = options_.nearCloudVoxels && options_.clouds;
    out << "  \"near_cloud_voxels\": {\"active\": " << (nearActive ? "true" : "false")
        << ", \"grid\": [" << (nearVoxels ? nearCloudWidth : 0)
        << ", " << (nearVoxels ? nearCloudHeight : 0)
        << ", " << (nearVoxels ? nearCloudSlices : 0)
        << "], \"view_depth_m\": " << constants_.nearCloudParams.x
        << ", \"updates\": " << nearCloudUpdates_ << ", \"transmittance\": ";
    if (nearActive)
        out << "{\"min\": " << nearTransmittance.minimum << ", \"max\": "
            << nearTransmittance.maximum << ", \"mean\": " << nearTransmittance.mean << '}';
    else
        out << "null";
    out << "},\n";
    out << "  \"cloud_shadows_enabled\": " << (options_.shadows ? "true" : "false") << ",\n";
    out << "  \"cloud_optimization\": {\"lighting_reuse\": "
        << (constants_.cloudPerformance.z > 0.5f ? "true" : "false")
        << ", \"occlusion_cache_active\": "
        << (constants_.cloudOcclusionRegion.w > 0.5f ? "true" : "false")
        << ", \"occlusion_cache_updates\": " << cloudOcclusionUpdates_
        << ", \"shadow_updates\": " << shadowUpdates_
        << ", \"atmosphere_updates\": " << atmosphereUpdates_
        << ", \"shadow_age_seconds\": " << constants_.cloudPerformance.w << "},\n";
    out << "  \"cloud_reconstruction\": {\"enabled\": "
        << (options_.checkerboard ? "true" : "false")
        << ", \"active\": " << (checkerActive_ ? "true" : "false")
        << ", \"full_refresh\": " << (fullCloudRefresh_ ? "true" : "false")
        << ", \"logical_size\": [" << cloudWidth_ << ", " << cloudHeight_
        << "], \"raw_allocation\": [" << rawCloudWidth_ << ", " << rawCloudHeight_
        << "], \"phases\": " << (options_.checkerboard ? (fastClassic() ? 4 : 2) : 1)
        << ", \"parity\": " << static_cast<int>(constants_.checkerboard.y)
        << ", \"traced_pixels\": " << reconstructionCounts[0] + reconstructionCounts[2]
        << ", \"history_pixels\": " << reconstructionCounts[1]
        << ", \"repair_pixels\": " << reconstructionCounts[2]
        << ", \"analytical_clear_pixels\": " << reconstructionCounts[3]
        << ", \"checker_frames\": " << checkerFrames_
        << ", \"full_refresh_frames\": " << fullCloudFrames_ << "},\n";
    out << "  \"cloud_textures\": {\"source\": \""
        << (options_.cloudTextureDirectory.empty() ? "procedural" : "dds")
        << "\", \"base_size\": " << baseNoiseSize_ << ", \"detail_size\": " << detailNoiseSize_ << "},\n";
    out << "  \"tower_control_volume\": {\"size\": " << cloudControlSize
        << ", \"format\": \"R16_FLOAT\", \"bytes\": "
        << cloudControlSize * cloudControlSize * cloudControlSize * 2
        << ", \"cells\": " << cloudControlCells().size() << ", \"warp_size\": " << cloudWarpSize
        << ", \"warp_bytes\": " << cloudWarpSize * cloudWarpSize * cloudWarpSize * 8
        << ", \"asset_setup_cpu_ms\": " << towerBakeMs_ << "},\n";
    out << "  \"formations\": {\"mode\": \"" << options_.formationMode
        << "\", \"count\": " << static_cast<int>(constants_.formationControls.x)
        << ", \"strength\": " << options_.formationStrength
        << ", \"scale\": " << options_.formationScale << ", \"speed\": " << options_.formationSpeed
        << ", \"phase_seconds\": " << formationPhase_
        << ", \"base_m\": " << constants_.formationLayer.x
        << ", \"top_m\": " << constants_.formationLayer.y << ", \"regions\": [";
    for (size_t i = 0; i < formations_.count; ++i)
    {
        const auto &f = constants_.formations[i];
        out << (i ? ", " : "") << "{\"kind\": \"" << (f.kind > 0.5f ? "vortex" : "tower")
            << "\", \"center_xz_m\": [" << f.x << ", " << f.z << "], \"radius_m\": " << f.radius
            << ", \"base_m\": " << f.base << ", \"height_m\": " << f.height
            << ", \"density\": " << f.density << ", \"spin_rad_s\": " << f.spin << "}";
    }
    out << "]},\n";
    out << "  \"texture_view\": {\"index\": " << options_.debugView << ", \"name\": \""
        << textureViews[options_.debugView].name << "\", \"slice\": " << options_.textureSlice
        << ", \"axis\": \""
        << "XYZ"[options_.textureAxis]
        << "\", \"panel_visible\": " << (options_.ui && options_.textureViewer ? "true" : "false")
        << "},\n";
    out << "  \"cloud_transmittance\": {\"min\": " << clouds.minimum
        << ", \"max\": " << clouds.maximum << ", \"mean\": " << clouds.mean << "},\n";
    out << "  \"shadow_transmittance\": {\"min\": " << shadow.minimum
        << ", \"max\": " << shadow.maximum << ", \"mean\": " << shadow.mean << "},\n";
    out << "  \"nonfinite_samples\": " << invalid << ", \"gpu_timing_samples\": " << timingSamples_
        << ",\n  \"gpu_frame_ms\": " << gpu << ",\n  \"gpu_pass_ms\": {";
    for (size_t i = 0; i < gpuMs_.size(); i++)
        out << (i ? ", " : "") << '\"' << stageNames[i] << "\": " << gpuMs_[i];
    out << "}\n}\n";
    return out.str();
}

void Renderer::recordWeather(std::ostream &output, uint64_t frame) const
{
    output << std::fixed << std::setprecision(6) << frame << ',' << weather_.time() << ','
           << weather_.demoTime() << ',' << static_cast<int>(weather_.target()) << ','
           << weather_.state().precipitation << ',' << weather_.wetness() << ',' << lastLightning_
           << ',' << weather_.lightningSerial() << ',' << weather_.wind().x << ','
           << weather_.wind().z << '\n';
    if (!output)
        throw std::runtime_error("Cannot write weather timeline");
}

void Renderer::capture(const std::filesystem::path &file, bool includeDiagnostics)
{
    if (!file.parent_path().empty())
        std::filesystem::create_directories(file.parent_path());
    context_->OMSetRenderTargets(0, nullptr, nullptr);
    D3D11_TEXTURE2D_DESC desc{};
    finalColor_.texture->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    require(device_->CreateTexture2D(&desc, nullptr, &staging), "Capture staging");
    context_->CopyResource(staging.Get(), finalColor_.texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    require(context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped), "Capture readback");
    std::vector<uint8_t> pixels(static_cast<size_t>(width_) * height_ * 4);
    for (int y = 0; y < height_; y++)
    {
        const auto *src = static_cast<const uint8_t *>(mapped.pData) + y * mapped.RowPitch;
        for (int x = 0; x < width_; x++)
        {
            auto i = (static_cast<size_t>(y) * width_ + x) * 4;
            pixels[i] = src[x * 4 + 2];
            pixels[i + 1] = src[x * 4 + 1];
            pixels[i + 2] = src[x * 4];
            pixels[i + 3] = 255;
        }
    }
    context_->Unmap(staging.Get(), 0);
    ComPtr<IWICImagingFactory> factory;
    require(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                             IID_PPV_ARGS(&factory)),
            "WIC factory");
    ComPtr<IWICStream> stream;
    require(factory->CreateStream(&stream), "WIC stream");
    require(stream->InitializeFromFilename(file.c_str(), GENERIC_WRITE), "Capture file");
    ComPtr<IWICBitmapEncoder> encoder;
    require(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder), "PNG encoder");
    require(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache), "PNG initialize");
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> properties;
    require(encoder->CreateNewFrame(&frame, &properties), "PNG frame");
    require(frame->Initialize(properties.Get()), "PNG frame initialize");
    require(frame->SetSize(width_, height_), "PNG size");
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    require(frame->SetPixelFormat(&format), "PNG format");
    if (format != GUID_WICPixelFormat32bppBGRA)
        throw std::runtime_error("PNG encoder rejected BGRA");
    require(
        frame->WritePixels(height_, width_ * 4, static_cast<UINT>(pixels.size()), pixels.data()),
        "PNG pixels");
    require(frame->Commit(), "PNG frame commit");
    require(encoder->Commit(), "PNG commit");
    if (!includeDiagnostics)
        return;
    std::string report = diagnostics();
    auto json = file;
    json.replace_extension(".json");
    std::ofstream out(json);
    out << report;
    if (!out)
        throw std::runtime_error("Cannot write capture diagnostics");
    log("Saved " + file.string() + " and " + json.string());
    status_ = "Saved " + file.filename().string();
}

void Renderer::finishValidation()
{
    require(device_->GetDeviceRemovedReason(), "Final device health");
    ComPtr<ID3D11InfoQueue> queue;
    if (SUCCEEDED(device_.As(&queue)))
    {
        uint64_t errors = 0, warnings = 0;
        for (UINT64 i = 0; i < queue->GetNumStoredMessages(); i++)
        {
            SIZE_T size = 0;
            queue->GetMessage(i, nullptr, &size);
            std::vector<uint8_t> storage(size);
            auto *m = reinterpret_cast<D3D11_MESSAGE *>(storage.data());
            if (SUCCEEDED(queue->GetMessage(i, m, &size)))
            {
                if (m->Severity <= D3D11_MESSAGE_SEVERITY_ERROR)
                {
                    ++errors;
                    log(std::string("D3D11 error: ") + m->pDescription);
                }
                else if (m->Severity == D3D11_MESSAGE_SEVERITY_WARNING)
                {
                    ++warnings;
                    log(std::string("D3D11 warning: ") + m->pDescription);
                }
            }
        }
        log("D3D11 debug messages: errors=" + std::to_string(errors)
            + ", warnings=" + std::to_string(warnings));
        if (errors || warnings)
            throw std::runtime_error(
                "D3D11 validation reported errors or warnings; see logs/cirrus.log");
    }
    else
        log("D3D11 debug layer was not active; resource validation is unavailable.");
    log("Validation complete.");
}
}
