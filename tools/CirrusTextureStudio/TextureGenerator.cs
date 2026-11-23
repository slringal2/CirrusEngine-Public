using System.Numerics;

namespace CirrusTextureStudio;

internal readonly record struct GenerationSettings(int Seed, int Size, float DensityBias, float CoverageBias);

internal sealed record TextureData(string FileName, int Size, int Depth, int Channels, Half[] Texels);

internal sealed record TexturePack(GenerationSettings Settings, TextureData[] Textures);

internal static class TextureGenerator
{
    private const int WeatherSize = 512;

    public static TexturePack Generate(GenerationSettings settings, CancellationToken cancellation)
    {
        int size = settings.Size;
        if (size is not (32 or 64 or 128))
            throw new ArgumentOutOfRangeException(nameof(settings), "3D size must be 32, 64 or 128.");

        var baseNoise = new TextureData("base-noise.dds", size, size, 4, new Half[size * size * size * 4]);
        var detailNoise = new TextureData("detail-noise.dds", size, size, 4, new Half[size * size * size * 4]);
        var weather = new TextureData("weather-map.dds", WeatherSize, 1, 4, new Half[WeatherSize * WeatherSize * 4]);
        var displacement = new TextureData("cloud-displacement.dds", WeatherSize, 1, 2,
            new Half[WeatherSize * WeatherSize * 2]);

        var layers = new TextureData("cloud-layers.dds", WeatherSize, 1, 4,
            new Half[WeatherSize * WeatherSize * 4]);

        uint seed = unchecked((uint)settings.Seed);
        var parallel = new ParallelOptions { CancellationToken = cancellation };
        GenerateVolumes(settings, seed, baseNoise, detailNoise, parallel);
        GenerateWeather(settings, seed, weather, displacement, parallel);
        GenerateLayerMasks(seed, layers, parallel);
        return new TexturePack(settings, [baseNoise, detailNoise, weather, displacement, layers]);
    }

    private static void GenerateVolumes(GenerationSettings settings, uint seed, TextureData baseNoise,
        TextureData detailNoise, ParallelOptions parallel)
    {
        int size = baseNoise.Size;
        var cells4 = new PeriodicGrid(4, seed, gradients: true);
        var cells8 = new PeriodicGrid(8, seed, gradients: true);
        var cells16 = new PeriodicGrid(16, seed, gradients: true);
        var cells32 = new PeriodicGrid(32, seed, gradients: true);

        // 同じセルをPerlinとWorleyで使い、詳細ボリュームともWorleyの3帯域を共有する。
        Parallel.For(0, size, parallel, z =>
        {
            float inverseSize = 1f / size;
            for (int y = 0; y < size; y++)
            {
                parallel.CancellationToken.ThrowIfCancellationRequested();
                for (int x = 0; x < size; x++)
                {
                    Vector3 uv = (new Vector3(x, y, z) + new Vector3(0.5f)) * inverseSize;
                    Vector3 p4 = uv * 4, p8 = uv * 8, p16 = uv * 16, p32 = uv * 32;
                    float w4 = cells4.Worley(p4), w8 = cells8.Worley(p8);
                    float w16 = cells16.Worley(p16), w32 = cells32.Worley(p32);
                    float perlin = cells4.Gradient(p4) * 0.533333f + cells8.Gradient(p8) * 0.266667f
                                + cells16.Gradient(p16) * 0.133333f + cells32.Gradient(p32) * 0.066667f;
                    perlin = Saturate((perlin - 0.28f) / 0.44f);
                    float worley = w4 * 0.625f + w8 * 0.25f + w16 * 0.125f;
                    float shape = Lerp(worley, 1, perlin) + settings.DensityBias;
                    int index = ((z * size + y) * size + x) * 4;
                    WriteRgba(baseNoise.Texels, index, Saturate((shape - 0.42f) / 0.52f), w4, w8, w16);
                    WriteRgba(detailNoise.Texels, index, w4, w8, w16, w32);
                }
            }
        });
    }

    private static void GenerateWeather(GenerationSettings settings, uint seed, TextureData weather,
        TextureData displacement, ParallelOptions parallel)
    {
        var regional = new[] { new PeriodicGrid(8, seed), new PeriodicGrid(16, seed),
                               new PeriodicGrid(32, seed), new PeriodicGrid(64, seed) };
        var coarse = new PeriodicGrid(9, seed ^ 0x353a93b7u);
        var fine = new PeriodicGrid(23, seed ^ 0x6cecdadeu);
        var clouds = new PeriodicGrid(15, seed ^ 0xa08c1bddu);

        Parallel.For(0, WeatherSize, parallel, y =>
        {
            for (int x = 0; x < WeatherSize; x++)
            {
                Vector2 uv = (new Vector2(x, y) + new Vector2(0.5f)) / WeatherSize;
                float coverage = 0, weight = 0.571f;
                for (int octave = 0; octave < regional.Length; octave++)
                {
                    int scale = 1 << octave;
                    coverage += regional[octave].Value(new Vector3(uv * (8 * scale), 1.7f * scale)) * weight;
                    weight *= 0.5f;
                }

                float moisture = regional[0].Value(new Vector3(uv * 8, 5.6f));
                float type = regional[1].Value(new Vector3(uv * 16, 3.2f));
                Vector2 largeWarp = new(coarse.Value(new Vector3(uv * 9, 2.17f)),
                                        coarse.Value(new Vector3(uv * 9, 5.31f)));
                Vector2 smallWarp = new(fine.Value(new Vector3(uv * 23, 8.46f)),
                                        fine.Value(new Vector3(uv * 23, 1.57f)));
                Vector2 warp = Vector2.Lerp(largeWarp, smallWarp, 0.32f);
                Vector2 cloudUv = uv + new Vector2(0.038f, 0.067f) + (largeWarp - new Vector2(0.5f)) * 0.018f;
                int pixel = y * WeatherSize + x;
                WriteRgba(weather.Texels, pixel * 4, Saturate(coverage + settings.CoverageBias),
                    moisture, type, clouds.CumulusCore(cloudUv * 15));
                displacement.Texels[pixel * 2] = (Half)warp.X;
                displacement.Texels[pixel * 2 + 1] = (Half)warp.Y;
            }
        });
    }

    private static void GenerateLayerMasks(uint seed, TextureData layers, ParallelOptions parallel)
    {
        // 3種類の周期マスクをRGBA16F 1枚へ保存する。エンジンは旧DDS互換としてRGBを各層に分けて読む。
        var broad = new PeriodicGrid(8, seed ^ 0xc2b2ae35u);
        var medium = new PeriodicGrid(19, seed ^ 0xb5297a4du);
        var fine = new PeriodicGrid(47, seed ^ 0xa5cd8b3du);
        var bend = new PeriodicGrid(7, seed ^ 0x63d83595u);
        var fibres = new PeriodicGrid(6, seed ^ 0x5f356495u);
        var fineFibres = new PeriodicGrid(12, seed ^ 0x6d2b79f5u);
        var cloudlets = new PeriodicGrid(30, seed ^ 0x2c9277b5u);
        Parallel.For(0, layers.Size, parallel, y =>
        {
            for (int x = 0; x < layers.Size; ++x)
            {
                Vector2 uv = (new Vector2(x, y) + new Vector2(0.5f)) / layers.Size;
                float low = broad.Value(new Vector3(uv * 8, 2.73f));
                float mid = medium.Value(new Vector3(uv * 19, 9.38f));
                float high = fine.Value(new Vector3(uv * 47, 16.65f));
                float veil = SmoothStep(0.30f, 0.75f, 0.64f * low + 0.26f * mid + 0.10f * high);

                float curve = 0.054f * (bend.Value(new Vector3(uv * 7, 2.18f)) - 0.5f);
                var flowing = new Vector2(uv.X, uv.Y + curve);
                float strands = 0.76f * fibres.Value(new Vector3(flowing * new Vector2(6, 54), 3.13f))
                    + 0.24f * fineFibres.Value(new Vector3(flowing * new Vector2(12, 108), 8.41f));
                float wisps = SmoothStep(0.49f, 0.78f, strands) * SmoothStep(0.29f, 0.67f, mid);

                Vector2 warped = uv + 0.027f * (new Vector2(low, mid) - new Vector2(0.5f));
                float core = cloudlets.CumulusCore(warped * 30);
                float patches = SmoothStep(0.36f, 0.66f, 0.66f * mid + 0.34f * low);
                float scales = SmoothStep(0.16f, 0.76f, core) * patches;
                WriteRgba(layers.Texels, (y * layers.Size + x) * 4, veil, wisps, scales, 1);
            }
        });
    }

    private static float SmoothStep(float lower, float upper, float value)
    {
        float t = Saturate((value - lower) / (upper - lower));
        return t * t * (3 - 2 * t);
    }

    private static void WriteRgba(Half[] texels, int index, float r, float g, float b, float a)
    {
        texels[index] = (Half)r;
        texels[index + 1] = (Half)g;
        texels[index + 2] = (Half)b;
        texels[index + 3] = (Half)a;
    }

    private static float Saturate(float value) => Math.Clamp(value, 0, 1);
    private static float Lerp(float a, float b, float t) => a + (b - a) * t;
    private static float Fade(float t) => t * t * t * (t * (t * 6 - 15) + 10);

    private sealed class PeriodicGrid
    {
        private readonly int period;
        private readonly Vector3[] points;
        private readonly Vector3[] gradients;

        public PeriodicGrid(int period, uint seed, bool gradients = false)
        {
            this.period = period;
            points = new Vector3[period * period * period];
            this.gradients = gradients ? new Vector3[points.Length] : [];
            for (int i = 0; i < points.Length; i++)
            {
                uint cell = unchecked(seed + (uint)i * 0x9e3779b9u);
                var point = new Vector3(Unit(cell), Unit(cell ^ 0x66b25457u), Unit(cell ^ 0xc2b2ae35u));
                points[i] = point;
                if (gradients)
                    this.gradients[i] = Vector3.Normalize(point * 2 - Vector3.One + new Vector3(0.00001f));
            }
        }

        public float Worley(Vector3 p)
        {
            Vector3 f = Local(p, out int x, out int y, out int z);
            float nearest = 4;
            for (int dz = -1; dz <= 1; dz++)
                for (int dy = -1; dy <= 1; dy++)
                {
                    int row = Row(y + dy, z + dz);
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        Vector3 delta = new Vector3(dx, dy, dz) + points[row + Wrap(x + dx)] - f;
                        nearest = MathF.Min(nearest, delta.LengthSquared());
                    }
                }
            return Saturate(1 - MathF.Sqrt(nearest));
        }

        public float Gradient(Vector3 p)
        {
            Vector3 f = Local(p, out int x, out int y, out int z);
            Vector3 t = new(Fade(f.X), Fade(f.Y), Fade(f.Z));
            float value = 0;
            for (int dz = 0; dz <= 1; dz++)
                for (int dy = 0; dy <= 1; dy++)
                {
                    int row = Row(y + dy, z + dz);
                    float weight = (dy == 0 ? 1 - t.Y : t.Y) * (dz == 0 ? 1 - t.Z : t.Z);
                    float a = Vector3.Dot(gradients[row + Wrap(x)], f - new Vector3(0, dy, dz));
                    float b = Vector3.Dot(gradients[row + Wrap(x + 1)], f - new Vector3(1, dy, dz));
                    value += Lerp(a, b, t.X) * weight;
                }
            return Saturate(value * 1.35f + 0.5f);
        }

        public float Value(Vector3 p)
        {
            Vector3 f = Local(p, out int x, out int y, out int z);
            int left = Wrap(x), right = Wrap(x + 1);
            float tx = Fade(f.X), ty = Fade(f.Y);
            int a = Row(y, z), b = Row(y + 1, z), c = Row(y, z + 1), d = Row(y + 1, z + 1);
            float near = Lerp(Lerp(points[a + left].X, points[a + right].X, tx),
                              Lerp(points[b + left].X, points[b + right].X, tx), ty);
            float far = Lerp(Lerp(points[c + left].X, points[c + right].X, tx),
                             Lerp(points[d + left].X, points[d + right].X, tx), ty);
            return Lerp(near, far, Fade(f.Z));
        }

        public float CumulusCore(Vector2 p)
        {
            int x = (int)MathF.Floor(p.X), y = (int)MathF.Floor(p.Y);
            Vector2 local = p - new Vector2(x, y);
            float core = 0;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++)
                {
                    Vector3 cell = points[Row(y + dy, 0) + Wrap(x + dx)];
                    Vector2 center = new Vector2(dx, dy) + new Vector2(cell.X, cell.Y) * 0.82f
                                   + new Vector2(0.09f);
                    Vector2 delta = (local - center) / Lerp(0.29f, 0.65f, cell.Z);
                    core = MathF.Max(core, 1 - delta.LengthSquared());
                }
            return core;
        }

        private int Row(int y, int z) => (Wrap(z) * period + Wrap(y)) * period;

        private int Wrap(int value)
        {
            int index = value % period;
            return index < 0 ? index + period : index;
        }

        private static Vector3 Local(Vector3 p, out int x, out int y, out int z)
        {
            x = (int)MathF.Floor(p.X);
            y = (int)MathF.Floor(p.Y);
            z = (int)MathF.Floor(p.Z);
            return p - new Vector3(x, y, z);
        }

        private static float Unit(uint value)
        {
            unchecked
            {
                value = (value ^ (value >> 16)) * 0x7feb352du;
                value = (value ^ (value >> 15)) * 0x846ca68bu;
                return ((value ^ (value >> 16)) >> 8) * (1f / 16777216);
            }
        }
    }
}
