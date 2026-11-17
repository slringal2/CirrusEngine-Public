#pragma once

#include "scene_mesh.hpp"
#include <limits>
#include <map>
#include <tuple>

namespace cirrus
{
inline constexpr float eyeHeight = 1.68f;
inline constexpr float worldLimit = 500000;

class World
{
  public:
    World(ID3D11Device *device, bool vegetation);
    void update(DirectX::XMFLOAT3 camera);
    float ground(float x, float z) const;
    void walk(DirectX::XMFLOAT3 &position, float x, float z) const;
    void drawTerrain(ID3D11DeviceContext *context, DirectX::FXMMATRIX viewProjection) const;
    void drawPlants(ID3D11DeviceContext *context, bool shadow) const;

    size_t tiles() const
    {
        return terrain_.size();
    }

    UINT trees() const
    {
        return closeTrees_.count + distantTrees_.count;
    }

    UINT grassTufts() const
    {
        return grass_.count;
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
    };

    struct Instances
    {
        ComPtr<ID3D11Buffer> buffer;
        UINT count = 0;
    };

    Tile buildTile(int lod, int x, int z);
    void updateTerrain(float x, float z);
    void updatePlants(DirectX::XMFLOAT3 camera);

    ID3D11Device *device_;
    std::map<TileKey, Tile> terrain_;
    ComPtr<ID3D11Buffer> indices_;
    Mesh grassMesh_, closeTreeMesh_, distantTreeMesh_;
    Instances grass_, closeTrees_, distantTrees_;
    UINT indexCount_ = 0;
    bool vegetation_;
    bool groundDetail_ = false;
    int tileX_ = std::numeric_limits<int>::max(), tileZ_ = tileX_;
    int plantX_ = tileX_, plantZ_ = tileX_;
    uint64_t tilesBuilt_ = 0;
};

DirectX::XMFLOAT3 solarDirection(double hour);
}
