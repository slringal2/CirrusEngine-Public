#include "grass.hpp"
#include <cmath>
#include <cstring>

namespace cirrus
{
using namespace DirectX;
void require(HRESULT hr, const char *operation);

namespace
{
struct Range
{
    float spacing;
    XMFLOAT4 distance; // fade in: start/end, fade out: start/end
    UINT blades, rows;
};

constexpr std::array<Range, GrassField::lodCount> ranges{{
    {0.25f, {-1, 0, 22, 35}, 12, 5},
    {0.50f, {22, 35, 86, 123}, 6, 4},
    {0.98f, {86, 123, 246, 310}, 4, 3},
}};
constexpr UINT settingsSlot = 4, heightSlot = 42, siteSlot = 43, grainSlot = 44;
constexpr UINT siteBytes = 32; // GrassSite in grass.hlsl

struct Settings
{
    XMFLOAT4 terrain;
    XMINT4 grid;
    XMFLOAT4 fade;
    float spacing;
    UINT rows, lod, padding = 0;
};

static_assert(sizeof(Settings) == 64);

UINT gridWidth(const Range &range)
{
    return static_cast<UINT>(std::ceil(2 * range.distance.w / range.spacing)) + 2;
}
}

GrassField::GrassField(ID3D11Device *device, ID3D11DeviceContext *context,
                       const std::filesystem::path &bladeGrain)
    : bladeGrain_(loadTexture(device, context, bladeGrain, false))
{
    D3D11_TEXTURE2D_DESC height{};
    height.Width = height.Height = terrainSize;
    height.MipLevels = height.ArraySize = 1;
    height.Format = DXGI_FORMAT_R32_FLOAT;
    height.SampleDesc.Count = 1;
    height.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    require(device->CreateTexture2D(&height, nullptr, &heightTexture_), "Grass terrain texture");
    require(device->CreateShaderResourceView(heightTexture_.Get(), nullptr, &heightView_),
            "Grass terrain view");

    D3D11_BUFFER_DESC readback{};
    readback.ByteWidth = sizeof(D3D11_DRAW_INDEXED_INSTANCED_INDIRECT_ARGS);
    readback.Usage = D3D11_USAGE_STAGING;
    readback.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    require(device->CreateBuffer(&readback, nullptr, &readback_), "Grass statistics buffer");

    for (size_t i = 0; i < lodCount; ++i)
    {
        const Range &range = ranges[i];
        Lod &lod = lods_[i];
        const UINT side = gridWidth(range);
        const UINT capacity = side * side;

        D3D11_BUFFER_DESC sites{};
        sites.ByteWidth = capacity * siteBytes;
        sites.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
        sites.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
        sites.StructureByteStride = siteBytes;
        ComPtr<ID3D11Buffer> buffer;
        require(device->CreateBuffer(&sites, nullptr, &buffer), "Grass sites");
        D3D11_SHADER_RESOURCE_VIEW_DESC view{};
        view.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
        view.Buffer.NumElements = capacity;
        require(device->CreateShaderResourceView(buffer.Get(), &view, &lod.sites),
                "Grass site view");
        D3D11_UNORDERED_ACCESS_VIEW_DESC append{};
        append.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
        append.Buffer.NumElements = capacity;
        append.Buffer.Flags = D3D11_BUFFER_UAV_FLAG_APPEND;
        require(device->CreateUnorderedAccessView(buffer.Get(), &append, &lod.append),
                "Grass append buffer");

        std::vector<uint16_t> indices;
        for (UINT blade = 0; blade < range.blades; ++blade)
            for (UINT row = 0; row + 1 < range.rows; ++row)
            {
                const auto a = static_cast<uint16_t>((blade * range.rows + row) * 2);
                const auto b = static_cast<uint16_t>(a + 1);
                const auto c = static_cast<uint16_t>(a + 2);
                indices.insert(indices.end(), {a, b, c});
                if (row + 2 < range.rows)
                    indices.insert(indices.end(), {c, b, static_cast<uint16_t>(a + 3)});
            }
        lod.indices =
            immutableBuffer(device, D3D11_BIND_INDEX_BUFFER, std::as_bytes(std::span(indices)));

        D3D11_DRAW_INDEXED_INSTANCED_INDIRECT_ARGS draw{};
        draw.IndexCountPerInstance = static_cast<UINT>(indices.size());
        D3D11_SUBRESOURCE_DATA initial{&draw, 0, 0};
        D3D11_BUFFER_DESC args{};
        args.ByteWidth = sizeof(draw);
        args.MiscFlags = D3D11_RESOURCE_MISC_DRAWINDIRECT_ARGS;
        require(device->CreateBuffer(&args, &initial, &lod.arguments), "Grass draw arguments");

        D3D11_BUFFER_DESC settings{};
        settings.ByteWidth = sizeof(Settings);
        settings.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        require(device->CreateBuffer(&settings, nullptr, &lod.settings), "Grass LOD constants");
    }
}

void GrassField::setTerrain(ID3D11DeviceContext *context, XMFLOAT2 origin,
                            std::span<const float> heights)
{
    context->UpdateSubresource(heightTexture_.Get(), 0, nullptr, heights.data(),
                               terrainSize * sizeof(float), 0);
    terrainOrigin_ = origin;
    selectedShader_ = nullptr;
}

void GrassField::select(ID3D11DeviceContext *context, ID3D11ComputeShader *shader, XMFLOAT3 camera,
                        const XMFLOAT4X4 &viewProjection)
{
    // Roots are fixed to the terrain; wind moves only the vertices in the draw pass.
    if (selectedShader_ == shader
        && std::memcmp(&viewProjection, &selectedView_, sizeof(viewProjection)) == 0)
        return;
    selectedShader_ = shader;
    selectedView_ = viewProjection;
    context->CSSetShader(shader, nullptr, 0);
    ID3D11ShaderResourceView *height = heightView_.Get();
    context->CSSetShaderResources(heightSlot, 1, &height);
    ID3D11UnorderedAccessView *empty = nullptr;
    for (size_t i = 0; i < lodCount; ++i)
    {
        const Range &range = ranges[i];
        const Lod &lod = lods_[i];
        const UINT side = gridWidth(range);
        const Settings settings{
            {terrainOrigin_.x, terrainOrigin_.y, terrainStep, static_cast<float>(terrainSize)},
            {static_cast<int>(std::floor((camera.x - range.distance.w) / range.spacing)),
             static_cast<int>(std::floor((camera.z - range.distance.w) / range.spacing)),
             static_cast<int>(side), 0},
            range.distance,
            range.spacing,
            range.rows,
            static_cast<UINT>(i)};
        context->UpdateSubresource(lod.settings.Get(), 0, nullptr, &settings, 0, 0);
        ID3D11Buffer *constants = lod.settings.Get();
        context->CSSetConstantBuffers(settingsSlot, 1, &constants);
        ID3D11UnorderedAccessView *sites = lod.append.Get();
        const UINT reset = 0;
        context->CSSetUnorderedAccessViews(0, 1, &sites, &reset);
        context->Dispatch((side + 7) / 8, (side + 7) / 8, 1);
        context->CSSetUnorderedAccessViews(0, 1, &empty, nullptr);
        context->CopyStructureCount(
            lod.arguments.Get(),
            offsetof(D3D11_DRAW_INDEXED_INSTANCED_INDIRECT_ARGS, InstanceCount), sites);
    }
    ID3D11ShaderResourceView *noHeight = nullptr;
    context->CSSetShaderResources(heightSlot, 1, &noHeight);
    context->CSSetShader(nullptr, nullptr, 0);
}

void GrassField::draw(ID3D11DeviceContext *context, bool shadow) const
{
    ID3D11ShaderResourceView *grain = bladeGrain_.Get();
    if (!shadow)
        context->PSSetShaderResources(grainSlot, 1, &grain);
    const size_t count = shadow ? 1 : lodCount;
    for (size_t i = 0; i < count; ++i)
    {
        const Lod &lod = lods_[i];
        ID3D11Buffer *constants = lod.settings.Get();
        ID3D11ShaderResourceView *sites = lod.sites.Get();
        context->VSSetConstantBuffers(settingsSlot, 1, &constants);
        if (!shadow)
            context->PSSetConstantBuffers(settingsSlot, 1, &constants);
        context->VSSetShaderResources(siteSlot, 1, &sites);
        context->IASetIndexBuffer(lod.indices.Get(), DXGI_FORMAT_R16_UINT, 0);
        context->DrawIndexedInstancedIndirect(lod.arguments.Get(), 0);
    }
    ID3D11ShaderResourceView *empty = nullptr;
    context->VSSetShaderResources(siteSlot, 1, &empty);
    if (!shadow)
        context->PSSetShaderResources(grainSlot, 1, &empty);
}

std::array<UINT, GrassField::lodCount> GrassField::counts(ID3D11DeviceContext *context) const
{
    std::array<UINT, lodCount> result{};
    for (size_t i = 0; i < lodCount; ++i)
    {
        context->CopyResource(readback_.Get(), lods_[i].arguments.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        require(context->Map(readback_.Get(), 0, D3D11_MAP_READ, 0, &mapped),
                "Read grass instance count");
        auto *args = static_cast<const D3D11_DRAW_INDEXED_INSTANCED_INDIRECT_ARGS *>(mapped.pData);
        result[i] = args->InstanceCount;
        context->Unmap(readback_.Get(), 0);
    }
    return result;
}
}
