#include "scene_mesh.hpp"
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace cirrus
{
void require(HRESULT hr, const char *operation);

ComPtr<ID3D11Buffer> immutableBuffer(ID3D11Device *device, UINT bind,
                                     std::span<const std::byte> data)
{
    if (data.empty() || data.size() > std::numeric_limits<UINT>::max())
        throw std::runtime_error("Invalid immutable buffer size");
    D3D11_BUFFER_DESC desc{};
    desc.ByteWidth = static_cast<UINT>(data.size());
    desc.Usage = D3D11_USAGE_IMMUTABLE;
    desc.BindFlags = bind;
    const D3D11_SUBRESOURCE_DATA initial{data.data(), 0, 0};
    ComPtr<ID3D11Buffer> buffer;
    require(device->CreateBuffer(&desc, &initial, &buffer),
            "Immutable vertex, index or material buffer");
    return buffer;
}

Mesh makeMesh(ID3D11Device *device, std::span<const MeshVertex> vertices,
              std::span<const uint32_t> indices, const PbrMaterial &material)
{
    Mesh mesh;
    mesh.vertices = immutableBuffer(device, D3D11_BIND_VERTEX_BUFFER, std::as_bytes(vertices));
    mesh.indices = immutableBuffer(device, D3D11_BIND_INDEX_BUFFER, std::as_bytes(indices));
    mesh.material = immutableBuffer(device, D3D11_BIND_CONSTANT_BUFFER,
                                    std::as_bytes(std::span(&material.data, 1)));
    mesh.indexCount = static_cast<UINT>(indices.size());
    mesh.alphaMask = material.data.emissionCutoff.w >= 0;
    mesh.doubleSided = material.data.flags[2] != 0;
    mesh.textures = material.textures;
    mesh.samplers = material.samplers;
    if (std::any_of(mesh.samplers.begin(), mesh.samplers.end(),
                    [](const auto &s)
                    {
                        return !s;
                    }))
    {
        D3D11_SAMPLER_DESC desc{};
        desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        desc.AddressU = desc.AddressV = desc.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
        desc.MaxLOD = D3D11_FLOAT32_MAX;
        ComPtr<ID3D11SamplerState> fallback;
        require(device->CreateSamplerState(&desc, &fallback), "Default material sampler");
        for (auto &sampler : mesh.samplers)
            if (!sampler)
                sampler = fallback;
    }
    return mesh;
}

void Mesh::draw(ID3D11DeviceContext *context, ID3D11Buffer *instances, UINT count,
                bool shadow) const
{
    const UINT strides[] = {sizeof(MeshVertex), sizeof(MeshInstance)};
    const UINT offsets[] = {0, 0};
    ID3D11Buffer *buffers[] = {vertices.Get(), instances};
    context->IASetVertexBuffers(0, 2, buffers, strides, offsets);
    context->IASetIndexBuffer(indices.Get(), DXGI_FORMAT_R32_UINT, 0);
    ID3D11Buffer *constants = material.Get();
    context->VSSetConstantBuffers(3, 1, &constants);
    if (!shadow || alphaMask)
    {
        context->PSSetConstantBuffers(3, 1, &constants);
        ID3D11ShaderResourceView *views[5]{};
        ID3D11SamplerState *filters[5]{};
        for (size_t i = 0; i < textures.size(); ++i)
        {
            views[i] = textures[i].Get();
            filters[i] = samplers[i].Get();
        }
        context->PSSetShaderResources(32, 5, views);
        context->PSSetSamplers(3, 5, filters);
    }
    context->DrawIndexedInstanced(indexCount, count, 0, 0, 0);
}
}
