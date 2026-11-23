#include "ui.hpp"
#include "renderer.hpp"
#include <Windows.h>
#include <d3dcompiler.h>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace cirrus
{
void Ui::initialize(ID3D11Device *device)
{
    constexpr int w = 512, h = 256, cw = 28, ch = 36;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HDC dc = CreateCompatibleDC(nullptr);
    HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dc || !bitmap || !bits)
        throw std::runtime_error("Cannot create UI font atlas");
    HGDIOBJ oldBitmap = SelectObject(dc, bitmap);
    HFONT font =
        CreateFontW(-22, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET, OUT_DEFAULT_PRECIS,
                    CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, FF_MODERN, L"Consolas");
    HGDIOBJ oldFont = SelectObject(dc, font);
    std::memset(bits, 0, w * h * 4);
    SetBkColor(dc, RGB(0, 0, 0));
    SetTextColor(dc, RGB(255, 255, 255));
    for (int i = 0; i < 96; ++i)
    {
        wchar_t c = static_cast<wchar_t>(i + 32);
        TextOutW(dc, (i % 16) * cw, (i / 16) * ch, &c, 1);
    }
    auto *pixels = static_cast<uint32_t *>(bits);
    for (int i = 0; i < w * h; ++i)
        pixels[i] = ((pixels[i] & 255) << 24) | 0x00ffffff;
    pixels[w * h - 1] = 0xffffffff;
    D3D11_TEXTURE2D_DESC td{};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{bits, w * 4, 0};
    ComPtr<ID3D11Texture2D> texture;
    require(device->CreateTexture2D(&td, &data, &texture), "UI atlas");
    require(device->CreateShaderResourceView(texture.Get(), nullptr, &font_), "UI atlas SRV");
    SelectObject(dc, oldFont);
    SelectObject(dc, oldBitmap);
    DeleteObject(font);
    DeleteObject(bitmap);
    DeleteDC(dc);
    // UI専用の小さなHLSL。ピクセル座標をクリップ座標へ変換して文字アトラスを描く。
    constexpr char source[] = R"(
cbuffer Screen : register(b0)
{
    float4 viewport;
}

Texture2D atlas : register(t0);
SamplerState bilinear : register(s0);

struct V
{
    float2 p : POSITION;
    float2 uv : TEXCOORD;
    float4 c : COLOR;
};

struct P
{
    float4 p : SV_Position;
    float2 uv : TEXCOORD;
    float4 c : COLOR;
};

P VS(V v)
{
    P o;
    o.p = float4(v.p / viewport.xy * float2(2, -2) + float2(-1, 1), 0, 1);
    o.uv = v.uv;
    o.c = v.c;
    return o;
}

float4 PS(P v) : SV_Target
{
    return atlas.Sample(bilinear, v.uv) * v.c;
}
)";
    ComPtr<ID3DBlob> vb, pb, errors;
    require(D3DCompile(source, sizeof(source), "ui", nullptr, nullptr, "VS", "vs_5_0",
                       D3DCOMPILE_ENABLE_STRICTNESS, 0, &vb, &errors),
            "UI VS compile");
    require(D3DCompile(source, sizeof(source), "ui", nullptr, nullptr, "PS", "ps_5_0",
                       D3DCOMPILE_ENABLE_STRICTNESS, 0, &pb, &errors),
            "UI PS compile");
    require(device->CreateVertexShader(vb->GetBufferPointer(), vb->GetBufferSize(), nullptr, &vs_),
            "UI VS");
    require(device->CreatePixelShader(pb->GetBufferPointer(), pb->GetBufferSize(), nullptr, &ps_),
            "UI PS");
    const D3D11_INPUT_ELEMENT_DESC elements[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0}};
    require(device->CreateInputLayout(elements, 3, vb->GetBufferPointer(), vb->GetBufferSize(),
                                      &layout_),
            "UI layout");
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = sizeof(Vertex) * 65536;
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    require(device->CreateBuffer(&bd, nullptr, &buffer_), "UI vertices");
    bd.ByteWidth = 16;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    require(device->CreateBuffer(&bd, nullptr, &constants_), "UI constants");
    D3D11_BLEND_DESC blend{};
    auto &rt = blend.RenderTarget[0];
    rt.BlendEnable = TRUE;
    rt.SrcBlend = D3D11_BLEND_SRC_ALPHA;
    rt.DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    rt.BlendOp = D3D11_BLEND_OP_ADD;
    rt.SrcBlendAlpha = D3D11_BLEND_ONE;
    rt.DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    rt.BlendOpAlpha = D3D11_BLEND_OP_ADD;
    rt.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    require(device->CreateBlendState(&blend, &blend_), "UI blend");
    D3D11_SAMPLER_DESC sd{};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    require(device->CreateSamplerState(&sd, &sampler_), "UI sampler");
}

void Ui::begin(int w, int h, int mx, int my, bool down, bool pressed)
{
    width_ = w;
    height_ = h;
    mx_ = mx;
    my_ = my;
    down_ = down;
    pressed_ = pressed;
    if (!down_ || pressed_)
        activeSlider_.reset();
    setTransform(0, 0, 1);
    vertices_.clear();
}

void Ui::setTransform(float x, float y, float scale)
{
    originX_ = x;
    originY_ = y;
    scale_ = scale;
}

bool Ui::hit(float x, float y, float w, float h) const
{
    const float localX = (mx_ - originX_) / scale_;
    const float localY = (my_ - originY_) / scale_;
    return localX >= x && localX < x + w && localY >= y && localY < y + h;
}

void Ui::quad(float x, float y, float w, float h, float u0, float v0, float u1, float v1,
              uint32_t c)
{
    x = originX_ + x * scale_;
    y = originY_ + y * scale_;
    w *= scale_;
    h *= scale_;
    vertices_.insert(vertices_.end(), {{x, y, u0, v0, c},
                                       {x + w, y, u1, v0, c},
                                       {x, y + h, u0, v1, c},
                                       {x, y + h, u0, v1, c},
                                       {x + w, y, u1, v0, c},
                                       {x + w, y + h, u1, v1, c}});
}

void Ui::rect(float x, float y, float w, float h, uint32_t c)
{
    quad(x, y, w, h, 511.5f / 512, 255.5f / 256, 511.5f / 512, 255.5f / 256, c);
}

void Ui::text(float x, float y, std::string_view value, uint32_t c, float scale)
{
    for (unsigned char ch : value)
    {
        if (ch == '\n')
        {
            y += 25 * scale;
            continue;
        }
        if (ch < 32 || ch > 127)
            ch = '?';
        int i = ch - 32;
        const float u = (i % 16) * 28.0f, v = (i / 16) * 36.0f;
        quad(x, y, 28 * scale, 36 * scale, u / 512, v / 256, (u + 28) / 512, (v + 36) / 256, c);
        x += 12.2f * scale;
    }
}

bool Ui::button(float x, float y, float w, float h, std::string_view label, bool active,
                float textScale)
{
    bool over = hit(x, y, w, h);
    rect(x, y, w, h, active ? 0xe0508060 : (over ? 0xdc4b554d : 0xce272e2a));
    rect(x, y, active ? 3.0f : 1.0f, h, active ? 0xffa3edb4 : 0xff485248);
    text(x + 10, y + 3, label, active ? 0xffedfff3 : 0xffb6c6c0, textScale);
    return over && pressed_;
}

bool Ui::slider(float x, float y, float w, std::string_view label, float &value, float minimum,
                float maximum)
{
    const float previous = value;
    const std::array position{originX_ + x * scale_, originY_ + y * scale_};
    if (pressed_ && hit(x - 3, y + 19, w + 6, 23))
        activeSlider_ = position;
    // ドラッグを始めたスライダーに入力を送り続け、他の行へ移っても操作対象を変えない。
    if (activeSlider_ == position)
    {
        const float t = std::clamp((mx_ - position[0]) / (w * scale_), 0.0f, 1.0f);
        value = std::lerp(minimum, maximum, t);
    }
    text(x, y, label, 0xffa9bab3, 0.75f);
    rect(x, y + 30, w, 3, 0xff44554b);
    float t = std::clamp((value - minimum) / (maximum - minimum), 0.0f, 1.0f);
    rect(x, y + 30, w * t, 3, 0xff8cd5ab);
    rect(x + w * t - 3, y + 26, 6, 11, 0xffb0e6c5);
    return value != previous;
}

void Ui::draw(ID3D11DeviceContext *ctx)
{
    if (vertices_.empty())
        return;
    if (vertices_.size() > 65536)
        throw std::runtime_error("UI vertex capacity exceeded");
    D3D11_MAPPED_SUBRESOURCE m{};
    require(ctx->Map(buffer_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m), "Map UI");
    std::memcpy(m.pData, vertices_.data(), vertices_.size() * sizeof(Vertex));
    ctx->Unmap(buffer_.Get(), 0);
    require(ctx->Map(constants_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m), "Map UI constants");
    const std::array<float, 4> size{static_cast<float>(width_), static_cast<float>(height_), 0, 0};
    std::memcpy(m.pData, size.data(), 16);
    ctx->Unmap(constants_.Get(), 0);
    UINT stride = sizeof(Vertex), offset = 0;
    ID3D11Buffer *buffer = buffer_.Get();
    ctx->IASetVertexBuffers(0, 1, &buffer, &stride, &offset);
    ctx->IASetInputLayout(layout_.Get());
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ctx->VSSetShader(vs_.Get(), nullptr, 0);
    ctx->PSSetShader(ps_.Get(), nullptr, 0);
    ID3D11Buffer *cb = constants_.Get();
    ctx->VSSetConstantBuffers(0, 1, &cb);
    ID3D11ShaderResourceView *srv = font_.Get();
    ctx->PSSetShaderResources(0, 1, &srv);
    ID3D11SamplerState *samp = sampler_.Get();
    ctx->PSSetSamplers(0, 1, &samp);
    ctx->OMSetBlendState(blend_.Get(), nullptr, 0xffffffff);
    ctx->Draw(static_cast<UINT>(vertices_.size()), 0);
    ctx->OMSetBlendState(nullptr, nullptr, 0xffffffff);
}
}
