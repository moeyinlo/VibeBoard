using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using VibeBoardPlus.Core;

namespace VibeBoardPlus.UI;

/// <summary>Notification-area icon and menu (the Windows equivalent of the menu bar item).</summary>
public sealed class TrayController : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly Coordinator _coordinator;
    private readonly AppSettings _settings;
    private readonly ToolStripMenuItem _status;
    private SettingsWindow? _settingsWindow;

    public TrayController(Coordinator coordinator, AppSettings settings)
    {
        _coordinator = coordinator;
        _settings = settings;

        _status = new ToolStripMenuItem("等待设备") { Enabled = false };
        var menu = new ContextMenuStrip();
        menu.Items.Add(_status);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("显示最近识别结果", (_, _) => _coordinator.ShowLatest()));
        menu.Items.Add(Item("复制最近识别结果", (_, _) => _coordinator.CopyLatest()));
        menu.Items.Add(Item("取消识别", (_, _) => _coordinator.Cancel()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("设置…", (_, _) => ShowSettings()));
        menu.Items.Add(Item("打开日志", (_, _) => OpenLog()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("退出 VibeBoard Plus", (_, _) => System.Windows.Application.Current.Shutdown()));

        _icon = new NotifyIcon
        {
            Icon = CreateIcon(),
            Text = "VibeBoard Plus",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _icon.DoubleClick += (_, _) => _coordinator.ShowLatest();
    }

    private static ToolStripMenuItem Item(string text, EventHandler handler)
    {
        var item = new ToolStripMenuItem(text);
        item.Click += handler;
        return item;
    }

    public void SetStatus(string status)
    {
        void Update()
        {
            _status.Text = status;
            var text = $"VibeBoard Plus — {status}";
            // NotifyIcon.Text is limited to 63 characters.
            _icon.Text = text.Length <= 63 ? text : text[..63];
        }

        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) Update();
        else dispatcher.BeginInvoke(Update);
    }

    private void ShowSettings()
    {
        if (_settingsWindow is null || !_settingsWindow.IsLoaded)
        {
            _settingsWindow = new SettingsWindow(_settings);
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private static void OpenLog()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = Log.FilePath,
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"打开日志失败：{ex.Message}");
        }
    }

    /// <summary>Draws a simple waveform glyph so the app needs no icon asset.</summary>
    private static Icon CreateIcon()
    {
        const int size = 32;
        using var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            using var background = new SolidBrush(Color.FromArgb(28, 28, 30));
            graphics.FillEllipse(background, 0, 0, size - 1, size - 1);
            using var pen = new Pen(Color.FromArgb(80, 220, 200), 2.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            int[] heights = { 8, 15, 21, 12, 18, 9 };
            for (var index = 0; index < heights.Length; index++)
            {
                var x = 6 + index * 4;
                var half = heights[index] / 2f;
                graphics.DrawLine(pen, x, 16 - half, x, 16 + half);
            }
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(handle);
        }
    }

    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        internal static extern bool DestroyIcon(IntPtr handle);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
