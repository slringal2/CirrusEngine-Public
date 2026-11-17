#include "scene_mesh.hpp"

#pragma warning(push, 0)
#define CGLTF_IMPLEMENTATION
#include "../third_party/cgltf/cgltf.h"
#pragma warning(pop)

#include <wincodec.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <numeric>
#include <stdexcept>
#include <string_view>

namespace cirrus
{
using namespace DirectX;
void require(HRESULT hr, const char *operation);

namespace
{
[[noreturn]] void invalidModel(const char *message)
{
    throw std::runtime_error(std::string("glTF: ") + message);
}

std::filesystem::path utf8Path(std::string_view name)
{
    return std::filesystem::path(std::u8string(name.begin(), name.end()));
}

cgltf_result readFile(const cgltf_memory_options *, const cgltf_file_options *, const char *path,
                      cgltf_size *size, void **data)
{
    try
    {
        std::ifstream file(utf8Path(path), std::ios::binary | std::ios::ate);
        if (!file)
            return cgltf_result_file_not_found;
        const auto available = file.tellg();
        if (available < 0 || static_cast<uintmax_t>(available) > std::numeric_limits<size_t>::max())
            return cgltf_result_io_error;
        size_t bytes = *size ? *size : static_cast<size_t>(available);
        if (bytes > static_cast<size_t>(available))
            return cgltf_result_data_too_short;
        std::unique_ptr<void, decltype(&std::free)> buffer(std::malloc(std::max<size_t>(bytes, 1)),
                                                           &std::free);
        if (!buffer)
            return cgltf_result_out_of_memory;
        file.seekg(0);
        if (!file.read(static_cast<char *>(buffer.get()), static_cast<std::streamsize>(bytes)))
            return cgltf_result_io_error;
        *size = bytes;
        *data = buffer.release();
        return cgltf_result_success;
    }
    catch (...)
    {
        return cgltf_result_io_error;
    }
}

struct ImageLoader
{
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    std::filesystem::path directory;
    ComPtr<IWICImagingFactory> factory;
    std::map<std::pair<const cgltf_image *, bool>, ComPtr<ID3D11ShaderResourceView>> images;
    std::map<const cgltf_sampler *, ComPtr<ID3D11SamplerState>> samplers;

    ImageLoader(ID3D11Device *dev, ID3D11DeviceContext *ctx, std::filesystem::path dir)
        : device(dev), context(ctx), directory(std::move(dir))
    {
        require(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_PPV_ARGS(&factory)),
                "Create glTF image decoder");
    }

    ComPtr<ID3D11ShaderResourceView> image(const cgltf_image *source, bool srgb)
    {
        if (!source)
            invalidModel("a texture requires a PNG or JPEG image");
        const auto key = std::make_pair(source, srgb);
        if (auto found = images.find(key); found != images.end())
            return found->second;

        ComPtr<IWICBitmapDecoder> decoder;
        ComPtr<IWICStream> stream;
        std::unique_ptr<void, decltype(&std::free)> decoded(nullptr, &std::free);
        std::string_view uri = source->uri ? source->uri : "";
        if (source->buffer_view || uri.starts_with("data:"))
        {
            const uint8_t *bytes = nullptr;
            size_t size = 0;
            if (source->buffer_view)
            {
                bytes = cgltf_buffer_view_data(source->buffer_view);
                size = source->buffer_view->size;
            }
            else
            {
                const size_t comma = uri.find(',');
                if (comma == uri.npos || !uri.substr(0, comma).ends_with(";base64"))
                    invalidModel("embedded image data is not base64");
                auto contents = uri.substr(comma + 1);
                if (contents.empty() || contents.size() % 4 != 0)
                    invalidModel("invalid embedded image length");
                size = (contents.size() / 4) * 3
                       - (contents.ends_with("==")  ? 2
                          : contents.ends_with("=") ? 1
                                                    : 0);
                cgltf_options options{};
                void *result = nullptr;
                if (cgltf_load_buffer_base64(&options, size, contents.data(), &result)
                    != cgltf_result_success)
                    invalidModel("invalid embedded image data");
                decoded.reset(result);
                bytes = static_cast<const uint8_t *>(result);
            }
            if (!bytes || size == 0 || size > std::numeric_limits<DWORD>::max())
                invalidModel("invalid image buffer");
            require(factory->CreateStream(&stream), "Create glTF image stream");
            require(
                stream->InitializeFromMemory(const_cast<BYTE *>(bytes), static_cast<DWORD>(size)),
                "Initialize embedded glTF image");
            require(factory->CreateDecoderFromStream(stream.Get(), nullptr,
                                                     WICDecodeMetadataCacheOnLoad, &decoder),
                    "Decode embedded glTF image");
        }
        else
        {
            if (uri.empty() || uri.find("://") != uri.npos)
                invalidModel("image URI must refer to a local file");
            std::string filename(uri);
            filename.resize(cgltf_decode_uri(filename.data()));
            const auto file = directory / utf8Path(filename);
            require(factory->CreateDecoderFromFilename(file.c_str(), nullptr, GENERIC_READ,
                                                       WICDecodeMetadataCacheOnLoad, &decoder),
                    "Decode external glTF image");
        }

        auto view = uploadTexture(device, context, factory.Get(), decoder.Get(), srgb);
        images.emplace(key, view);
        return view;
    }

    ComPtr<ID3D11SamplerState> sampler(const cgltf_sampler *source)
    {
        if (auto found = samplers.find(source); found != samplers.end())
            return found->second;
        auto address = [](cgltf_wrap_mode mode)
        {
            if (mode == cgltf_wrap_mode_clamp_to_edge)
                return D3D11_TEXTURE_ADDRESS_CLAMP;
            if (mode == cgltf_wrap_mode_mirrored_repeat)
                return D3D11_TEXTURE_ADDRESS_MIRROR;
            return D3D11_TEXTURE_ADDRESS_WRAP;
        };
        const auto min = source ? source->min_filter : cgltf_filter_type_undefined;
        const auto mag = source ? source->mag_filter : cgltf_filter_type_undefined;
        bool linearMin = min != cgltf_filter_type_nearest
                         && min != cgltf_filter_type_nearest_mipmap_nearest
                         && min != cgltf_filter_type_nearest_mipmap_linear;
        bool linearMip = min == cgltf_filter_type_undefined
                         || min == cgltf_filter_type_linear_mipmap_linear
                         || min == cgltf_filter_type_nearest_mipmap_linear;
        auto filter = [](bool linear)
        {
            return linear ? D3D11_FILTER_TYPE_LINEAR : D3D11_FILTER_TYPE_POINT;
        };
        D3D11_SAMPLER_DESC desc{};
        desc.Filter =
            D3D11_ENCODE_BASIC_FILTER(filter(linearMin), filter(mag != cgltf_filter_type_nearest),
                                      filter(linearMip), D3D11_FILTER_REDUCTION_TYPE_STANDARD);
        desc.AddressU = source ? address(source->wrap_s) : D3D11_TEXTURE_ADDRESS_WRAP;
        desc.AddressV = source ? address(source->wrap_t) : D3D11_TEXTURE_ADDRESS_WRAP;
        desc.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
        desc.MaxLOD = min == cgltf_filter_type_linear || min == cgltf_filter_type_nearest
                          ? 0
                          : D3D11_FLOAT32_MAX;
        ComPtr<ID3D11SamplerState> result;
        require(device->CreateSamplerState(&desc, &result), "Create glTF sampler");
        samplers.emplace(source, result);
        return result;
    }

    PbrMaterial material(const cgltf_material *source)
    {
        PbrMaterial result;
        result.data.pbr.x = 1;
        if (!source)
            return result;
        if (source->alpha_mode == cgltf_alpha_mode_blend)
            invalidModel("alpha BLEND needs a transparent pass; use OPAQUE or MASK");
        const auto &pbr = source->pbr_metallic_roughness;
        result.data.baseColor = XMFLOAT4(pbr.base_color_factor);
        result.data.pbr = {pbr.metallic_factor, pbr.roughness_factor, source->normal_texture.scale,
                           source->occlusion_texture.scale};
        float strength =
            source->has_emissive_strength ? source->emissive_strength.emissive_strength : 1;
        result.data.emissionCutoff = {
            source->emissive_factor[0] * strength, source->emissive_factor[1] * strength,
            source->emissive_factor[2] * strength,
            source->alpha_mode == cgltf_alpha_mode_mask ? source->alpha_cutoff : -1};
        result.data.flags[2] = source->double_sided;

        const cgltf_texture_view slots[] = {pbr.base_color_texture, pbr.metallic_roughness_texture,
                                            source->normal_texture, source->occlusion_texture,
                                            source->emissive_texture};
        for (UINT i = 0; i < std::size(slots); ++i)
        {
            const auto &slot = slots[i];
            if (!slot.texture)
                continue;
            if (slot.texcoord < 0 || slot.texcoord > 1)
                invalidModel("only TEXCOORD_0 and TEXCOORD_1 are supported");
            result.textures[i] = image(slot.texture->image, i == 0 || i == 4);
            result.samplers[i] = sampler(slot.texture->sampler);
            result.data.flags[0] |= 1u << i;
            if (slot.texcoord == 1)
                result.data.flags[3] |= 1u << i;
        }
        return result;
    }
};

struct Primitive
{
    std::vector<MeshVertex> vertices;
    std::vector<uint32_t> indices;
    const cgltf_material *material;
};

std::vector<float> unpack(const cgltf_accessor *accessor, size_t count, size_t components)
{
    if (!accessor)
        return {};
    if (accessor->count != count || cgltf_num_components(accessor->type) != components)
        invalidModel("vertex attribute has an unexpected size");
    std::vector<float> values(count * components);
    if (cgltf_accessor_unpack_floats(accessor, values.data(), values.size()) != values.size())
        invalidModel("could not decode a vertex attribute");
    if (std::any_of(values.begin(), values.end(),
                    [](float v)
                    {
                        return !std::isfinite(v);
                    }))
        invalidModel("vertex attribute contains a non-finite value");
    return values;
}

Primitive readPrimitive(const cgltf_primitive &primitive, FXMMATRIX transform)
{
    auto attribute = [&](cgltf_attribute_type type, int index = 0) -> const cgltf_accessor *
    {
        for (size_t i = 0; i < primitive.attributes_count; ++i)
        {
            const auto &candidate = primitive.attributes[i];
            if (candidate.type == type && candidate.index == index)
                return candidate.data;
        }
        return nullptr;
    };
    const cgltf_accessor *position = attribute(cgltf_attribute_type_position);
    if (!position || !position->count
        || position->count > std::numeric_limits<UINT>::max() / sizeof(MeshVertex))
        invalidModel("missing or oversized POSITION data");
    if (primitive.has_draco_mesh_compression || primitive.targets_count != 0)
        invalidModel("compressed or morph-target meshes are unsupported");
    size_t count = position->count;
    auto positions = unpack(position, count, 3);
    auto normals = unpack(attribute(cgltf_attribute_type_normal), count, 3);
    auto tangents = unpack(attribute(cgltf_attribute_type_tangent), count, 4);
    auto uv = unpack(attribute(cgltf_attribute_type_texcoord), count, 2);
    auto uv1 = unpack(attribute(cgltf_attribute_type_texcoord, 1), count, 2);
    const auto *color = attribute(cgltf_attribute_type_color);
    size_t colorSize = color ? cgltf_num_components(color->type) : 0;
    if (color && colorSize != 3 && colorSize != 4)
        invalidModel("vertex colors must have three or four components");
    auto colors = unpack(color, count, colorSize);
    const float determinant = XMVectorGetX(XMMatrixDeterminant(transform));
    if (!std::isfinite(determinant) || std::abs(determinant) < 1e-20f)
        invalidModel("singular or invalid node transform");
    XMMATRIX normalTransform = XMMatrixTranspose(XMMatrixInverse(nullptr, transform));
    float orientation = determinant < 0 ? -1.0f : 1.0f;

    Primitive result;
    result.material = primitive.material;
    result.vertices.resize(count);
    for (size_t i = 0; i < count; ++i)
    {
        auto &vertex = result.vertices[i];
        XMFLOAT3 p(positions.data() + i * 3);
        XMStoreFloat3(&vertex.position, XMVector3TransformCoord(XMLoadFloat3(&p), transform));
        if (!normals.empty())
        {
            XMFLOAT3 n(normals.data() + i * 3);
            XMStoreFloat3(&vertex.normal, XMVector3Normalize(XMVector3TransformNormal(
                                              XMLoadFloat3(&n), normalTransform)));
        }
        else
            vertex.normal = {};
        if (!tangents.empty())
        {
            XMFLOAT3 t(tangents.data() + i * 4);
            XMVECTOR tangent =
                XMVector3Normalize(XMVector3TransformNormal(XMLoadFloat3(&t), transform));
            XMStoreFloat4(&vertex.tangent,
                          XMVectorSetW(tangent, tangents[i * 4 + 3] * orientation));
        }
        if (!uv.empty())
            vertex.uv = XMFLOAT2(uv.data() + i * 2);
        if (!uv1.empty())
            vertex.uv1 = XMFLOAT2(uv1.data() + i * 2);
        if (color)
            vertex.color = {colors[i * colorSize], colors[i * colorSize + 1],
                            colors[i * colorSize + 2],
                            colorSize == 4 ? colors[i * colorSize + 3] : 1};
    }

    size_t indexCount = primitive.indices ? primitive.indices->count : count;
    if (indexCount < 3 || indexCount > std::numeric_limits<UINT>::max() / sizeof(uint32_t))
        invalidModel("invalid index count");
    std::vector<uint32_t> indices(indexCount);
    if (primitive.indices)
    {
        if (cgltf_accessor_unpack_indices(primitive.indices, indices.data(), sizeof(uint32_t),
                                          indexCount)
            != indexCount)
            invalidModel("could not decode primitive indices");
    }
    else
        std::iota(indices.begin(), indices.end(), 0u);
    if (std::any_of(indices.begin(), indices.end(),
                    [count](uint32_t index)
                    {
                        return index >= count;
                    }))
        invalidModel("index outside the vertex array");
    auto addTriangle = [&](uint32_t a, uint32_t b, uint32_t c)
    {
        if (a != b && b != c && a != c)
            result.indices.insert(result.indices.end(),
                                  {a, orientation < 0 ? c : b, orientation < 0 ? b : c});
    };
    switch (primitive.type)
    {
    case cgltf_primitive_type_triangles:
        if (indexCount % 3 != 0)
            invalidModel("triangle index count is not divisible by three");
        for (size_t i = 0; i < indexCount; i += 3)
            addTriangle(indices[i], indices[i + 1], indices[i + 2]);
        break;
    case cgltf_primitive_type_triangle_strip:
        for (size_t i = 0; i + 2 < indexCount; ++i)
            addTriangle(indices[i + (i % 2)], indices[i + 1 - (i % 2)], indices[i + 2]);
        break;
    case cgltf_primitive_type_triangle_fan:
        for (size_t i = 1; i + 1 < indexCount; ++i)
            addTriangle(indices[0], indices[i], indices[i + 1]);
        break;
    default:
        invalidModel("the scene must contain triangle geometry");
    }
    if (normals.empty())
    {
        for (size_t i = 0; i < result.indices.size(); i += 3)
        {
            auto &a = result.vertices[result.indices[i]];
            auto &b = result.vertices[result.indices[i + 1]];
            auto &c = result.vertices[result.indices[i + 2]];
            XMVECTOR origin = XMLoadFloat3(&a.position);
            XMVECTOR n = XMVector3Cross(XMLoadFloat3(&b.position) - origin,
                                        XMLoadFloat3(&c.position) - origin);
            for (auto *v : {&a, &b, &c})
                XMStoreFloat3(&v->normal, XMLoadFloat3(&v->normal) + n);
        }
        for (auto &vertex : result.vertices)
        {
            XMVECTOR n = XMLoadFloat3(&vertex.normal);
            XMStoreFloat3(&vertex.normal, XMVectorGetX(XMVector3LengthSq(n)) > 0
                                              ? XMVector3Normalize(n)
                                              : XMVectorSet(0, 1, 0, 0));
        }
    }
    return result;
}
}

StaticModel loadStaticModel(ID3D11Device *device, ID3D11DeviceContext *context,
                            const std::filesystem::path &file, XMFLOAT3 anchor, float scale)
{
    cgltf_options options{};
    options.file.read = readFile;
    auto u8 = file.u8string();
    std::string filename(u8.begin(), u8.end());
    cgltf_data *parsed = nullptr;
    if (cgltf_parse_file(&options, filename.c_str(), &parsed) != cgltf_result_success)
        invalidModel("could not parse model file");
    std::unique_ptr<cgltf_data, decltype(&cgltf_free)> data(parsed, &cgltf_free);
    if (cgltf_load_buffers(&options, data.get(), filename.c_str()) != cgltf_result_success
        || cgltf_validate(data.get()) != cgltf_result_success)
        invalidModel("missing buffers or invalid scene data");
    for (size_t i = 0; i < data->extensions_required_count; ++i)
    {
        std::string_view extension = data->extensions_required[i];
        if (extension != "KHR_mesh_quantization" && extension != "KHR_materials_emissive_strength")
            throw std::runtime_error("glTF: unsupported required extension "
                                     + std::string(extension));
    }

    ImageLoader images(device, context, file.parent_path());
    StaticModel model;
    std::map<const cgltf_material *, PbrMaterial> materials;
    XMVECTOR min = XMVectorReplicate(std::numeric_limits<float>::max());
    XMVECTOR max = -min;
    auto visit = [&](auto &&self, const cgltf_node &node) -> void
    {
        if (node.mesh)
        {
            if (node.skin)
                invalidModel("skinned meshes are unsupported");
            XMFLOAT4X4 matrix;
            cgltf_node_transform_world(&node, &matrix._11);
            // glTF's column-major right-handed transform is the row-vector matrix in DirectXMath.
            XMMATRIX transform = XMLoadFloat4x4(&matrix) * XMMatrixScaling(1, 1, -1);
            for (size_t i = 0; i < node.mesh->primitives_count; ++i)
            {
                Primitive primitive = readPrimitive(node.mesh->primitives[i], transform);
                if (primitive.indices.empty())
                    continue;
                for (const auto &v : primitive.vertices)
                {
                    XMVECTOR p = XMLoadFloat3(&v.position);
                    min = XMVectorMin(min, p);
                    max = XMVectorMax(max, p);
                }
                auto [material, inserted] = materials.try_emplace(primitive.material);
                if (inserted)
                    material->second = images.material(primitive.material);
                model.meshes.push_back(
                    makeMesh(device, primitive.vertices, primitive.indices, material->second));
            }
        }
        for (size_t i = 0; i < node.children_count; ++i)
            self(self, *node.children[i]);
    };
    const cgltf_scene *scene = data->scene          ? data->scene
                               : data->scenes_count ? &data->scenes[0]
                                                    : nullptr;
    if (scene)
        for (size_t i = 0; i < scene->nodes_count; ++i)
            visit(visit, *scene->nodes[i]);
    else
        for (size_t i = 0; i < data->nodes_count; ++i)
            if (!data->nodes[i].parent)
                visit(visit, data->nodes[i]);
    if (model.meshes.empty())
        invalidModel("active scene has no drawable triangles");
    XMFLOAT3 center;
    XMStoreFloat3(&center, (min + max) * 0.5f);
    const MeshInstance instance{{anchor.x - center.x * scale, anchor.y - XMVectorGetY(min) * scale,
                                 anchor.z - center.z * scale, scale},
                                {1, 0, 1, 0}};
    model.instance =
        immutableBuffer(device, D3D11_BIND_VERTEX_BUFFER, std::as_bytes(std::span(&instance, 1)));
    return model;
}
}
