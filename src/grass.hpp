#pragma once

#include "scene_mesh.hpp"

namespace cirrus
{
class GrassField
{
  public:
    static constexpr unsigned terrainSize = 193;
    static constexpr float terrainStep = 4;
    static constexpr size_t lodCount = 3;

    GrassField(ID3D11Device *device, ID3D11DeviceContext *context,
               const std::filesystem::path &bladeGrain);
    void setTerrain(ID3D11DeviceContext *context, DirectX::XMFLOAT2 origin,
                    std::span<const float> heights);
    void select(ID3D11DeviceContext *context, ID3D11ComputeShader *shader, DirectX::XMFLOAT3 camera,
                const DirectX::XMFLOAT4X4 &viewProjection);
    void draw(ID3D11DeviceContext *context, bool shadow) const;
    std::array<UINT, lodCount> counts(ID3D11DeviceContext *context) const;

  private:
    struct Lod
    {
        ComPtr<ID3D11Buffer> settings, arguments, indices;
        ComPtr<ID3D11ShaderResourceView> sites;
        ComPtr<ID3D11UnorderedAccessView> append;
    };

    std::array<Lod, lodCount> lods_;
    ComPtr<ID3D11Texture2D> heightTexture_;
    ComPtr<ID3D11ShaderResourceView> heightView_;
    ComPtr<ID3D11ShaderResourceView> bladeGrain_;
    ComPtr<ID3D11Buffer> readback_;
    DirectX::XMFLOAT2 terrainOrigin_{};
    DirectX::XMFLOAT4X4 selectedView_{};
    ID3D11ComputeShader *selectedShader_ = nullptr;
};
}
