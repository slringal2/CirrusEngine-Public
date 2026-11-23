using System.ComponentModel;
using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace CirrusTextureStudio;

internal sealed class StudioForm : Form
{
    private static readonly Color Background = Color.FromArgb(15, 23, 32);
    private static readonly Color Surface = Color.FromArgb(24, 36, 47);
    private static readonly Color Field = Color.FromArgb(33, 49, 62);
    private static readonly Color TextColor = Color.FromArgb(231, 240, 244);
    private static readonly Color Muted = Color.FromArgb(161, 182, 195);
    private static readonly Color Accent = Color.FromArgb(112, 218, 198);
    private static readonly string[][] ChannelNames =
    [
        ["RGB", "R · 基本の雲形", "G · Worley 4", "B · Worley 8", "A · Worley 16"],
        ["RGB", "R · Worley 4", "G · Worley 8", "B · Worley 16", "A · Worley 32"],
        ["RGB", "R · 雲量", "G · 湿度", "B · 雲種", "A · 積雲の芯"],
        ["RG", "R · 変位 1", "G · 変位 2"],
        ["RGB", "R · 薄雲", "G · 筋雲", "B · うろこ雲"]
    ];

    private readonly NumericUpDown seed = Number("シード", 0, int.MaxValue, 17, 0, 1);
    private readonly ComboBox size = Choice("3D 解像度", 225, "32³", "64³", "128³");
    private readonly NumericUpDown density = Number("密度の補正", -0.25m, 0.25m, 0, 2, 0.02m);
    private readonly NumericUpDown coverage = Number("雲量の補正", -0.30m, 0.30m, 0, 2, 0.02m);
    private readonly ComboBox texture = Choice("テクスチャ", 181,
        "Perlin–Worley", "詳細 Worley", "天候マップ", "雲の変位マップ", "雲層マスク");
    private readonly ComboBox channel = Choice("チャンネル", 160);
    private readonly ComboBox axis = Choice("断面軸", 62, "X", "Y", "Z");
    private readonly TrackBar slice = new()
    {
        Name = "Slice", AccessibleName = "断面の位置", Dock = DockStyle.Fill,
        TickStyle = TickStyle.None, AutoSize = false, Maximum = 63, Value = 32, BackColor = Surface
    };
    private readonly CheckBox tile = new()
    {
        Text = "3×3 タイル", AutoSize = true, ForeColor = TextColor, Margin = new Padding(12, 7, 0, 0)
    };
    private readonly Label sliceValue = new()
    {
        Dock = DockStyle.Fill, ForeColor = TextColor, TextAlign = ContentAlignment.MiddleRight
    };
    private readonly Label metadata = new()
    {
        Dock = DockStyle.Fill, ForeColor = Muted, TextAlign = ContentAlignment.MiddleLeft
    };
    private readonly Label status = new()
    {
        Dock = DockStyle.Fill, ForeColor = Muted, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft
    };
    private readonly TexturePreview preview = new() { Name = "TexturePreview", Dock = DockStyle.Fill, Margin = Padding.Empty };
    private readonly Button generate = ActionButton("Generate", "生成", primary: true);
    private readonly Button savePng = ActionButton("SavePng", "断面 PNG を保存");
    private readonly Button savePack = ActionButton("SavePack", "DDS パックを書き出す");
    private readonly Button runEngine = ActionButton("RunEngine", "エンジンでプレビュー");
    private readonly CancellationTokenSource lifetime = new();
    private readonly string enginePath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "CirrusEngine.exe"));
    private TexturePack? current;
    private string? exportedFolder;
    private bool busy, updatingView;

    public StudioForm()
    {
        Text = "Cirrus Texture Studio";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(1120, 720);
        MinimumSize = new Size(900, 640);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Background;
        ForeColor = TextColor;
        Font = new Font("Yu Gothic UI", 10);
        Padding = new Padding(22, 15, 22, 9);

        var layout = Column(Color.Transparent);
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        var title = new Label
        {
            Text = Text, Font = new Font("Segoe UI", 25, FontStyle.Bold), Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };
        var body = new TableLayoutPanel { ColumnCount = 2, RowCount = 1, Dock = DockStyle.Fill, Margin = Padding.Empty };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 263));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        body.Controls.Add(BuildEditor(), 0, 0);
        body.Controls.Add(BuildInspector(), 1, 0);
        layout.Controls.Add(title, 0, 0);
        layout.Controls.Add(body, 0, 1);
        layout.Controls.Add(status, 0, 2);
        Controls.Add(layout);

        size.SelectedIndex = 1;
        texture.SelectedIndex = 0;
        axis.SelectedIndex = 2;
        RefreshActions();
        Shown += async (_, _) => await GenerateAsync();
        FormClosed += (_, _) =>
        {
            lifetime.Cancel();
            lifetime.Dispose();
        };
        generate.Click += async (_, _) => await GenerateAsync();
        savePack.Click += async (_, _) => await ExportAsync();
        savePng.Click += (_, _) => SaveSlice();
        runEngine.Click += (_, _) => LaunchEngine();
        texture.SelectedIndexChanged += (_, _) => ConfigureView();
        channel.SelectedIndexChanged += (_, _) => UpdatePreview();
        axis.SelectedIndexChanged += (_, _) => UpdatePreview();
        slice.ValueChanged += (_, _) => UpdatePreview();
        tile.CheckedChanged += (_, _) => preview.ShowTiles(tile.Checked);
    }

    private Control BuildEditor()
    {
        var panel = Column(Surface);
        panel.Padding = new Padding(16, 13, 16, 10);
        panel.Margin = new Padding(0, 0, 15, 0);
        panel.Controls.Add(new Label
        {
            Text = "生成設定", Font = new Font(Font, FontStyle.Bold), Dock = DockStyle.Fill,
            Height = 28, Margin = new Padding(0, 0, 0, 8)
        });
        foreach (Control input in new Control[] { seed, size, density, coverage })
        {
            panel.Controls.Add(new Label
            {
                Text = input.AccessibleName, ForeColor = Muted, AutoSize = true,
                Margin = new Padding(0, 5, 0, 3)
            });
            input.Dock = DockStyle.Top;
            input.Margin = new Padding(0, 0, 0, 10);
            panel.Controls.Add(input);
        }
        foreach (Button button in new[] { generate, savePng, savePack, runEngine })
            panel.Controls.Add(button);
        return panel;
    }

    private Control BuildInspector()
    {
        var layout = Column(Surface);
        layout.Padding = new Padding(12, 9, 12, 8);
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 41));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 25));
        var bar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = Padding.Empty };
        foreach (Control control in new Control[] { texture, channel, axis, tile })
            bar.Controls.Add(control);
        var scrub = new TableLayoutPanel { ColumnCount = 3, RowCount = 1, Dock = DockStyle.Fill, Margin = Padding.Empty };
        scrub.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 46));
        scrub.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        scrub.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 84));
        scrub.Controls.Add(new Label
        {
            Text = "断面", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = Muted
        }, 0, 0);
        scrub.Controls.Add(slice, 1, 0);
        scrub.Controls.Add(sliceValue, 2, 0);
        layout.Controls.Add(bar, 0, 0);
        layout.Controls.Add(preview, 0, 1);
        layout.Controls.Add(scrub, 0, 2);
        layout.Controls.Add(metadata, 0, 3);
        return layout;
    }

    private async Task GenerateAsync()
    {
        var settings = new GenerationSettings((int)seed.Value, 32 << size.SelectedIndex,
            (float)density.Value, (float)coverage.Value);
        await RunWorkAsync("テクスチャを生成しています…", async cancellation =>
        {
            var pack = await Task.Run(() => TextureGenerator.Generate(settings, cancellation), cancellation);
            if (IsDisposed)
                return;
            current = pack;
            exportedFolder = null;
            ConfigureView();
            status.Text = $"生成完了  ·  シード {settings.Seed}";
        });
    }

    private async Task ExportAsync()
    {
        if (current is not { } pack)
            return;
        using var dialog = new FolderBrowserDialog
        {
            Description = "DDS パックの保存先を選択してください",
            UseDescriptionForTitle = true
        };
        if (dialog.ShowDialog(this) != DialogResult.OK)
            return;
        string parent = dialog.SelectedPath;
        await RunWorkAsync("DDS パックを書き出しています…", async cancellation =>
        {
            string folder = await Task.Run(() => TextureFiles.ExportPack(pack, parent, cancellation), cancellation);
            if (IsDisposed)
                return;
            exportedFolder = folder;
            status.Text = $"保存しました  ·  {folder}";
        });
    }

    private async Task RunWorkAsync(string message, Func<CancellationToken, Task> action)
    {
        if (busy)
            return;
        busy = true;
        status.Text = message;
        RefreshActions();
        try { await action(lifetime.Token); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex)
        {
            if (!IsDisposed)
                status.Text = ex.Message;
        }
        finally
        {
            busy = false;
            if (!IsDisposed)
                RefreshActions();
        }
    }

    private void SaveSlice()
    {
        if (current is not { } pack || preview.Slice is not { } bitmap)
            return;
        TextureData selected = pack.Textures[texture.SelectedIndex];
        string map = Path.GetFileNameWithoutExtension(selected.FileName);
        string cut = selected.Depth > 1 ? $"-{axis.Text.ToLowerInvariant()}{slice.Value:D3}" : "";
        using var dialog = new SaveFileDialog
        {
            Filter = "PNG (*.png)|*.png", FileName = $"{map}{cut}.png", DefaultExt = "png"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK)
            return;
        try
        {
            bitmap.Save(dialog.FileName, ImageFormat.Png);
            status.Text = $"保存しました  ·  {dialog.FileName}";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ExternalException)
        {
            status.Text = ex.Message;
        }
    }

    private void LaunchEngine()
    {
        if (exportedFolder is not { } folder)
            return;
        try
        {
            var start = new ProcessStartInfo(enginePath)
            {
                WorkingDirectory = Path.GetDirectoryName(enginePath)!,
                UseShellExecute = false
            };
            foreach (string argument in new[] { "--cloud-textures", folder, "--camera", "fly", "--look", "25", "13" })
                start.ArgumentList.Add(argument);
            using var process = Process.Start(start);
            status.Text = $"CirrusEngine でパックを開きました  ·  {Path.GetFileName(folder)}";
        }
        catch (Win32Exception ex) { status.Text = ex.Message; }
    }

    private void RefreshActions()
    {
        foreach (Control control in new Control[] { seed, size, density, coverage, generate })
            control.Enabled = !busy;
        savePng.Enabled = savePack.Enabled = !busy && current is not null;
        runEngine.Enabled = !busy && exportedFolder is not null && File.Exists(enginePath);
    }

    private void ConfigureView()
    {
        if (current is not { } pack)
            return;
        TextureData selected = pack.Textures[texture.SelectedIndex];
        updatingView = true;
        axis.Enabled = slice.Enabled = selected.Depth > 1;
        slice.Maximum = selected.Depth - 1;
        slice.Value = selected.Depth / 2;
        channel.Items.Clear();
        channel.Items.AddRange(ChannelNames[texture.SelectedIndex]);
        channel.SelectedIndex = texture.SelectedIndex is 0 or 2 ? 1 : 0;
        updatingView = false;
        UpdatePreview();
    }

    private void UpdatePreview()
    {
        if (updatingView || current is not { } pack)
            return;
        TextureData selected = pack.Textures[texture.SelectedIndex];
        bool volume = selected.Depth > 1;
        preview.SetSlice(TextureFiles.MakeSlice(selected, volume ? axis.SelectedIndex : 2, slice.Value,
            channel.SelectedIndex - 1));
        sliceValue.Text = volume ? $"{slice.Value + 1} / {selected.Depth}" : "–";
        string dimensions = $"{selected.Size} × {selected.Size}" + (volume ? $" × {selected.Depth}" : "");
        metadata.Text = $"{dimensions}  ·  {(selected.Channels == 4 ? "RGBA16F" : "RG16F")}";
    }

    private static TableLayoutPanel Column(Color color)
    {
        var panel = new TableLayoutPanel
        {
            ColumnCount = 1, Dock = DockStyle.Fill, BackColor = color, Margin = Padding.Empty
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        return panel;
    }

    private static ComboBox Choice(string name, int width, params string[] items)
    {
        var box = new ComboBox
        {
            AccessibleName = name, DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat,
            DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = 23,
            Width = width, BackColor = Field, ForeColor = TextColor, Margin = new Padding(0, 3, 8, 0)
        };
        box.Items.AddRange(items);
        box.DrawItem += (_, e) =>
        {
            if (e.Index < 0)
                return;
            bool highlighted = (e.State & DrawItemState.Selected) != 0;
            using var background = new SolidBrush(highlighted ? Color.FromArgb(47, 75, 88) : Field);
            e.Graphics.FillRectangle(background, e.Bounds);
            var label = new Rectangle(e.Bounds.X + 5, e.Bounds.Y, e.Bounds.Width - 5, e.Bounds.Height);
            string text = box.Items[e.Index]?.ToString() ?? string.Empty;
            TextRenderer.DrawText(e.Graphics, text, box.Font, label,
                box.Enabled ? TextColor : Muted, TextFormatFlags.Left | TextFormatFlags.VerticalCenter
                | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            e.DrawFocusRectangle();
        };
        return box;
    }

    private static NumericUpDown Number(string name, decimal min, decimal max, decimal value, int decimals,
        decimal increment) => new()
    {
        AccessibleName = name, Minimum = min, Maximum = max, Value = value, DecimalPlaces = decimals,
        Increment = increment, BackColor = Field, ForeColor = TextColor, BorderStyle = BorderStyle.FixedSingle,
        TextAlign = HorizontalAlignment.Right
    };

    private static Button ActionButton(string name, string label, bool primary = false)
    {
        var button = new Button
        {
            Name = name, Text = label, FlatStyle = FlatStyle.Flat, Height = 36, Dock = DockStyle.Top,
            Margin = new Padding(0, primary ? 6 : 0, 0, 7),
            BackColor = primary ? Accent : Field, ForeColor = primary ? Background : TextColor,
            UseVisualStyleBackColor = false
        };
        button.FlatAppearance.BorderSize = 0;
        return button;
    }

    private sealed class TexturePreview : Control
    {
        private bool tiled;
        public Bitmap? Slice { get; private set; }

        public TexturePreview()
        {
            BackColor = Color.FromArgb(10, 17, 24);
            DoubleBuffered = true;
            ResizeRedraw = true;
        }

        public void SetSlice(Bitmap bitmap)
        {
            Slice?.Dispose();
            Slice = bitmap;
            Invalidate();
        }

        public void ShowTiles(bool enabled)
        {
            tiled = enabled;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (Slice is not { } bitmap)
                return;
            int count = tiled ? 3 : 1;
            int side = Math.Max(1, (Math.Min(ClientSize.Width, ClientSize.Height) - 22) / count);
            int left = (ClientSize.Width - count * side) / 2;
            int top = (ClientSize.Height - count * side) / 2;
            e.Graphics.InterpolationMode = InterpolationMode.Bilinear;
            e.Graphics.PixelOffsetMode = PixelOffsetMode.Half;
            for (int y = 0; y < count; y++)
                for (int x = 0; x < count; x++)
                    e.Graphics.DrawImage(bitmap, new Rectangle(left + x * side, top + y * side, side, side));
            int center = count / 2 * side;
            using var border = new Pen(tiled ? Color.FromArgb(180, Accent) : Color.FromArgb(100, Muted));
            e.Graphics.DrawRectangle(border, left + center, top + center, side - 1, side - 1);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
                Slice?.Dispose();
            base.Dispose(disposing);
        }
    }
}
