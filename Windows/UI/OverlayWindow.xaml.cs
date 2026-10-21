using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using VibeBoardPlus.Core;

namespace VibeBoardPlus.UI;

/// <summary>
/// Floating transcript window that never steals focus, mirroring the macOS NSPanel overlay.
/// </summary>
public partial class OverlayWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExToolWindow = 0x00000080;

    private readonly DispatcherTimer _hideTimer;
    private string _latest = "";

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr newStyle);

    public OverlayWindow()
    {
        InitializeComponent();
        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        _hideTimer.Tick += (_, _) =>
        {
            _hideTimer.Stop();
            Hide();
        };
        SourceInitialized += (_, _) => ApplyNoActivate();
    }

    private void ApplyNoActivate()
    {
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        var style = GetWindowLongPtr(handle, GwlExStyle).ToInt64();
        SetWindowLongPtr(handle, GwlExStyle, new IntPtr(style | WsExNoActivate | WsExToolWindow));
    }

    public void ShowTranscript(string text, bool final, string? status = null)
    {
        _latest = text;
        TranscriptText.Text = text;
        TranscriptText.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        StatusText.Text = status ?? (final ? (string.IsNullOrEmpty(text) ? "未识别到文字" : "识别完成") : "正在聆听");
        CopyButton.IsEnabled = !string.IsNullOrEmpty(text);

        if (!IsVisible)
        {
            PositionAtBottomCenter();
            Show();
        }

        _hideTimer.Stop();
        if (final) _hideTimer.Start();
    }

    public void SetStatus(string status)
    {
        if (IsVisible) StatusText.Text = status;
    }

    public void SetLatest(string text)
    {
        _latest = text;
        ShowTranscript(text, true);
    }

    public void Dismiss()
    {
        _hideTimer.Stop();
        Hide();
    }

    private void PositionAtBottomCenter()
    {
        UpdateLayout();
        var work = SystemParameters.WorkArea;
        Left = work.Left + (work.Width - ActualWidth) / 2;
        Top = work.Bottom - ActualHeight - 72;
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_latest)) return;
        try
        {
            System.Windows.Clipboard.SetText(_latest);
            StatusText.Text = "已复制";
        }
        catch (Exception ex)
        {
            Log.Warn($"复制失败：{ex.Message}");
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Dismiss();
}
