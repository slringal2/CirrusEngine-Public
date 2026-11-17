#pragma once

#include <DirectXMath.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <filesystem>
#include <span>
#include <vector>

namespace cirrus
{
using Microsoft::WRL::ComPtr;

struct TerrainVertex
{
    DirectX::XMFLOAT3 position, normal;
    DirectX::XMFLOAT4 material;
};

struct MeshVertex
{
    DirectX::XMFLOAT3 position;
    DirectX::XMFLOAT3 normal{0, 1, 0};
    DirectX::XMFLOAT4 tangent{};
    DirectX::XMFLOAT2 uv{}, uv1{};
    DirectX::XMFLOAT4 color{1, 1, 1, 1};
};

struct MeshInstance
{
    DirectX::XMFLOAT4 positionScale;
    DirectX::XMFLOAT4 rotationVariation; // cos, sin, color variation, wind phase
};

enum class MeshKind : UINT
{
    Model,
    Grass,
    Tree
};

struct MaterialData
{
    DirectX::XMFLOAT4 baseColor{1, 1, 1, 1};
    DirectX::XMFLOAT4 pbr{0, 1, 1, 1}; // metallic, roughness, normal scale, AO strength
    DirectX::XMFLOAT4 emissionCutoff{0, 0, 0, -1};
    // Texture slots in use, mesh kind, double-sided, UV1 slots.
    std::array<UINT, 4> flags{};
};

static_assert(sizeof(MaterialData) == 64);

struct PbrMaterial
{
    MaterialData data;
    std::array<ComPtr<ID3D11ShaderResourceView>, 5> textures;
    std::array<ComPtr<ID3D11SamplerState>, 5> samplers;
};

struct Mesh
{
    ComPtr<ID3D11Buffer> vertices, indices, material;
    std::array<ComPtr<ID3D11ShaderResourceView>, 5> textures;
    std::array<ComPtr<ID3D11SamplerState>, 5> samplers;
    UINT indexCount = 0;
    bool alphaMask = false, doubleSided = false;
    void draw(ID3D11DeviceContext *context, ID3D11Buffer *instances, UINT count, bool shadow) const;
};

ComPtr<ID3D11Buffer> immutableBuffer(ID3D11Device *device, UINT bind,
                                     std::span<const std::byte> data);
Mesh makeMesh(ID3D11Device *device, std::span<const MeshVertex> vertices,
              std::span<const uint32_t> indices, const PbrMaterial &material);

struct StaticModel
{
    std::vector<Mesh> meshes;
    ComPtr<ID3D11Buffer> instance;
};

StaticModel loadStaticModel(ID3D11Device *device, ID3D11DeviceContext *context,
                            const std::filesystem::path &file, DirectX::XMFLOAT3 anchor,
                            float scale);
}
