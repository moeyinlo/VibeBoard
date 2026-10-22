using System.Diagnostics;
using System.Windows;
using VibeBoardPlus.Core;
using ComboBox = System.Windows.Controls.ComboBox;
using StackPanel = System.Windows.Controls.StackPanel;
using TextBlock = System.Windows.Controls.TextBlock;
using Orientation = System.Windows.Controls.Orientation;
using VerticalAlignment = System.Windows.VerticalAlignment;
using FontFamily = System.Windows.Media.FontFamily;

namespace VibeBoardPlus.UI;

public partial class SettingsWindow : Window
{
    private readonly AppSettings _settings;
    private readonly Dictionary<string, ComboBox> _buttonChoices = new();
    private readonly List<OutputMode> _modes = new() { OutputMode.Overlay, OutputMode.LiveInput, OutputMode.PasteOnCompletion };
    private readonly List<string> _providers = new() { "whisper", "stepfun", "external" };
    private readonly List<string> _models = new() { "tiny", "base", "small", "small-q5_1", "medium", "medium-q5_0", "large-v3-turbo", "large-v3-turbo-q5_0", "large-v3-turbo-q8_0" };

    public SettingsWindow(AppSettings settings)
    {
        _settings = settings;
        InitializeComponent();

        OutputModeCombo.ItemsSource = _modes.Select(mode => mode.Label()).ToList();
        ProviderCombo.ItemsSource = new[] { "本地 Whisper（离线）", "StepFun 官方 API（云端）", "Windows 自带语音识别" };
        WhisperModelCombo.ItemsSource = _models;
        AsrModelCombo.ItemsSource = new[]
        {
            "stepaudio-2.5-asr-stream", "step-asr-1.1-stream", "stepaudio-2.5-asr", "step-asr",
        };

        var buttons = new[] { "k1", "k2", "k3", "k4" };
        foreach (var button in buttons)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
            row.Children.Add(new TextBlock
            {
                Text = button.ToUpperInvariant(),
                Width = 46,
                VerticalAlignment = VerticalAlignment.Center,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            });
            var combo = new ComboBox { Width = 260 };
            combo.ItemsSource = ButtonActionInfo.All.Select(action => action.Label()).ToList();
            _buttonChoices[button] = combo;
            row.Children.Add(combo);
            ButtonPanel.Children.Add(row);
        }

        Refresh();
        RefreshModels();
        RefreshEngine();
    }

    private void Refresh()
    {
        OutputModeCombo.SelectedIndex = Math.Max(0, _modes.IndexOf(_settings.OutputMode));
        AutoCopyCheck.IsChecked = _settings.AutoCopy;

        var providerIndex = _providers.IndexOf(_settings.AsrProvider);
        ProviderCombo.SelectedIndex = providerIndex >= 0 ? providerIndex : 0;
        WhisperModelCombo.SelectedItem = _settings.WhisperModel;
        AsrModelCombo.SelectedItem = _settings.AsrModel;
        RecognitionKeyBox.Password = "";

        RewriteCheck.IsChecked = _settings.RewriteEnabled;
        RewriteModelBox.Text = _settings.RewriteModel;
        RewriteKeyBox.Password = "";

        foreach (var (button, combo) in _buttonChoices)
        {
            var action = _settings.ActionFor(button);
            combo.SelectedIndex = Array.IndexOf(ButtonActionInfo.All, action);
        }

        VersionText.Text = $"VibeBoard Plus {typeof(SettingsWindow).Assembly.GetName().Version} · 内核 v{NativeCore.Version()}";
    }

    private void RefreshModels()
    {
        var catalog = NativeCore.ModelCatalog();
        var selected = WhisperModelCombo.SelectedItem as string ?? _settings.WhisperModel;
        var model = catalog.FirstOrDefault(item => item.Name == selected);
        if (model is null)
        {
            WhisperStatusText.Text = "未找到模型信息";
            return;
        }

        WhisperStatusText.Text = model.Installed
            ? $"已下载 · {model.Quality} · {model.Path}"
            : $"未下载（约 {model.SizeMb} MB）· {model.Quality}";
        DownloadButton.Content = model.Installed ? "重新下载" : "下载模型";
    }

    private void RefreshEngine()
    {
        var backend = NativeCore.ReadBackendInfo();
        if (backend is null)
        {
            EngineText.Text = "本地引擎：此构建未包含 Whisper";
            SystemInfoText.Text = "";
            return;
        }

        EngineText.Text = $"本地引擎：{backend.Active}（已编译 {string.Join(" / ", backend.Compiled)}）";
        SystemInfoText.Text = backend.SystemInfo;
    }

    private void OnDownloadModel(object sender, RoutedEventArgs e)
    {
        var name = WhisperModelCombo.SelectedItem as string ?? _settings.WhisperModel;
        DownloadButton.IsEnabled = false;
        DownloadProgress.Visibility = Visibility.Visible;
        DownloadProgress.Value = 0;
        WhisperStatusText.Text = $"准备下载 {name}…";

        Task.Run(() =>
        {
            var lastReport = 0;
            var error = NativeCore.DownloadModel(name, (fraction, received) =>
            {
                var percent = (int)((fraction ?? 0) * 100);
                if (percent < lastReport + 2 && fraction is not null) return;
                lastReport = percent;
                Dispatcher.BeginInvoke(() =>
                {
                    DownloadProgress.Value = percent;
                    WhisperStatusText.Text = fraction is null
                        ? $"下载中 {received / 1024.0 / 1024.0:F0} MB"
                        : $"下载中 {percent}%（{received / 1024.0 / 1024.0:F0} MB）";
                });
            });

            Dispatcher.BeginInvoke(() =>
            {
                DownloadButton.IsEnabled = true;
                DownloadProgress.Visibility = Visibility.Collapsed;
                if (error is not null) WhisperStatusText.Text = $"下载失败：{error}";
                else RefreshModels();
            });
        });
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        _settings.OutputMode = _modes[Math.Max(0, OutputModeCombo.SelectedIndex)];
        _settings.AutoCopy = AutoCopyCheck.IsChecked == true;

        var providerIndex = Math.Max(0, ProviderCombo.SelectedIndex);
        _settings.AsrProvider = _providers[providerIndex];
        _settings.WhisperModel = WhisperModelCombo.SelectedItem as string ?? _settings.WhisperModel;
        _settings.AsrModel = AsrModelCombo.SelectedItem as string ?? _settings.AsrModel;

        if (!string.IsNullOrWhiteSpace(RecognitionKeyBox.Password))
            _settings.RecognitionKey = RecognitionKeyBox.Password.Trim();
        if (!string.IsNullOrWhiteSpace(RewriteKeyBox.Password))
            _settings.RewriteKey = RewriteKeyBox.Password.Trim();

        _settings.RewriteEnabled = RewriteCheck.IsChecked == true;
        var rewriteModel = RewriteModelBox.Text.Trim();
        if (!string.IsNullOrEmpty(rewriteModel)) _settings.RewriteModel = rewriteModel;

        var actions = new Dictionary<string, string>();
        foreach (var (button, combo) in _buttonChoices)
        {
            var index = Math.Max(0, combo.SelectedIndex);
            actions[button] = ButtonActionInfo.All[index].Id();
        }
        _settings.ButtonActions = actions;
        _settings.Save();

        (System.Windows.Application.Current as App)?.ReloadConfiguration();
        SaveStatusText.Text = "已保存";
        RecognitionKeyBox.Password = "";
        RewriteKeyBox.Password = "";
        RefreshModels();
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    private void OnOpenLog(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = Log.FilePath, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"打开日志失败：{ex.Message}");
        }
    }
}
