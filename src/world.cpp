#include "world.hpp"
#include "../shaders/river_profile.hlsli"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <numbers>
#include <set>
#include <stdexcept>

namespace cirrus
{
using namespace DirectX;

namespace
{
constexpr int cells = 32;
constexpr int baseTile = 128;
constexpr int farLod = 6;
constexpr float treeSpacing = 19;
constexpr float tau = 2 * std::numbers::pi_v<float>;
constexpr int ridgeSize = 513;
constexpr XMFLOAT2 ridgeMin{-3690, 1000}, ridgeMax{5610, 10300};

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

float trailCenter(float z)
{
    return 4 * std::sin(z * 0.022f) + 11 * std::sin(z * 0.008f);
}

float interpolateTerrain(float a, float b, float c, float d, float u, float v)
{
    // The diagonal is shared with the rendered terrain indices.
    return u + v <= 1 ? a + (b - a) * u + (c - a) * v : d + (c - d) * (1 - u) + (b - d) * (1 - v);
}

MeshInstance plant(float x, float y, float z, float scale, float angle, float tint)
{
    return {{x, y, z, scale}, {std::cos(angle), std::sin(angle), tint, angle}};
}

struct MeshBuilder
{
    std::vector<MeshVertex> vertices;
    std::vector<uint32_t> indices;

    void bark(XMVECTOR start, XMVECTOR end, float radius, float endRadius, int sides)
    {
        XMVECTOR axis = XMVector3Normalize(end - start);
        XMVECTOR side = XMVector3Normalize(XMVector3Cross(axis, XMVectorSet(0, 0, 1, 0)));
        XMVECTOR other = XMVector3Cross(axis, side);
        float repeat = XMVectorGetX(XMVector3Length(end - start)) * 0.72f;
        auto first = static_cast<uint32_t>(vertices.size());
        for (int i = 0; i <= sides; ++i)
        {
            float angle = tau * i / sides;
            XMVECTOR n = side * std::cos(angle) + other * std::sin(angle);
            MeshVertex a, b;
            XMStoreFloat3(&a.normal, n);
            b.normal = a.normal;
            XMStoreFloat3(&a.position, start + n * radius);
            XMStoreFloat3(&b.position, end + n * endRadius);
            a.uv = {static_cast<float>(i) / sides, XMVectorGetY(start) * -0.72f};
            b.uv = {a.uv.x, a.uv.y - repeat};
            vertices.push_back(a);
            vertices.push_back(b);
            if (i > 0)
            {
                uint32_t lo = first + (i - 1) * 2;
                indices.insert(indices.end(), {lo, lo + 2, lo + 1, lo + 2, lo + 3, lo + 1});
            }
        }
    }

    void leafStrip(std::span<const XMVECTOR> centers, XMVECTOR lateral, float width, int tile,
                   float tint, float shadeAtRoot)
    {
        constexpr float inset = 8.5f / 512;
        float u = (tile % 2) * 0.5f + inset, v = (tile / 2) * 0.5f + inset;
        constexpr float span = 0.5f - inset * 2;
        auto first = static_cast<uint32_t>(vertices.size());
        XMVECTOR up = XMVectorSet(0, 1, 0, 0);
        XMVECTOR face =
            XMVector3Normalize(XMVector3Cross(lateral, centers.back() - centers.front()));
        if (XMVectorGetY(face) < 0)
            face = -face;
        for (size_t row = 0; row < centers.size(); ++row)
        {
            float fraction = static_cast<float>(row) / static_cast<float>(centers.size() - 1);
            for (int edge = 0; edge < 2; ++edge)
            {
                float side = edge ? 1.0f : -1.0f;
                MeshVertex vertex;
                XMStoreFloat3(&vertex.position, centers[row] + lateral * (width * side * 0.5f));
                XMVECTOR normal = up + face * 0.31f + lateral * (side * 0.19f);
                XMStoreFloat3(&vertex.normal, XMVector3Normalize(normal));
                vertex.uv = {u + span * edge, v + span * (1 - fraction)};
                float shade = tint * std::lerp(shadeAtRoot, 1.0f, fraction);
                vertex.color = {shade, shade, shade, 1};
                vertices.push_back(vertex);
            }
            if (row > 0)
            {
                uint32_t i = first + static_cast<uint32_t>((row - 1) * 2);
                indices.insert(indices.end(), {i, i + 1, i + 2, i + 2, i + 1, i + 3});
            }
        }
    }

    Mesh create(ID3D11Device *device, const PbrMaterial &material) const
    {
        return makeMesh(device, vertices, indices, material);
    }
};

PbrMaterial plantMaterial(ComPtr<ID3D11ShaderResourceView> leaves, MeshKind kind, float cutoff)
{
    PbrMaterial material;
    material.textures[0] = std::move(leaves);
    material.data.pbr.y = 0.84f;
    material.data.flags = {1, static_cast<UINT>(kind), 1, 0};
    material.data.emissionCutoff.w = cutoff;
    return material;
}

Mesh makeFern(ID3D11Device *device, const PbrMaterial &material)
{
    MeshBuilder mesh;
    for (int leaf = 0; leaf < 11; ++leaf)
    {
        float angle = leaf * 2.3999632f;
        float reach = std::lerp(0.32f, 0.77f, random01(leaf, 0, 41));
        float rise = std::lerp(0.27f, 0.57f, random01(leaf, 0, 42));
        XMVECTOR direction = XMVectorSet(std::cos(angle), 0, std::sin(angle), 0);
        const XMVECTOR rows[] = {XMVectorZero(),
                                 direction * reach * 0.41f + XMVectorSet(0, rise, 0, 0),
                                 direction * reach + XMVectorSet(0, rise * 0.58f, 0, 0)};
        mesh.leafStrip(rows, XMVectorSet(-std::sin(angle), 0, std::cos(angle), 0), reach * 0.46f,
                       leaf % 4, 0.90f + 0.23f * random01(leaf, 0, 43), 0.52f);
    }
    return mesh.create(device, material);
}

Mesh makeBankRock(ID3D11Device *device, const PbrMaterial &material)
{
    MeshBuilder mesh;
    constexpr int sides = 12, rows = 7;
    constexpr float pi = std::numbers::pi_v<float>;
    for (int row = 0; row <= rows; ++row)
    {
        float latitude = pi * (static_cast<float>(row) / rows - 0.5f);
        for (int col = 0; col <= sides; ++col)
        {
            float angle = tau * (col % sides) / sides;
            XMVECTOR direction =
                XMVectorSet(std::cos(angle) * std::cos(latitude), std::sin(latitude),
                            std::sin(angle) * std::cos(latitude), 0);
            float irregular = std::lerp(0.78f, 1.17f, random01(col % sides, row, 58));
            MeshVertex vertex;
            XMStoreFloat3(&vertex.position,
                          direction * XMVectorSet(0.68f, 0.39f, 0.54f, 0) * irregular);
            XMStoreFloat3(&vertex.normal,
                          XMVector3Normalize(direction * XMVectorSet(1.47f, 2.56f, 1.85f, 0)));
            vertex.uv = {static_cast<float>(col) / sides, 1 - static_cast<float>(row) / rows};
            mesh.vertices.push_back(vertex);
            if (row && col)
            {
                uint32_t a = row * (sides + 1) + col;
                uint32_t b = a - sides - 1;
                mesh.indices.insert(mesh.indices.end(), {b - 1, a - 1, b, b, a - 1, a});
            }
        }
    }
    return mesh.create(device, material);
}

std::array<Mesh, 2> makeTree(ID3D11Device *device, const PbrMaterial &barkMaterial,
                             const PbrMaterial &needleMaterial, int form, bool detailed)
{
    MeshBuilder wood, needles;
    const float height = form == 0 ? 17.6f : 14.3f;
    const float crownBase = form == 0 ? 3.15f : 4.1f;
    const float crownWidth = form == 0 ? 4.15f : 4.9f;
    const float rootRadius = form == 0 ? 0.35f : 0.45f;
    auto stem = [&](float y)
    {
        float bend = std::clamp(y / height, 0.0f, 1.0f);
        return XMVectorSet(bend * std::sin(bend * 3.8f + form) * 0.39f, y,
                           bend * std::cos(bend * 6.1f + form) * 0.45f, 0);
    };
    const int segments = detailed ? 6 : 3;
    for (int part = 0; part < segments; ++part)
    {
        float a = static_cast<float>(part) / segments, b = static_cast<float>(part + 1) / segments;
        wood.bark(stem(std::lerp(-0.6f, height, a)), stem(std::lerp(-0.6f, height, b)),
                  rootRadius * std::pow(1 - a, 0.68f) + (part == 0 ? 0.10f : 0.014f),
                  rootRadius * std::pow(1 - b, 0.68f) + 0.014f, detailed ? 11 : 6);
    }

    constexpr int layers = 18;
    for (int level = 0; level < layers; level += detailed ? 1 : 2)
    {
        const float crown = (level + 0.28f) / layers;
        const int branches = level > 13 ? 3 : 5;
        for (int branch = 0; branch < branches; ++branch)
        {
            const int seed = level * 7 + branch + 131 * form;
            const float angle = branch * tau / branches + level * 2.3999632f
                                + (random01(seed, 0, 2) - 0.5f) * 0.82f;
            const float reach = (crownWidth * std::pow(1 - crown, 0.88f) + 0.32f)
                                * std::lerp(0.48f, 1.22f, random01(seed, 0, 3));
            const float y = std::lerp(crownBase, height, crown)
                            + (random01(seed, 0, 5) - 0.5f) * (1.8f - crown);
            const float droop = std::lerp(-1.23f, 0.46f, crown) * (reach * 0.28f);
            const float fork = std::lerp(-0.52f, 0.52f, random01(seed, 0, 10));
            const XMVECTOR out = XMVectorSet(std::cos(angle), 0, std::sin(angle), 0);
            const XMVECTOR side = XMVectorSet(-std::sin(angle), 0, std::cos(angle), 0);
            const XMVECTOR root = stem(y);
            auto branchAt = [&](float fraction)
            {
                return root + out * (reach * fraction) + side * (fork * fraction * fraction)
                       + XMVectorSet(0, droop * fraction + 0.59f * fraction * fraction, 0, 0);
            };
            if (detailed && level < 13)
            {
                float joint = 0.025f + 0.023f * (1 - crown);
                wood.bark(root, branchAt(0.49f), 0.074f * (1 - crown) + 0.016f, joint, 5);
                wood.bark(branchAt(0.49f), branchAt(0.92f), joint, 0.009f, 5);
            }

            const int sprays = detailed ? 9 : 5;
            for (int shoot = 0; shoot < sprays; ++shoot)
            {
                float along = std::lerp(0.18f, 0.92f, (shoot + 0.45f) / sprays);
                float spread = std::lerp(0.19f, 0.47f, random01(seed, shoot, 18));
                spread *= (shoot % 2 ? 1 : -1) * reach * (1 - 0.64f * along);
                float length = (0.66f + 0.40f * reach) * (1 - 0.34f * along);
                const XMVECTOR base = branchAt(along);
                const XMVECTOR tip =
                    base + out * (length * 0.58f) + side * spread
                    + XMVectorSet(0, length * std::lerp(-0.21f, 0.78f, random01(seed, shoot, 22)),
                                  0, 0);
                XMVECTOR axis = XMVector3Normalize(tip - base);
                XMVECTOR across = XMVector3Normalize(XMVector3Cross(axis, XMVectorSet(0, 1, 0, 0)));
                float roll = (random01(seed, shoot, 30) - 0.50f) * 2.24f;
                XMVECTOR lateral =
                    across * std::cos(roll) + XMVector3Cross(axis, across) * std::sin(roll);
                const XMVECTOR rows[] = {base, tip};
                const float width = length * (detailed ? 0.80f : 1.23f);
                float tint = std::lerp(0.64f, 1.35f, random01(seed, shoot, 31));
                needles.leafStrip(rows, lateral, width, (seed + shoot) % 4, tint, 0.56f);
                if (detailed && shoot % 2 == 0)
                    needles.leafStrip(rows, XMVector3Cross(axis, lateral), width * 0.83f,
                                      (seed + shoot + 1) % 4, tint * 0.88f, 0.56f);
            }
        }
    }
    return {wood.create(device, barkMaterial), needles.create(device, needleMaterial)};
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

float World::valleyRidges(float x, float z) const
{
    float u = (x - ridgeMin.x) / (ridgeMax.x - ridgeMin.x);
    float v = (z - ridgeMin.y) / (ridgeMax.y - ridgeMin.y);
    if (u <= 0 || v <= 0 || u >= 1 || v >= 1)
        return 0;

    float sx = u * (ridgeSize - 1), sz = v * (ridgeSize - 1);
    int ix = std::min(static_cast<int>(sx), ridgeSize - 2);
    int iz = std::min(static_cast<int>(sz), ridgeSize - 2);
    size_t i = iz * ridgeSize + ix;
    float front = std::lerp(static_cast<float>(ridgeHeights_[i]),
                            static_cast<float>(ridgeHeights_[i + 1]), sx - ix);
    float back = std::lerp(static_cast<float>(ridgeHeights_[i + ridgeSize]),
                           static_cast<float>(ridgeHeights_[i + ridgeSize + 1]), sx - ix);
    float weight = smooth(0, 0.12f, u) * (1 - smooth(0.87f, 1, u)) * smooth(0, 0.14f, v)
                   * (1 - smooth(0.86f, 1, v));
    return std::lerp(front, back, sz - iz) * weight / 24;
}

float World::terrainHeight(float x, float z) const
{
    float region = noise(x / 5900, z / 5900, 12);
    float rolling = 32 * noise(x / 400, z / 400, 11) + 90 * noise(x / 1600, z / 1600, 23);
    float mountainWeight = smooth(0.44f, 0.73f, region);
    float ridge = 1 - std::abs(2 * noise(x / 2600, z / 2600, 8) - 1);
    float mountains = mountainWeight
                      * (260 * ridge * ridge + 680 * noise(x / 3400, z / 3400, 10)
                         + 125 * noise(x / 750, z / 750, 17));
    float soil = 2.0f * noise(x / 48, z / 48, 21);
    soil += 1.1f * (noise(x / 19, z / 27, 76) - 0.5f);
    float upland = 105 + rolling + mountains + soil + valleyRidges(x, z);
    if (std::abs(z) >= riverExtent || x < -116 || x > 222)
        return upland;

    float sandbars = noise(x / 8, z / 16, 71);
    float bank = riverBankDistance(x, z) + (sandbars - 0.5f) * 4.4f;
    float depth = 1.45f + 1.95f * noise(x / 28, z / 78, 72);
    float wetBed = riverLevel(z) - depth * smooth(0, 13, -bank);
    float dryBank = std::max(bank, 0.0f) * (0.27f + 0.18f * noise(x / 37, z / 53, 73));
    dryBank += (noise(x / 17, z / 27, 74) - 0.43f) * 1.9f * smooth(0.5f, 17.0f, bank);
    float strength = (1 - smooth(8, 88, bank)) * (1 - smooth(2180, riverExtent, std::abs(z)));
    return std::lerp(upland, wetBed + dryBank, strength);
}

std::optional<MeshInstance> World::treeInCell(int cellX, int cellZ) const
{
    float x = (cellX + 0.12f + 0.76f * random01(cellX, cellZ, 1)) * treeSpacing;
    float z = (cellZ + 0.12f + 0.76f * random01(cellX, cellZ, 2)) * treeSpacing;
    float woods = noise(x / 160, z / 160, 42);
    if (std::abs(x - trailCenter(z)) < 4.2f || terrainHeight(x, z) > 1280
        || (std::abs(z) < riverExtent && riverBankDistance(x, z) < 4.1f)
        || random01(cellX, cellZ, 3) > std::lerp(0.07f, 0.90f, smooth(0.22f, 0.76f, woods)))
        return std::nullopt;
    float slope = std::hypot(terrainHeight(x + 3, z) - terrainHeight(x - 3, z),
                             terrainHeight(x, z + 3) - terrainHeight(x, z - 3))
                  / 6;
    if (slope > 0.65f)
        return std::nullopt;
    return plant(x, 0, z, std::lerp(0.48f, 1.38f, random01(cellX, cellZ, 4)),
                 tau * random01(cellX, cellZ, 5),
                 std::lerp(0.65f, 1.32f, random01(cellX, cellZ, 6)));
}

World::World(ID3D11Device *device, ID3D11DeviceContext *context,
             const std::filesystem::path &assets, bool vegetation)
    : device_(device), vegetation_(vegetation)
{
    ridgeHeights_.resize(ridgeSize * ridgeSize);
    const auto relief = std::as_writable_bytes(std::span(ridgeHeights_));
    std::ifstream ridge(assets / L"teton-relief.r16", std::ios::binary | std::ios::ate);
    if (!ridge || ridge.tellg() != static_cast<std::streamoff>(relief.size()))
        throw std::runtime_error("Invalid Teton relief heightfield");
    ridge.seekg(0);
    if (!ridge.read(reinterpret_cast<char *>(relief.data()),
                    static_cast<std::streamsize>(relief.size())))
        throw std::runtime_error("Could not read Teton relief heightfield");

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
    auto texture = [&](const wchar_t *name, bool srgb = true)
    {
        return loadTexture(device, context, assets / name, srgb);
    };
    groundTextures_ = {texture(L"meadow.jpg"),
                       texture(L"soil.jpg"),
                       texture(L"soil-normal.jpg", false),
                       texture(L"gravel.jpg"),
                       texture(L"gravel-normal.jpg", false),
                       texture(L"ridge.jpg"),
                       texture(L"ridge-normal.jpg", false)};
    PbrMaterial stone;
    stone.data.flags = {5, 0, 1, 0};
    stone.data.pbr = {0, 0.87f, 0.42f, 1};
    stone.textures[0] = groundTextures_[3];
    stone.textures[2] = groundTextures_[4];
    rockMesh_ = makeBankRock(device, stone);
    if (vegetation_)
    {
        grass_ = std::make_unique<GrassField>(device, context, assets / L"blade-grain.png");
        fernMesh_ =
            makeFern(device, plantMaterial(texture(L"fern-fronds.png"), MeshKind::Grass, 0.40f));

        PbrMaterial bark;
        bark.textures[0] = texture(L"bark.jpg");
        bark.textures[2] = texture(L"bark-normal.jpg", false);
        bark.data.flags = {5, static_cast<UINT>(MeshKind::Tree), 1, 0};
        bark.data.pbr = {0, 0.91f, 0.83f, 1};
        auto needles = plantMaterial(texture(L"fir-needles.png"), MeshKind::Foliage, 0.29f);
        needles.data.baseColor = {0.71f, 1.65f, 0.93f, 1};
        for (int form = 0; form < 2; ++form)
        {
            treeMeshes_[form] = makeTree(device, bark, needles, form, true);
            treeMeshes_[form + 2] = makeTree(device, bark, needles, form, false);
        }
    }
}

World::Tile World::buildTile(int lod, int x, int z)
{
    int size = baseTile << lod, step = size / cells;
    float xmin = static_cast<float>(x * size), zmin = static_cast<float>(z * size);
    std::vector<TerrainVertex> vertices;
    vertices.reserve((cells + 1) * (cells + 5));
    std::vector<float> heights;
    heights.reserve((cells + 1) * (cells + 1));
    float ymin = std::numeric_limits<float>::max(), ymax = -ymin;
    for (int row = 0; row <= cells; ++row)
        for (int col = 0; col <= cells; ++col)
        {
            float px = xmin + col * step, pz = zmin + row * step;
            float y = terrainHeight(px, pz);
            heights.push_back(y);
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
            {xmin + size, ymax, zmin + size},
            std::move(heights)};
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
        const float distanceSquared = dx * dx + dz * dz;
        bool detailedRidge = lod > 2 && distanceSquared < 11000.0f * 11000.0f && x0 < ridgeMax.x
                             && x0 + size > ridgeMin.x && z0 < ridgeMax.y && z0 + size > ridgeMin.y;
        if (lod > 0 && (distanceSquared < size * size * 1.14f || detailedRidge))
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

void World::uploadInstances(Instances &target, std::span<const MeshInstance> instances)
{
    target.count = static_cast<UINT>(instances.size());
    target.buffer = instances.empty() ? nullptr
                                      : immutableBuffer(device_, D3D11_BIND_VERTEX_BUFFER,
                                                        std::as_bytes(instances));
}

void World::updatePlants(XMFLOAT3 camera)
{
    std::array<std::vector<MeshInstance>, 4> trees;
    std::vector<MeshInstance> ferns;
    constexpr float treeRadius = 1040;
    const int firstX = static_cast<int>(std::floor((camera.x - treeRadius) / treeSpacing));
    const int firstZ = static_cast<int>(std::floor((camera.z - treeRadius) / treeSpacing));
    const int range = static_cast<int>(std::ceil(treeRadius * 2 / treeSpacing)) + 1;
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
            p.y = surface(p.x, p.z) - 0.13f;
            size_t form = random01(ix, iz, 58) < 0.69f ? 0 : 1;
            size_t lod = distance < 155 ? 0 : 2;
            trees[lod + form].push_back(*tree);
        }

    if (groundDetail_)
    {
        constexpr float fernSpacing = 3.2f;
        int fernX = static_cast<int>(std::floor(camera.x / fernSpacing));
        int fernZ = static_cast<int>(std::floor(camera.z / fernSpacing));
        constexpr int fernRange = 18;
        for (int iz = fernZ - fernRange; iz <= fernZ + fernRange; ++iz)
            for (int ix = fernX - fernRange; ix <= fernX + fernRange; ++ix)
            {
                float x = (ix + random01(ix, iz, 43)) * fernSpacing;
                float z = (iz + random01(ix, iz, 44)) * fernSpacing;
                float bank = std::abs(z) < riverExtent ? riverBankDistance(x, z) : 100;
                float moisture = noise(x / 16, z / 16, 80);
                float density = (1 - smooth(36, 58, std::hypot(x - camera.x, z - camera.z)))
                                * moisture * moisture * (bank < 14 ? 1.07f : 0.21f);
                if (bank < 2.4f || std::abs(x - trailCenter(z)) < 2.45f
                    || random01(ix, iz, 45) >= density)
                    continue;
                ferns.push_back(plant(x, ground(x, z) - 0.05f, z,
                                      std::lerp(0.55f, 1.48f, random01(ix, iz, 46)),
                                      tau * random01(ix, iz, 47), 0.77f + 0.33f * moisture));
            }
    }
    for (size_t i = 0; i < trees_.size(); ++i)
        uploadInstances(trees_[i], trees[i]);
    uploadInstances(ferns_, ferns);
}

void World::updateRocks(XMFLOAT3 camera)
{
    std::vector<MeshInstance> rocks;
    // The larger stones break the shoreline and remain in place when the bank streams.
    if (std::abs(camera.x) < 260 && std::abs(camera.z) < riverExtent + 128)
    {
        constexpr float spacing = 3.0f;
        int z0 = static_cast<int>(std::floor(camera.z / spacing));
        for (int iz = z0 - 38; iz <= z0 + 38; ++iz)
        {
            float z = (iz + random01(iz, 0, 74)) * spacing;
            if (std::abs(z) >= riverExtent)
                continue;
            for (int side : {-1, 1})
                for (int i = 0; i < 3; ++i)
                {
                    float offset = std::lerp(-3.4f, 11.0f, random01(iz, side * 3 + i, 78));
                    float x = riverCenter(z) + side * (riverHalfWidth(z) + offset);
                    float cover = noise(x / 8, z / 15, 79);
                    if (std::hypot(x - camera.x, z - camera.z) > 118
                        || std::abs(x - trailCenter(z)) < 1.25f
                        || random01(iz, side * 3 + i, 77) > 0.73f * cover)
                        continue;
                    float size = random01(iz, side * 3 + i, 82);
                    float scale = std::lerp(0.22f, 2.0f, size * size * size);
                    rocks.push_back(plant(x, ground(x, z) - scale * 0.07f, z, scale,
                                          tau * random01(iz, side * 3 + i, 83),
                                          0.66f + 0.58f * cover));
                }
        }
    }
    uploadInstances(rocks_, rocks);
}

float World::surface(float x, float z) const
{
    for (int lod = 0; lod <= farLod; ++lod)
    {
        const int size = baseTile << lod;
        const int col = static_cast<int>(std::floor(x / size));
        const int row = static_cast<int>(std::floor(z / size));
        auto found = terrain_.find({lod, col, row});
        if (found == terrain_.end())
            continue;

        const float step = static_cast<float>(size / cells);
        float ux = (x - col * size) / step, uz = (z - row * size) / step;
        int ix = std::clamp(static_cast<int>(ux), 0, cells - 1);
        int iz = std::clamp(static_cast<int>(uz), 0, cells - 1);
        size_t at = iz * (cells + 1) + ix;
        const auto &h = found->second.heights;
        return interpolateTerrain(h[at], h[at + 1], h[at + cells + 1], h[at + cells + 2], ux - ix,
                                  uz - iz);
    }
    return terrainHeight(x, z);
}

void World::updateGrassHeight(ID3D11DeviceContext *context, XMFLOAT2 origin)
{
    std::vector<float> heights(GrassField::terrainSize * GrassField::terrainSize);
    for (UINT row = 0; row < GrassField::terrainSize; ++row)
        for (UINT col = 0; col < GrassField::terrainSize; ++col)
            heights[row * GrassField::terrainSize + col] = surface(
                origin.x + col * GrassField::terrainStep, origin.y + row * GrassField::terrainStep);
    grass_->setTerrain(context, origin, heights);
}

void World::update(ID3D11DeviceContext *context, XMFLOAT3 camera)
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
    if (terrainChanged || px != plantX_ || pz != plantZ_ || ground != groundDetail_)
    {
        groundDetail_ = ground;
        if (vegetation_)
            updatePlants(camera);
        updateRocks(camera);
        plantX_ = px;
        plantZ_ = pz;
    }
    constexpr float fieldStep = 64;
    int gx = static_cast<int>(std::floor(camera.x / fieldStep));
    int gz = static_cast<int>(std::floor(camera.z / fieldStep));
    if (grass() && (terrainChanged || gx != grassX_ || gz != grassZ_))
    {
        constexpr float offset =
            (GrassField::terrainSize - 1) * GrassField::terrainStep * 0.5f - fieldStep * 0.5f;
        updateGrassHeight(context, {gx * fieldStep - offset, gz * fieldStep - offset});
        grassX_ = gx;
        grassZ_ = gz;
    }
}

float World::ground(float x, float z) const
{
    constexpr float step = baseTile / cells;
    const float x0 = std::floor(x / step) * step, z0 = std::floor(z / step) * step;
    return interpolateTerrain(terrainHeight(x0, z0), terrainHeight(x0 + step, z0),
                              terrainHeight(x0, z0 + step), terrainHeight(x0 + step, z0 + step),
                              (x - x0) / step, (z - z0) / step);
}

void World::placeWalker(XMFLOAT3 &position) const
{
    float y = ground(position.x, position.z);
    if (std::abs(position.z) < riverExtent && riverBankDistance(position.x, position.z) < 4.3f
        && y < riverLevel(position.z) - 0.40f)
    {
        const float origin = position.x;
        // A spawn or landing inside the river moves to the nearest shallow bank.
        for (float offset = 0.5f; offset <= 27.0f && y < riverLevel(position.z) - 0.40f;
             offset += 0.5f)
            for (float side : {-1.0f, 1.0f})
            {
                float x = origin + side * offset;
                float candidate = ground(x, position.z);
                if (candidate >= riverLevel(position.z) - 0.40f)
                {
                    position.x = x;
                    y = candidate;
                    break;
                }
            }
    }
    position.y = y + eyeHeight;
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
        float nextGround = ground(x, z);
        if (std::abs(nextGround - y) > distance * 1.08f)
            return false;
        if (std::abs(z) < riverExtent && riverBankDistance(x, z) < 2
            && nextGround < riverLevel(z) - 0.40f && nextGround < y)
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

void World::bindTerrainMaterials(ID3D11DeviceContext *context) const
{
    std::array<ID3D11ShaderResourceView *, 7> views{};
    for (size_t i = 0; i < groundTextures_.size(); ++i)
        views[i] = groundTextures_[i].Get();
    context->PSSetShaderResources(37, static_cast<UINT>(views.size()), views.data());
}

void World::drawPlants(ID3D11DeviceContext *context, bool shadow,
                       ID3D11PixelShader *shadowMask) const
{
    auto draw = [&](const Mesh &mesh, const Instances &instances)
    {
        if (!instances.count)
            return;
        if (shadow)
            context->PSSetShader(mesh.alphaMask ? shadowMask : nullptr, nullptr, 0);
        mesh.draw(context, instances.buffer.Get(), instances.count, shadow);
    };
    for (size_t i = 0; i < trees_.size(); ++i)
        for (const auto &mesh : treeMeshes_[i])
            draw(mesh, trees_[i]);
    draw(fernMesh_, ferns_);
    draw(rockMesh_, rocks_);
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
