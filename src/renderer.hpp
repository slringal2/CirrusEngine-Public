#pragma once
#include "weather.hpp"
#include "cloud_formations.hpp"
#include "cloud_volume.hpp"
#include "ui.hpp"
#include "world.hpp"
#include <Windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <DirectXMath.h>
#include <wrl/client.h>
#include <array>
#include <filesystem>
#include <iosfwd>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace cirrus
{
using Microsoft::WRL::ComPtr;
inline constexpr UINT shaderResourceCount = 29;
using ShaderResources = std::array<ID3D11ShaderResourceView *, shaderResourceCount>;
enum class Quality
{
    Low,
    Medium,
    High,
    Ultra
};

// 既存の0～8を保ち、scene.hlsl の textureDebugView と同じ番号で共有する。
enum class DebugView
{
    Final,
    CloudTransmittance,
    CloudShadow,
    Normal,
    Albedo,
    FogScattering,
    Weather,
    PerlinWorley,
    DetailWorley,
    BaseWorley,
    SceneDepth,
    TerrainShadow,
    Sky,
    CloudRadiance,
    CloudDistance,
    AerialScattering,
    AerialTransmittance,
    FogTransmittance,
    AtmosphereLut,
    RawCloudRadiance,
    RawCloudTransmittance,
    Roughness,
    Rain,
    CloudReconstruction,
    TowerControl,
    CloudWarp,
    CloudMap,
    CloudHeightLut,
    CloudShadowDepth,
    Metallic,
    NearShadow,
    RiverSurface,
    Count
};

struct Options
{
    int width = 1600, height = 900, frames = 48;
    WeatherKind weather = WeatherKind::PartlyCloudy;
    Quality quality = Quality::High;
    float elevation = 28, azimuth = -26, exposure = 1.0f;
    bool headless = false, warp = false, checkShaders = false, ui = true, shadows = true,
         clouds = true;
    bool automatic = false, vsync = true, debugLayer = false;
    bool weatherDemo = false, rain = true, lightning = true;
    bool fullCloudLighting = false;
    bool checkerboard = true;
    // 0: quality preset, 1: full, 2: half width/height, 4: quarter width/height.
    int cloudDivisor = 0;
    std::string formationMode = "none";
    std::filesystem::path formationFile;
    float formationStrength = 1, formationScale = 1, formationSpeed = 1;
    double lightningAt = -1;
    std::filesystem::path recordDirectory;
    double fixedDt = 0;
    int transition = -1;
    double transitionSeconds = 18;
    double benchmarkSeconds = 0;
    std::filesystem::path benchmarkOutput = "captures/benchmark.json";
    int debugView = 0;
    bool textureViewer = false;
    float textureSlice = 0.41f;
    int textureAxis = 2;
    std::string camera;
    std::string cameraPath;
    std::filesystem::path capture, shaderDirectory, assetsDirectory;
    bool openWorld = false, vegetation = true;
    float timeOfDay = -1, spawnX = -6.1f, spawnZ = -37;
    std::optional<DirectX::XMFLOAT2> walkLook;
    double daySeconds = 0;
    std::filesystem::path modelPath;
    float modelScale = 1;
};

struct Camera
{
    DirectX::XMFLOAT3 position{0, 330, -1600};
    float yaw = 0, pitch = 0.11f;
};

// shaders/common.hlsli の cbuffer Frame と同じ順序・配置を保つCPU側の定数。
struct FrameData
{
    DirectX::XMFLOAT4X4 viewProjection, inverseViewProjection, previousViewProjection,
        lightViewProjection, nearLightViewProjection;
    DirectX::XMFLOAT4 cameraTime, previousCamera;
    DirectX::XMFLOAT4 sunDirection, solarExposure, resolution, cloudLayer, weather;
    DirectX::XMFLOAT4 wind, previousWind, shadowRegion, renderSize, controls, atmosphere;
    DirectX::XMFLOAT4 textureInspection;
    DirectX::XMFLOAT4 weatherEffects, lightningSource, lightningTarget;
    DirectX::XMFLOAT4 cloudPerformance;
    DirectX::XMFLOAT4 checkerboard;
    DirectX::XMFLOAT4 worldRendering;
    DirectX::XMFLOAT4 formationControls, formationLayer;
    std::array<CloudFormation, maxCloudFormations> formations;
};

static_assert(sizeof(FrameData) % 16 == 0, "D3D11 constant buffer alignment");

struct Texture
{
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11RenderTargetView> rtv;
    ComPtr<ID3D11UnorderedAccessView> uav;
};

struct ShaderSet
{
    ComPtr<ID3D11VertexShader> geometryVS, shadowVS, fullscreenVS, rainVS, meshVS, grassVS;
    ComPtr<ID3D11PixelShader> geometryPS, compositePS, rainPS, meshPS, meshShadowPS, resolveEdgesPS,
        grassPS;
    ComPtr<ID3D11ComputeShader> noiseCS, weatherCS, cloudMapCS, transmittanceCS, skyCS,
        skyAmbientCS, shadowCS, cloudCS, temporalCS, repairCS, aerialCS, grassPlacementCS;
    ComPtr<ID3D11InputLayout> geometryLayout, meshLayout;
};

class Renderer
{
  public:
    Renderer(HWND window, const Options &options);
    ~Renderer();
    void resize(int width, int height);
    void frame(double dt, bool focused);
    void key(UINT key);
    void look(float dx, float dy);
    void pointer(int x, int y, bool down, bool pressed);
    void capture(const std::filesystem::path &file, bool includeDiagnostics = true);
    void recordWeather(std::ostream &output, uint64_t frame) const;
    void finishValidation();

    bool wantsCapture()
    {
        bool b = captureRequested_;
        captureRequested_ = false;
        return b;
    }

    const std::string &adapter() const
    {
        return adapter_;
    }

    bool shaderCheckOnly() const
    {
        return options_.checkShaders;
    }

  private:
    void createDevice(HWND window);
    ShaderSet compileShaders();
    void initializeResources();
    void makeTerrain();
    void makeShadowDepth(ComPtr<ID3D11DepthStencilView> &dsv,
                         ComPtr<ID3D11ShaderResourceView> &srv);
    Texture makeTexture(int w, int h, DXGI_FORMAT format, bool target, bool unordered,
                        bool mipmaps = false);
    void makeTargets();
    void updateConstants();
    void drawGeometry(bool shadow, bool localPass = false);
    void moveCamera(float forward, float side, float vertical, double dt, bool fast);
    void drawRain();
    void compute(ID3D11ComputeShader *shader, int x, int y, int z,
                 const std::vector<ID3D11UnorderedAccessView *> &outputs, ShaderResources inputs);
    ShaderResources resources() const;
    void drawUi();
    void drawTextureInspector();
    void resetCamera();
    void setFormations(std::string_view mode);
    FormationSet loadFormationFile() const;
    void startTiming();
    void stamp(int stage);
    void endTiming();
    std::string diagnostics();
    Options options_;
    WeatherSystem weather_;
    FormationSet formations_;
    Camera camera_;
    std::unique_ptr<World> world_;
    StaticModel model_;
    bool walking_ = false;
    FrameData constants_{};
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<IDXGISwapChain> swapchain_;
    ComPtr<ID3D11RenderTargetView> backbuffer_;
    ComPtr<ID3D11Texture2D> depth_;
    ComPtr<ID3D11DepthStencilView> depthView_;
    ComPtr<ID3D11ShaderResourceView> depthSRV_;
    ComPtr<ID3D11DepthStencilView> terrainDepthView_, nearDepthView_;
    ComPtr<ID3D11ShaderResourceView> terrainDepthSRV_, nearDepthSRV_;
    ComPtr<ID3D11Buffer> frameBuffer_, passBuffer_, noiseBuffer_, vertices_, indices_;
    ComPtr<ID3D11ShaderResourceView> baseNoise_, detailNoise_, towerControl_, cloudWarp_;
    double towerBakeMs_ = 0;
    ComPtr<ID3D11SamplerState> linearClamp_, linearWrap_, shadowSampler_;
    ComPtr<ID3D11RasterizerState> raster_, meshRaster_, shadowRaster_, meshShadowRaster_;
    ComPtr<ID3D11DepthStencilState> depthOn_, reversedDepth_, depthOff_;
    ComPtr<ID3D11BlendState> rainBlend_;
    ShaderSet shaders_;
    Texture finalColor_, sceneColor_, albedo_, normals_, surface_, weatherMap_, cloudDisplacement_,
        cloudMap_, cloudHeightLut_, shadowMap_, transmittance_, sky_, skyAmbient_, cloudRaw_,
        metaRaw_, reconstruction_;
    // 前回を読みながら今回を書けるよう、雲と代表距離の履歴を2組で交互に使う。
    std::array<Texture, 2> history_, historyMeta_;
    Texture aerialScatter_, aerialTransmittance_, fog_, rain_;
    Ui ui_;
    int width_ = 0, height_ = 0, cloudWidth_ = 0, cloudHeight_ = 0, aerialWidth_ = 0,
        aerialHeight_ = 0, shadowSize_ = 0;
    int rawCloudWidth_ = 0, cameraCut_ = -1;
    bool checkerActive_ = false, fullCloudRefresh_ = true;
    uint64_t checkerFrames_ = 0, fullCloudFrames_ = 0;
    float previousYaw_ = 0, previousPitch_ = 0;
    double previousTime_ = 0;
    double formationPhase_ = 0;
    DirectX::XMFLOAT4 previousLayer_{};
    UINT indexCount_ = 0;
    uint64_t frameNumber_ = 0;
    int historyIndex_ = 0;
    bool historyValid_ = false, paused_ = false, captureRequested_ = false, timeLapse_ = false;
    bool pointerDown_ = false, pointerPressed_ = false;
    int pointerX_ = 0, pointerY_ = 0;
    float lastElevation_ = 0, lastLightning_ = 0;
    float cachedAerosol_ = -1;
    uint64_t atmosphereUpdates_ = 0;
    DirectX::XMFLOAT4 cachedCloudMapWeather_{-1, -1, -1, -1};
    bool shadowValid_ = false, updateShadow_ = true;
    DirectX::XMFLOAT4 shadowLayer_{}, shadowRegion_{}, shadowSun_{};
    DirectX::XMFLOAT2 shadowWind_{};
    float shadowType_ = -1, shadowControls_ = -1;
    double shadowTime_ = -1;
    uint64_t shadowFrame_ = 0, shadowUpdates_ = 0;
    uint32_t lightningSerial_ = 0;
    DirectX::XMFLOAT3 lightningSource_{}, lightningTarget_{};
    WindOffset previousWind_{};
    DirectX::XMFLOAT3 previousCamera_{};
    DirectX::XMFLOAT4X4 previousVP_{};
    std::string adapter_, status_;
    double cpuMs_ = 0;

    struct Timing
    {
        ComPtr<ID3D11Query> disjoint;
        std::array<ComPtr<ID3D11Query>, 8> stamps;
        bool pending = false;
    };

    std::array<Timing, 6> timing_;
    std::array<double, 7> gpuMs_{};
    uint64_t timingSamples_ = 0;
    bool timingActive_ = false;
    Timing *activeTiming_ = nullptr;
};

void require(HRESULT result, const char *operation);
void log(const std::string &message);
}
