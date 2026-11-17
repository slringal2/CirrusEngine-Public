#include "world.hpp"
#include <algorithm>
#include <cmath>
#include <numbers>
#include <optional>
#include <set>

namespace cirrus
{
using namespace DirectX;

namespace
{
constexpr int cells = 32;
constexpr int baseTile = 256;
constexpr int farLod = 5;
constexpr float treeSpacing = 22;
constexpr float tau = 2 * std::numbers::pi_v<float>;

float random01(int x, int z, uint32_t seed = 0)
{
    uint32_t n = uint32_t(x) * 0x9e3779b9u ^ uint32_t(z) * 0x85ebca6bu ^ seed * 0xc2b2ae35u;
    n ^= n >> 16;
    n *= 0x7feb352du;
    n ^= n >> 15;
    n *= 0x846ca68bu;
    return static_cast<float>((n ^ (n >> 16)) >> 8) / 16777216.0f;
}

float smooth(float a, float b, float x)
{
    float f = std::clamp((x - a) / (b - a), 0.0f, 1.0f);
    return f * f * (3 - 2 * f);
}

float noise(float x, float z, uint32_t seed)
{
    int ix = static_cast<int>(std::floor(x)), iz = static_cast<int>(std::floor(z));
    float u = smooth(0, 1, x - ix), v = smooth(0, 1, z - iz);
    return std::lerp(std::lerp(random01(ix, iz, seed), random01(ix + 1, iz, seed), u),
                     std::lerp(random01(ix, iz + 1, seed), random01(ix + 1, iz + 1, seed), u), v);
}

float terrainHeight(float x, float z)
{
    float region = noise(x / 5900, z / 5900, 12);
    float rolling = 32 * noise(x / 400, z / 400, 11) + 90 * noise(x / 1600, z / 1600, 23);
    float mountainWeight = smooth(0.44f, 0.73f, region);
    float ridge = 1 - std::abs(2 * noise(x / 2600, z / 2600, 8) - 1);
    float mountains = mountainWeight
                      * (260 * ridge * ridge + 680 * noise(x / 3400, z / 3400, 10)
                         + 125 * noise(x / 750, z / 750, 17));
    float soil = 2.0f * noise(x / 48, z / 48, 21);
    return 105 + rolling + mountains + soil;
}

float trailCenter(float z)
{
    return 4 * std::sin(z * 0.022f) + 11 * std::sin(z * 0.008f);
}

float sampledTerrain(float x, float z, int step)
{
    const float x0 = std::floor(x / step) * step, z0 = std::floor(z / step) * step;
    float u = (x - x0) / step, v = (z - z0) / step;
    float a = terrainHeight(x0, z0), b = terrainHeight(x0 + step, z0);
    float c = terrainHeight(x0, z0 + step), d = terrainHeight(x0 + step, z0 + step);
    // The diagonal is shared with the rendered terrain indices.
    return u + v <= 1 ? a + (b - a) * u + (c - a) * v : d + (c - d) * (1 - u) + (b - d) * (1 - v);
}

MeshInstance plant(float x, float y, float z, float scale, float angle, float tint)
{
    return {{x, y, z, scale}, {std::cos(angle), std::sin(angle), tint, angle}};
}

std::optional<MeshInstance> treeInCell(int cellX, int cellZ)
{
    float x = (cellX + 0.12f + 0.76f * random01(cellX, cellZ, 1)) * treeSpacing;
    float z = (cellZ + 0.12f + 0.76f * random01(cellX, cellZ, 2)) * treeSpacing;
    float woods = noise(x / 160, z / 160, 42);
    if (std::abs(x - trailCenter(z)) < 4.2f || terrainHeight(x, z) > 1280
        || random01(cellX, cellZ, 3) > std::lerp(0.20f, 0.91f, woods))
        return std::nullopt;
    float slope = std::hypot(terrainHeight(x + 3, z) - terrainHeight(x - 3, z),
                             terrainHeight(x, z + 3) - terrainHeight(x, z - 3))
                  / 6;
    if (slope > 0.65f)
        return std::nullopt;
    return plant(x, 0, z, std::lerp(0.52f, 1.55f, random01(cellX, cellZ, 4)),
                 tau * random01(cellX, cellZ, 5),
                 std::lerp(0.65f, 1.32f, random01(cellX, cellZ, 6)));
}

struct MeshBuilder
{
    std::vector<MeshVertex> vertices;
    std::vector<uint32_t> indices;

    void triangle(XMFLOAT3 a, XMFLOAT3 b, XMFLOAT3 c, XMFLOAT3 normal, XMFLOAT4 color, XMFLOAT4 tip)
    {
        auto first = static_cast<uint32_t>(vertices.size());
        vertices.push_back({a, normal, {}, {}, {}, color});
        vertices.push_back({b, normal, {}, {}, {}, color});
        vertices.push_back({c, normal, {}, {}, {}, tip});
        indices.insert(indices.end(), {first, first + 1, first + 2});
    }

    void cylinder(XMFLOAT3 start, XMFLOAT3 end, float radius, float endRadius, int sides,
                  XMFLOAT4 color)
    {
        XMVECTOR p = XMLoadFloat3(&start), q = XMLoadFloat3(&end);
        XMVECTOR axis = XMVector3Normalize(q - p);
        XMVECTOR side = XMVector3Normalize(XMVector3Cross(axis, XMVectorSet(0, 0, 1, 0)));
        XMVECTOR other = XMVector3Cross(axis, side);
        auto first = static_cast<uint32_t>(vertices.size());
        for (int i = 0; i < sides; ++i)
        {
            float angle = tau * i / sides;
            XMVECTOR n = side * std::cos(angle) + other * std::sin(angle);
            MeshVertex a, b;
            XMStoreFloat3(&a.normal, n);
            b.normal = a.normal;
            XMStoreFloat3(&a.position, p + n * radius);
            XMStoreFloat3(&b.position, q + n * endRadius);
            a.color = b.color = color;
            vertices.push_back(a);
            vertices.push_back(b);
            uint32_t lo = first + i * 2, next = first + (i + 1) % sides * 2;
            indices.insert(indices.end(), {lo, next, lo + 1, next, next + 1, lo + 1});
        }
    }
};

Mesh makeGrass(ID3D11Device *device)
{
    MeshBuilder mesh;
    for (int blade = 0; blade < 9; ++blade)
    {
        float angle = tau * random01(blade, 1, 17);
        float c = std::cos(angle), s = std::sin(angle);
        float r = 0.15f * random01(blade, 2, 17);
        float height = 0.22f + 0.38f * random01(blade, 3, 17);
        float bend = 0.12f + random01(blade, 4, 17) * 0.24f;
        float width = 0.016f + random01(blade, 5, 17) * 0.015f;
        auto first = static_cast<uint32_t>(mesh.vertices.size());
        for (int row = 0; row < 3; ++row)
        {
            float t = row / 3.0f, center = r + bend * t * t;
            XMFLOAT4 color{std::lerp(0.035f, 0.17f, t), std::lerp(0.075f, 0.24f, t),
                           std::lerp(0.018f, 0.055f, t), 1};
            for (float sign : {-1.0f, 1.0f})
            {
                float w = width * (1 - t * 0.72f) * sign;
                mesh.vertices.push_back({{c * center - s * w, height * t, s * center + c * w},
                                         {-0.34f * c, 0.94f, -0.34f * s},
                                         {},
                                         {},
                                         {},
                                         color});
            }
            if (row > 0)
            {
                uint32_t i = first + 2 * (row - 1);
                mesh.indices.insert(mesh.indices.end(), {i, i + 1, i + 2, i + 1, i + 3, i + 2});
            }
        }
        mesh.vertices.push_back({{c * (r + bend), height, s * (r + bend)},
                                 {0, 1, 0},
                                 {},
                                 {},
                                 {},
                                 {0.29f, 0.34f, 0.09f, 1}});
        mesh.indices.insert(mesh.indices.end(), {first + 4, first + 5, first + 6});
    }
    PbrMaterial material;
    material.data.pbr.y = 0.86f;
    material.data.flags[1] = static_cast<UINT>(MeshKind::Grass);
    material.data.flags[2] = 1;
    return makeMesh(device, mesh.vertices, mesh.indices, material);
}

Mesh makePine(ID3D11Device *device, bool detailed)
{
    MeshBuilder mesh;
    const XMFLOAT4 bark{0.088f, 0.051f, 0.027f, 1};
    mesh.cylinder({0, -0.8f, 0}, {0.12f, 11.8f, -0.06f}, 0.27f, 0.026f, detailed ? 8 : 5, bark);
    const int layers = detailed ? 13 : 9;
    for (int level = 0; level < layers; ++level)
    {
        float h = (level + 0.15f) / layers;
        float base = 1.8f + 10.65f * h;
        const int branches = detailed ? 7 : 5;
        for (int branch = 0; branch < branches; ++branch)
        {
            float angle = tau * branch / branches + level * 2.39996f
                          + (random01(level, branch, 33) - 0.5f) * 0.3f;
            float extent =
                (2.9f * (1 - h) + 0.2f) * std::lerp(0.67f, 1.19f, random01(level, branch, 4));
            float c = std::cos(angle), s = std::sin(angle);
            float y = base + (random01(level, branch, 12) - 0.5f) * 0.70f;
            if (detailed)
                mesh.cylinder({0, y, 0}, {c * extent * 0.78f, y - 0.27f, s * extent * 0.78f},
                              0.072f * (1 - h) + 0.012f, 0.01f, 4, bark);

            const int shoots = detailed ? 12 : 4;
            for (int shoot = 0; shoot < shoots; ++shoot)
            {
                float along = (shoot + 0.85f) / shoots;
                float side = shoot % 2 == 0 ? 1.0f : -1.0f;
                float r = extent * along;
                float spread = (0.3f + 0.20f * random01(level * 11 + branch, shoot, 87)) * extent
                               * (1 - 0.72f * along);
                XMFLOAT3 root{c * r, y - along * 0.25f, s * r};
                float lift = 0.38f + 0.53f * (1 - h) * random01(level + shoot, branch, 81);
                XMFLOAT3 tip{c * (r + extent * 0.28f) - s * side * spread, root.y + lift,
                             s * (r + extent * 0.28f) + c * side * spread};
                XMFLOAT4 green{0.029f + h * 0.032f, 0.075f + h * 0.073f, 0.031f + h * 0.021f, 1};
                XMFLOAT4 fresh{green.x * 1.19f, green.y * 1.20f, green.z * 1.17f, 1};
                const float fan = extent * (detailed ? 0.135f : 0.25f) + 0.085f;
                XMFLOAT3 middle{std::lerp(root.x, tip.x, 0.42f), std::lerp(root.y, tip.y, 0.42f),
                                std::lerp(root.z, tip.z, 0.42f)};
                mesh.triangle(root, {middle.x + s * fan, middle.y, middle.z - c * fan}, tip,
                              {c * 0.45f, 0.79f, s * 0.45f}, green, fresh);
                mesh.triangle(root, {middle.x - s * fan, middle.y + 0.07f, middle.z + c * fan}, tip,
                              {-s * 0.53f, 0.84f, c * 0.53f}, green, fresh);
                mesh.triangle(root, {middle.x, middle.y + fan, middle.z}, tip,
                              {s * 0.66f, 0.71f, -c * 0.66f}, green, fresh);
            }
        }
    }
    PbrMaterial material;
    material.data.pbr.y = 0.91f;
    material.data.flags[1] = static_cast<UINT>(MeshKind::Tree);
    material.data.flags[2] = 1;
    return makeMesh(device, mesh.vertices, mesh.indices, material);
}

bool visible(XMFLOAT3 min, XMFLOAT3 max, FXMMATRIX matrix)
{
    uint32_t outside = 63;
    for (float z : {min.z, max.z})
        for (float y : {min.y, max.y})
            for (float x : {min.x, max.x})
            {
                XMFLOAT4 p;
                XMStoreFloat4(&p, XMVector4Transform(XMVectorSet(x, y, z, 1), matrix));
                uint32_t mask = (p.x < -p.w ? 1 : 0) | (p.x > p.w ? 2 : 0) | (p.y < -p.w ? 4 : 0)
                                | (p.y > p.w ? 8 : 0) | (p.z < 0 ? 16 : 0) | (p.z > p.w ? 32 : 0);
                outside &= mask;
                if (outside == 0)
                    return true;
            }
    return false;
}
}

World::World(ID3D11Device *device, bool vegetation) : device_(device), vegetation_(vegetation)
{
    std::vector<uint32_t> indices;
    for (int z = 0; z < cells; ++z)
        for (int x = 0; x < cells; ++x)
        {
            uint32_t a = z * (cells + 1) + x, b = a + 1, c = a + cells + 1, d = c + 1;
            indices.insert(indices.end(), {a, c, b, b, c, d});
        }
    // Each border has a skirt. Its vertices follow the same order as buildTile().
    const uint32_t skirt = (cells + 1) * (cells + 1);
    for (uint32_t edge = 0; edge < 4; ++edge)
        for (uint32_t i = 0; i < cells; ++i)
        {
            uint32_t a = edge == 0   ? i
                         : edge == 1 ? cells * (cells + 1) + i
                                     : i * (cells + 1) + (edge == 2 ? 0 : cells);
            uint32_t b = a + (edge < 2 ? 1 : cells + 1);
            uint32_t c = skirt + edge * (cells + 1) + i;
            indices.insert(indices.end(), {a, b, c, b, c + 1, c});
        }
    indices_ = immutableBuffer(device_, D3D11_BIND_INDEX_BUFFER, std::as_bytes(std::span(indices)));
    indexCount_ = static_cast<UINT>(indices.size());
    if (vegetation_)
    {
        grassMesh_ = makeGrass(device_);
        closeTreeMesh_ = makePine(device_, true);
        distantTreeMesh_ = makePine(device_, false);
    }
}

World::Tile World::buildTile(int lod, int x, int z)
{
    int size = baseTile << lod, step = size / cells;
    float xmin = static_cast<float>(x * size), zmin = static_cast<float>(z * size);
    std::vector<TerrainVertex> vertices;
    vertices.reserve((cells + 1) * (cells + 5));
    float ymin = std::numeric_limits<float>::max(), ymax = -ymin;
    for (int row = 0; row <= cells; ++row)
        for (int col = 0; col <= cells; ++col)
        {
            float px = xmin + col * step, pz = zmin + row * step;
            float y = terrainHeight(px, pz);
            float d = 2.0f + step * 0.25f;
            XMFLOAT3 normal;
            XMStoreFloat3(&normal, XMVector3Normalize(XMVectorSet(
                                       terrainHeight(px - d, pz) - terrainHeight(px + d, pz), d * 2,
                                       terrainHeight(px, pz - d) - terrainHeight(px, pz + d), 0)));
            float rock = std::max(smooth(0.13f, 0.49f, 1 - normal.y), smooth(660, 1180, y));
            float grass = noise(px / 90, pz / 90, 18);
            XMFLOAT4 color{std::lerp(0.114f - 0.056f * grass, 0.23f, rock),
                           std::lerp(0.150f - 0.031f * grass, 0.205f, rock),
                           std::lerp(0.046f - 0.017f * grass, 0.17f, rock), 0.91f};
            vertices.push_back({{px, y, pz}, normal, color});
            ymin = std::min(ymin, y);
            ymax = std::max(ymax, y);
        }
    float skirtDepth = std::max(3.0f, step * 1.4f);
    for (int edge = 0; edge < 4; ++edge)
        for (int i = 0; i <= cells; ++i)
        {
            int index = edge == 0   ? i
                        : edge == 1 ? cells * (cells + 1) + i
                                    : i * (cells + 1) + (edge == 2 ? 0 : cells);
            TerrainVertex vertex = vertices[index];
            vertex.position.y -= skirtDepth;
            vertices.push_back(vertex);
        }
    ++tilesBuilt_;
    return {immutableBuffer(device_, D3D11_BIND_VERTEX_BUFFER, std::as_bytes(std::span(vertices))),
            {xmin, ymin - skirtDepth, zmin},
            {xmin + size, ymax, zmin + size}};
}

void World::updateTerrain(float x, float z)
{
    std::set<TileKey> wanted;
    auto visit = [&](auto &&self, int lod, int column, int row) -> void
    {
        int size = baseTile << lod;
        float x0 = static_cast<float>(column * size), z0 = static_cast<float>(row * size);
        float dx = x - std::clamp(x, x0, x0 + size);
        float dz = z - std::clamp(z, z0, z0 + size);
        if (lod > 0 && dx * dx + dz * dz < size * size * 1.14f)
        {
            for (int j = 0; j < 2; ++j)
                for (int i = 0; i < 2; ++i)
                    self(self, lod - 1, column * 2 + i, row * 2 + j);
        }
        else
            wanted.emplace(lod, column, row);
    };
    constexpr int rootSize = baseTile << farLod;
    int cx = static_cast<int>(std::floor(x / rootSize));
    int cz = static_cast<int>(std::floor(z / rootSize));
    for (int row = cz - 4; row <= cz + 4; ++row)
        for (int col = cx - 4; col <= cx + 4; ++col)
            visit(visit, farLod, col, row);
    for (auto key : wanted)
    {
        if (terrain_.contains(key))
            continue;
        auto [lod, col, row] = key;
        terrain_.emplace(key, buildTile(lod, col, row));
    }
    std::erase_if(terrain_,
                  [&](const auto &item)
                  {
                      return !wanted.contains(item.first);
                  });
}

void World::updatePlants(XMFLOAT3 camera)
{
    auto upload = [&](Instances &target, const std::vector<MeshInstance> &instances)
    {
        target.count = static_cast<UINT>(instances.size());
        target.buffer = instances.empty() ? nullptr
                                          : immutableBuffer(device_, D3D11_BIND_VERTEX_BUFFER,
                                                            std::as_bytes(std::span(instances)));
    };
    std::vector<MeshInstance> close, distant, tufts;
    constexpr float treeRadius = 1020, grassRadius = 82, spacing = 0.90f;
    const int firstX = static_cast<int>(std::floor((camera.x - treeRadius) / treeSpacing));
    const int firstZ = static_cast<int>(std::floor((camera.z - treeRadius) / treeSpacing));
    const int range = static_cast<int>(std::ceil(treeRadius * 2 / treeSpacing)) + 1;
    auto terrainSurface = [&](float x, float z)
    {
        for (int lod = 0; lod <= farLod; ++lod)
        {
            const int size = baseTile << lod;
            const int col = static_cast<int>(std::floor(x / size));
            const int row = static_cast<int>(std::floor(z / size));
            if (terrain_.contains({lod, col, row}))
                return sampledTerrain(x, z, size / cells);
        }
        return terrainHeight(x, z);
    };
    for (int iz = firstZ; iz <= firstZ + range; ++iz)
        for (int ix = firstX; ix <= firstX + range; ++ix)
        {
            auto tree = treeInCell(ix, iz);
            if (!tree)
                continue;
            auto &p = tree->positionScale;
            float distance = std::hypot(p.x - camera.x, p.z - camera.z);
            if (distance > treeRadius)
                continue;
            p.y = terrainSurface(p.x, p.z) - 0.13f;
            (distance < 210 ? close : distant).push_back(*tree);
        }

    const int grassX = static_cast<int>(std::floor(camera.x / spacing));
    const int grassZ = static_cast<int>(std::floor(camera.z / spacing));
    const int grassRange = static_cast<int>(std::ceil(grassRadius / spacing));
    if (groundDetail_)
        for (int iz = grassZ - grassRange; iz <= grassZ + grassRange; ++iz)
            for (int ix = grassX - grassRange; ix <= grassX + grassRange; ++ix)
            {
                float x = (ix + random01(ix, iz, 29)) * spacing;
                float z = (iz + random01(ix, iz, 37)) * spacing;
                float distance = std::hypot(x - camera.x, z - camera.z);
                float soil = noise(x / 9, z / 9, 20);
                float density = smooth(1.35f, 2.55f, std::abs(x - trailCenter(z)))
                                * std::lerp(0.24f, 0.97f, soil)
                                * (1 - smooth(32, grassRadius, distance));
                if (random01(ix, iz, 17) >= density)
                    continue;
                float y = ground(x, z);
                tufts.push_back(plant(x, y - 0.035f, z,
                                      std::lerp(0.48f, 1.37f, random01(ix, iz, 13)),
                                      tau * random01(ix, iz, 32), std::lerp(0.7f, 1.18f, soil)));
            }
    upload(closeTrees_, close);
    upload(distantTrees_, distant);
    upload(grass_, tufts);
}

void World::update(XMFLOAT3 camera)
{
    int tx = static_cast<int>(std::floor(camera.x / 128)),
        tz = static_cast<int>(std::floor(camera.z / 128));
    bool terrainChanged = tx != tileX_ || tz != tileZ_;
    if (terrainChanged)
    {
        updateTerrain(tx * 128.0f + 64, tz * 128.0f + 64);
        tileX_ = tx;
        tileZ_ = tz;
    }
    constexpr float plantCell = 7.0f;
    int px = static_cast<int>(std::floor(camera.x / plantCell));
    int pz = static_cast<int>(std::floor(camera.z / plantCell));
    bool ground = camera.y - this->ground(camera.x, camera.z) < 120;
    if (vegetation_
        && (terrainChanged || px != plantX_ || pz != plantZ_ || ground != groundDetail_))
    {
        groundDetail_ = ground;
        updatePlants(camera);
        plantX_ = px;
        plantZ_ = pz;
    }
}

float World::ground(float x, float z) const
{
    return sampledTerrain(x, z, baseTile / cells);
}

void World::walk(XMFLOAT3 &position, float dx, float dz) const
{
    // Substeps preserve slope and trunk collision even at the maximum simulation time step.
    int steps = std::max(1, static_cast<int>(std::ceil(std::hypot(dx, dz) / 0.36f)));
    dx /= steps;
    dz /= steps;
    auto canMove = [&](float x, float z, float y)
    {
        if (std::abs(x) > worldLimit || std::abs(z) > worldLimit)
            return false;
        float distance = std::hypot(x - position.x, z - position.z);
        if (std::abs(ground(x, z) - y) > distance * 1.08f)
            return false;
        if (!vegetation_)
            return true;
        for (int row = -1; row <= 1; ++row)
            for (int col = -1; col <= 1; ++col)
            {
                auto tree = treeInCell(static_cast<int>(std::floor(x / treeSpacing)) + col,
                                       static_cast<int>(std::floor(z / treeSpacing)) + row);
                if (!tree)
                    continue;
                const auto &p = tree->positionScale;
                float radius = 0.30f + 0.30f * p.w;
                float next = std::hypot(x - p.x, z - p.z);
                if (next < radius && next < std::hypot(position.x - p.x, position.z - p.z))
                    return false;
            }
        return true;
    };
    for (int i = 0; i < steps; ++i)
    {
        float y = ground(position.x, position.z);
        if (canMove(position.x + dx, position.z + dz, y))
        {
            position.x += dx;
            position.z += dz;
        }
        else if (canMove(position.x + dx, position.z, y) && dx != 0)
            position.x += dx;
        else if (canMove(position.x, position.z + dz, y))
            position.z += dz;
    }
    position.y = ground(position.x, position.z) + eyeHeight;
}

void World::drawTerrain(ID3D11DeviceContext *context, FXMMATRIX viewProjection) const
{
    const UINT stride = sizeof(TerrainVertex), zero = 0;
    context->IASetIndexBuffer(indices_.Get(), DXGI_FORMAT_R32_UINT, 0);
    for (const auto &[key, tile] : terrain_)
    {
        if (!visible(tile.min, tile.max, viewProjection))
            continue;
        ID3D11Buffer *vertex = tile.vertices.Get();
        context->IASetVertexBuffers(0, 1, &vertex, &stride, &zero);
        context->DrawIndexed(indexCount_, 0, 0);
    }
}

void World::drawPlants(ID3D11DeviceContext *context, bool shadow) const
{
    if (closeTrees_.count)
        closeTreeMesh_.draw(context, closeTrees_.buffer.Get(), closeTrees_.count, shadow);
    if (distantTrees_.count)
        distantTreeMesh_.draw(context, distantTrees_.buffer.Get(), distantTrees_.count, shadow);
    if (grass_.count && !shadow)
        grassMesh_.draw(context, grass_.buffer.Get(), grass_.count, false);
}

XMFLOAT3 solarDirection(double hour)
{
    // Local solar time, a fixed latitude and summer solar declination.
    constexpr double latitude = 40.0 * std::numbers::pi / 180.0;
    constexpr double declination = 16.0 * std::numbers::pi / 180.0;
    double angle = (hour - 12.0) * std::numbers::pi / 12.0;
    return {static_cast<float>(-std::cos(declination) * std::sin(angle)),
            static_cast<float>(std::sin(latitude) * std::sin(declination)
                               + std::cos(latitude) * std::cos(declination) * std::cos(angle)),
            static_cast<float>(std::cos(latitude) * std::sin(declination)
                               - std::sin(latitude) * std::cos(declination) * std::cos(angle))};
}
}
