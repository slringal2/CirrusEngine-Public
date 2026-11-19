using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace CirrusTextureStudio;

internal static class TextureFiles
{
    public static string ExportPack(TexturePack pack, string parent, CancellationToken cancellation)
    {
        parent = Path.GetFullPath(parent);
        string suffix = Guid.NewGuid().ToString("N");
        string name = $"CirrusTextures-{pack.Settings.Seed}-{suffix[..8]}";
        string staging = Path.Combine(parent, $".{name}-{suffix}.tmp");
        string destination = Path.Combine(parent, name);
        Directory.CreateDirectory(staging);
        try
        {
            foreach (TextureData texture in pack.Textures)
            {
                cancellation.ThrowIfCancellationRequested();
                WriteDds(texture, Path.Combine(staging, texture.FileName));
            }
            string settings = JsonSerializer.Serialize(pack.Settings, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(Path.Combine(staging, "settings.json"), settings);
            cancellation.ThrowIfCancellationRequested();
            Directory.Move(staging, destination);
            return destination;
        }
        catch
        {
            // 書き出し途中のファイル名は、この呼び出しが作った専用フォルダに限定する。
            foreach (TextureData texture in pack.Textures)
                TryDelete(Path.Combine(staging, texture.FileName));
            TryDelete(Path.Combine(staging, "settings.json"));
            try { Directory.Delete(staging); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void WriteDds(TextureData texture, string path)
    {
        bool volume = texture.Depth > 1;
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        using var writer = new BinaryWriter(stream);

        // DDS_HEADERにDX10拡張を続ける。ミップ0だけを保存し、描画側がミップを作る。
        writer.Write(0x20534444u); // DDS␣
        writer.Write(124u);
        writer.Write(0x100fu | (volume ? 0x800000u : 0));
        writer.Write((uint)texture.Size);
        writer.Write((uint)texture.Size);
        writer.Write((uint)(texture.Size * texture.Channels * sizeof(ushort)));
        writer.Write(volume ? (uint)texture.Depth : 0u);
        writer.Write(1u);
        writer.Write(new byte[44]);

        writer.Write(32u);
        writer.Write(4u); // DDPF_FOURCC
        writer.Write(0x30315844u); // DX10
        writer.Write(new byte[20]);
        writer.Write(volume ? 0x1008u : 0x1000u); // DDSCAPS_TEXTURE | DDSCAPS_COMPLEX
        writer.Write(volume ? 0x200000u : 0u); // DDSCAPS2_VOLUME
        writer.Write(new byte[12]);

        writer.Write(texture.Channels == 4 ? 10u : 34u); // DXGI R16G16B16A16_FLOAT / R16G16_FLOAT
        writer.Write(volume ? 4u : 3u); // D3D11_RESOURCE_DIMENSION_TEXTURE3D / TEXTURE2D
        writer.Write(0u);
        writer.Write(1u);
        writer.Write(0u);
        writer.Write(MemoryMarshal.AsBytes(texture.Texels.AsSpan()));
    }

    public static Bitmap MakeSlice(TextureData texture, int axis, int slice, int channel)
    {
        int size = texture.Size;
        var bgra = new byte[size * size * 4];
        for (int v = 0; v < size; v++)
            for (int u = 0; u < size; u++)
            {
                int x = axis == 0 ? slice : u;
                int y = axis == 1 ? slice : v;
                int z = axis == 2 ? slice : axis == 0 ? u : v;
                int source = ((z * size + y) * size + x) * texture.Channels;
                int pixel = (v * size + u) * 4;
                if (channel >= 0)
                {
                    byte value = ToByte(texture.Texels[source + channel]);
                    bgra[pixel] = bgra[pixel + 1] = bgra[pixel + 2] = value;
                }
                else
                {
                    bgra[pixel] = texture.Channels > 2 ? ToByte(texture.Texels[source + 2]) : (byte)0;
                    bgra[pixel + 1] = ToByte(texture.Texels[source + 1]);
                    bgra[pixel + 2] = ToByte(texture.Texels[source]);
                }
                bgra[pixel + 3] = 255;
            }

        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        BitmapData data = bitmap.LockBits(new Rectangle(0, 0, size, size), ImageLockMode.WriteOnly, bitmap.PixelFormat);
        try { Marshal.Copy(bgra, 0, data.Scan0, bgra.Length); }
        finally { bitmap.UnlockBits(data); }
        return bitmap;
    }

    private static byte ToByte(Half normalized) => (byte)MathF.Round((float)normalized * 255);
}
