#pragma once

#include "scene_mesh.hpp"
#include "grass.hpp"
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <tuple>

namespace cirrus
{
inline constexpr float eyeHeight = 1.68f;
inline constexpr float worldLimit = 500000;

class World
{
  public:
    World(ID3D11Device *device, ID3D11DeviceContext *context, const std::filesystem::path &assets,
          bool vegetation);
    void update(ID3D11DeviceContext *context, DirectX::XMFLOAT3 camera);
    float ground(float x, float z) const;
    void placeWalker(DirectX::XMFLOAT3 &position) const;
    void walk(DirectX::XMFLOAT3 &position, float x, float z) const;
    void drawTerrain(ID3D11DeviceContext *context, DirectX::FXMMATRIX viewProjection) const;
    void bindTerrainMaterials(ID3D11DeviceContext *context) const;
    void drawPlants(ID3D11DeviceContext *context, bool shadow, ID3D11PixelShader *shadowMask) const;

    size_t tiles() const
    {
        return terrain_.size();
    }

    UINT trees() const
    {
        UINT count = 0;
        for (const auto &batch : trees_)
            count += batch.count;
        return count;
    }

    GrassField *grass() const
    {
        return groundDetail_ ? grass_.get() : nullptr;
    }

    UINT ferns() const
    {
        return ferns_.count;
    }

    UINT rocks() const
    {
        return rocks_.count;
    }

    uint64_t tilesBuilt() const
    {
        return tilesBuilt_;
    }

  private:
    using TileKey = std::tuple<int, int, int>; // LOD, X, Z

    struct Tile
    {
        ComPtr<ID3D11Buffer> vertices;
        DirectX::XMFLOAT3 min, max;
        std::vector<float> heights;
    };

    struct Instances
    {
        ComPtr<ID3D11Buffer> buffer;
        UINT count = 0;
    };

    Tile buildTile(int lod, int x, int z);
    void updateTerrain(float x, float z);
    float terrainHeight(float x, float z) const;
    float valleyRidges(float x, float z) const;
    float surface(float x, float z) const;
    std::optional<MeshInstance> treeInCell(int cellX, int cellZ) const;
    void updateGrassHeight(ID3D11DeviceContext *context, DirectX::XMFLOAT2 origin);
    void updatePlants(DirectX::XMFLOAT3 camera);
    void updateRocks(DirectX::XMFLOAT3 camera);
    void uploadInstances(Instances &target, std::span<const MeshInstance> instances);

    ID3D11Device *device_;
    std::map<TileKey, Tile> terrain_;
    std::vector<uint16_t> ridgeHeights_;
    ComPtr<ID3D11Buffer> indices_;
    std::array<ComPtr<ID3D11ShaderResourceView>, 7> groundTextures_;
    std::array<std::array<Mesh, 2>, 4> treeMeshes_; // bark and needles, two forms per LOD
    std::unique_ptr<GrassField> grass_;
    Mesh fernMesh_;
    std::array<Instances, 4> trees_;
    Instances ferns_;
    Mesh rockMesh_;
    Instances rocks_;
    UINT indexCount_ = 0;
    bool vegetation_;
    bool groundDetail_ = false;
    int tileX_ = std::numeric_limits<int>::max(), tileZ_ = tileX_;
    int plantX_ = tileX_, plantZ_ = tileX_;
    int grassX_ = tileX_, grassZ_ = tileX_;
    uint64_t tilesBuilt_ = 0;
};

DirectX::XMFLOAT3 solarDirection(double hour);
}
