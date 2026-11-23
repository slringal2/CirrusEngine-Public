#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace cirrus
{
class Ui
{
  public:
    void initialize(ID3D11Device *device);
    void begin(int width, int height, int mouseX, int mouseY, bool down, bool pressed);
    void setTransform(float x, float y, float scale);
    void rect(float x, float y, float w, float h, uint32_t color);
    void text(float x, float y, std::string_view text, uint32_t color = 0xffe1e7e8,
              float scale = 1.0f);
    bool button(float x, float y, float w, float h, std::string_view label, bool active = false,
                float textScale = 0.77f);
    bool slider(float x, float y, float w, std::string_view label, float &value, float minimum,
                float maximum);
    void draw(ID3D11DeviceContext *context);

  private:
    struct Vertex
    {
        float x, y, u, v;
        uint32_t color;
    };

    void quad(float x, float y, float w, float h, float u0, float v0, float u1, float v1,
              uint32_t color);
    bool hit(float x, float y, float w, float h) const;
    std::vector<Vertex> vertices_;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> font_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vs_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> ps_;
    Microsoft::WRL::ComPtr<ID3D11InputLayout> layout_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> buffer_, constants_;
    Microsoft::WRL::ComPtr<ID3D11BlendState> blend_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
    int width_ = 0, height_ = 0, mx_ = 0, my_ = 0;
    bool down_ = false, pressed_ = false;
    float originX_ = 0, originY_ = 0, scale_ = 1;
    std::optional<std::array<float, 2>> activeSlider_;
};
}
