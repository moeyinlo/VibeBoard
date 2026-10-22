using System.Diagnostics;
using System.Windows;
using VibeBoardPlus.Core;
using Button = System.Windows.Controls.Button;
using ComboBox = System.Windows.Controls.ComboBox;
using SelectionChangedEventArgs = System.Windows.Controls.SelectionChangedEventArgs;
using TextBlock = System.Windows.Controls.TextBlock;
using StackPanel = System.Windows.Controls.StackPanel;
using Grid = System.Windows.Controls.Grid;
using Border = System.Windows.Controls.Border;
using ColumnDefinition = System.Windows.Controls.ColumnDefinition;
using Orientation = System.Windows.Controls.Orientation;
using GridLength = System.Windows.GridLength;
using GridUnitType = System.Windows.GridUnitType;
using FontFamily = System.Windows.Media.FontFamily;
using Brushes = System.Windows.Media.Brushes;
using SolidColorBrush = System.Windows.Media.SolidColorBrush;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using TextTrimming = System.Windows.TextTrimming;
using Thickness = System.Windows.Thickness;
using CornerRadius = System.Windows.CornerRadius;
using Visibility = System.Windows.Visibility;

namespace VibeBoardPlus.UI;

/// <summary>
/// 主窗口：左侧导航 + 内容区。承担状态查看、全部设置和本地模型管理。
/// </summary>
public partial class MainWindow : Window
{
    private readonly AppSettings _settings;
    private readonly Dictionary<string, ComboBox> _buttonChoices = new();
    private readonly List<string> _providers = new() { "whisper", "stepfun", "external" };
    private readonly List<OutputMode> _modes = new() { OutputMode.Overlay, OutputMode.LiveInput, OutputMode.PasteOnCompletion };

    private FrameworkElement[] _pages = Array.Empty<FrameworkElement>();
    private bool _downloading;
    private string _latest = "";

    /// 由 App 注入：
    public Action? CancelRequested;
    public Action? CopyLatestRequested;
    public Action? ShowLatestRequested;

    public MainWindow(AppSettings settings)
    {
        _settings = settings;
        InitializeComponent();
        _pages = new FrameworkElement[]
        {
            PageOverview, PageSpeech, PageModels, PageButtons, PageOutput, PageRewrite, PageAbout,
        };

        ProviderCombo.ItemsSource = new[] { "本地 Whisper（离线）", "StepFun 官方 API（云端）", "Windows 自带语音识别" };
        AsrModelCombo.ItemsSource = new[] { "stepaudio-2.5-asr-stream", "step-asr-1.1-stream", "stepaudio-2.5-asr", "step-asr" };
        OutputModeCombo.ItemsSource = _modes.Select(mode => mode.Label()).ToList();
        OutputModeCombo.SelectionChanged += (_, _) => ApplyOutput();
        AutoCopyCheck.Click += (_, _) => ApplyOutput();

        BuildButtonRows();
        VersionText.Text = $"VibeBoard Plus {typeof(MainWindow).Assembly.GetName().Version} · 内核 v{NativeCore.Version()}";
        LogPathText.Text = $"日志：{Log.FilePath}";
        Nav.SelectedIndex = 0;
        Refresh();
        RefreshModels();
        RefreshEngine();
    }

    // MARK: 导航

    private void OnNavChanged(object sender, SelectionChangedEventArgs e)
    {
        var index = Math.Max(0, Nav.SelectedIndex);
        for (var i = 0; i < _pages.Length; i++)
            _pages[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
        if (index == 2) RefreshModels();
        if (index == 0) RefreshOverview();
    }

    // MARK: 概览

    public void SetStatus(string status) => StatusText.Text = status;

    public void SetTranscript(string text)
    {
        _latest = text;
        TranscriptBox.Text = text;
        TranscriptPlaceholder.Visibility = string.IsNullOrEmpty(text) ? Visibility.Visible : Visibility.Collapsed;
    }

    public void RefreshOverview()
    {
        SetTranscript(_latest);
        RefreshEngine();
    }

    public void SetEngine(LocalEngineStats stats)
    {
        StatsText.Text = stats.Summary;
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

    private void OnCopyLatestButton(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_latest))
        {
            SetStatus("暂无识别结果");
            return;
        }
        try
        {
            System.Windows.Clipboard.SetText(_latest);
            SetStatus("已复制识别结果");
        }
        catch (Exception ex)
        {
            Log.Warn($"复制失败：{ex.Message}");
        }
    }

    private void OnShowLatestButton(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_latest)) SetStatus("暂无识别结果");
        else
        {
            SetTranscript(_latest);
            SetStatus("最近识别结果");
        }
    }

    private void OnCancelRecognitionButton(object sender, RoutedEventArgs e) => CancelRequested?.Invoke();

    // MARK: 设置加载

    public void Refresh()
    {
        OutputModeCombo.SelectedIndex = Math.Max(0, _modes.IndexOf(_settings.OutputMode));
        AutoCopyCheck.IsChecked = _settings.AutoCopy;

        var providerIndex = _providers.IndexOf(_settings.AsrProvider);
        ProviderCombo.SelectedIndex = providerIndex >= 0 ? providerIndex : 0;
        AsrModelCombo.SelectedItem = _settings.AsrModel;
        RecognitionKeyBox.Password = "";

        RewriteCheck.IsChecked = _settings.RewriteEnabled;
        RewriteModelBox.Text = _settings.RewriteModel;
        RewriteKeyBox.Password = "";

        foreach (var (button, combo) in _buttonChoices)
        {
            combo.SelectedIndex = Array.IndexOf(ButtonActionInfo.All, _settings.ActionFor(button));
        }

        RefreshEngine();
        RefreshModels();
    }

    private void BuildButtonRows()
    {
        foreach (var button in new[] { "k1", "k2", "k3", "k4" })
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
            row.Children.Add(new TextBlock
            {
                Text = button.ToUpperInvariant(),
                Width = 46,
                VerticalAlignment = VerticalAlignment.Center,
                FontFamily = new FontFamily("Consolas"),
            });
            var combo = new ComboBox { Width = 280 };
            combo.ItemsSource = ButtonActionInfo.All.Select(action => action.Label()).ToList();
            combo.SelectionChanged += (_, _) =>
            {
                var actions = new Dictionary<string, string>();
                foreach (var (name, popup) in _buttonChoices)
                {
                    var index = Math.Max(0, popup.SelectedIndex);
                    actions[name] = ButtonActionInfo.All[index].Id();
                }
                _settings.ButtonActions = actions;
                _settings.Save();
                (System.Windows.Application.Current as App)?.ReloadConfiguration();
            };
            _buttonChoices[button] = combo;
            row.Children.Add(combo);
            ButtonRowsPanel.Children.Add(row);
        }
    }

    private void OnSaveRecognition(object sender, RoutedEventArgs e)
    {
        var providerIndex = Math.Max(0, ProviderCombo.SelectedIndex);
        _settings.AsrProvider = _providers[providerIndex];
        _settings.AsrModel = AsrModelCombo.SelectedItem as string ?? _settings.AsrModel;
        if (!string.IsNullOrWhiteSpace(RecognitionKeyBox.Password))
            _settings.RecognitionKey = RecognitionKeyBox.Password.Trim();
        _settings.Save();
        RecognitionKeyBox.Password = "";
        RecognitionStatusText.Text = "识别配置已保存，下次录音生效";
        (System.Windows.Application.Current as App)?.ReloadConfiguration();
    }

    private void ApplyOutput()
    {
        var index = Math.Max(0, OutputModeCombo.SelectedIndex);
        _settings.OutputMode = _modes[index];
        _settings.AutoCopy = AutoCopyCheck.IsChecked == true;
        _settings.Save();
        (System.Windows.Application.Current as App)?.ReloadConfiguration();
    }

    private void OnSaveRewrite(object sender, RoutedEventArgs e)
    {
        _settings.RewriteEnabled = RewriteCheck.IsChecked == true;
        var model = RewriteModelBox.Text.Trim();
        if (!string.IsNullOrEmpty(model)) _settings.RewriteModel = model;
        if (!string.IsNullOrWhiteSpace(RewriteKeyBox.Password))
            _settings.RewriteKey = RewriteKeyBox.Password.Trim();
        _settings.Save();
        RewriteKeyBox.Password = "";
        RewriteStatusText.Text = "整理配置已保存";
        (System.Windows.Application.Current as App)?.ReloadConfiguration();
    }

    private void OnTestRewrite(object sender, RoutedEventArgs e)
    {
        OnSaveRewrite(sender, e);
        RewriteStatusText.Text = "正在测试…";
        var model = _settings.RewriteModel;
        var key = string.IsNullOrEmpty(_settings.RewriteKey) ? _settings.RecognitionKey : _settings.RewriteKey;
        Task.Run(() =>
        {
            var error = SemanticRewriteClient.Test(key, model);
            Dispatcher.BeginInvoke(() =>
                RewriteStatusText.Text = error ?? "云端整理连接成功");
        });
    }

    // MARK: 模型管理

    private void RefreshModels()
    {
        if (_downloading) return;
        ModelListPanel.Children.Clear();

        var catalog = NativeCore.ModelCatalog();
        var active = _settings.WhisperModel;
        var activeEntry = catalog.FirstOrDefault(model => model.Path == active || model.Name == active);
        var activeName = activeEntry?.Name ?? (string.IsNullOrEmpty(active) ? "未选择" : active);
        var activeInstalled = activeEntry?.Installed ?? false;
        ActiveModelText.Text = activeInstalled
            ? $"当前使用：{activeName}"
            : $"当前使用：{activeName}（未下载，录音时会提示缺失）";
        ActiveModelText.Foreground = activeInstalled
            ? new SolidColorBrush(Color.FromRgb(0x6B, 0x6B, 0x72))
            : Brushes.DarkOrange;

        foreach (var model in catalog)
        {
            ModelListPanel.Children.Add(BuildModelCard(model, active, activeInstalled));
        }
    }

    private FrameworkElement BuildModelCard(ModelInfo model, string activeValue, bool activeInstalled)
    {
        var isActive = model.Builtin ? model.Name == activeValue : model.Path == activeValue;

        var title = new TextBlock
        {
            Text = model.Builtin ? model.Name : $"{model.Name}（自定义）",
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
        };
        var detail = new TextBlock
        {
            Text = model.Installed
                ? $"已安装 · {Math.Max(model.ActualSizeMb, 0)} MB · {model.Quality}"
                : $"未下载 · {model.SizeMb} MB · {model.Quality}",
            FontSize = 11,
            Foreground = new SolidColorBrush(Color.FromRgb(0x6B, 0x6B, 0x72)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(title);
        text.Children.Add(detail);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };

        if (isActive)
        {
            actions.Children.Add(new TextBlock
            {
                Text = "使用中",
                Foreground = new SolidColorBrush(Color.FromRgb(0x0A, 0x7A, 0x3D)),
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0),
            });
        }
        else if (model.Installed)
        {
            actions.Children.Add(BuildAction("使用", model.Builtin ? model.Name : model.Path, OnUseModel));
        }

        if (!model.Installed && model.Builtin)
        {
            actions.Children.Add(BuildAction("下载", model.Name, OnDownloadModel));
        }
        if (model.Installed)
        {
            actions.Children.Add(BuildAction("删除", model.Builtin ? model.Name : model.Path, OnDeleteModel));
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(text, 0);
        Grid.SetColumn(actions, 1);
        grid.Children.Add(text);
        grid.Children.Add(actions);

        return new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0xDD, 0xDD, 0xE2)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 10, 14, 10),
            Margin = new Thickness(0, 0, 0, 8),
            Child = grid,
        };
    }

    private static Button BuildAction(string label, string tag, RoutedEventHandler handler)
    {
        var button = new Button
        {
            Content = label,
            Tag = tag,
            Width = 66,
            Margin = new Thickness(6, 0, 0, 0),
            Padding = new Thickness(0, 3, 0, 3),
        };
        button.Click += handler;
        return button;
    }

    private void OnUseModel(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string value } || string.IsNullOrEmpty(value)) return;
        _settings.WhisperModel = value;
        _settings.Save();
        ModelStatusText.Text = $"已切换到 {value}";
        (System.Windows.Application.Current as App)?.ReloadConfiguration();
        RefreshModels();
    }

    private void OnDownloadModel(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string name } || string.IsNullOrEmpty(name) || _downloading) return;
        _downloading = true;
        ModelProgress.Visibility = Visibility.Visible;
        ModelProgress.Value = 0;
        ModelStatusText.Text = $"正在下载 {name}…";
        RefreshModels();

        Task.Run(() =>
        {
            var lastPercent = -10;
            var error = NativeCore.DownloadModel(name, (fraction, received) =>
            {
                var percent = (int)((fraction ?? 0) * 100);
                if (fraction is not null && percent < lastPercent + 2) return;
                lastPercent = percent;
                Dispatcher.BeginInvoke(() =>
                {
                    ModelProgress.Value = percent;
                    ModelStatusText.Text = fraction is null
                        ? $"正在下载 {name}… {received / 1024.0 / 1024.0:F0} MB"
                        : $"正在下载 {name}… {percent}%";
                });
            });

            Dispatcher.BeginInvoke(() =>
            {
                _downloading = false;
                ModelProgress.Visibility = Visibility.Collapsed;
                ModelStatusText.Text = error ?? $"已下载 {name}";
                RefreshModels();
            });
        });
    }

    private void OnDeleteModel(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string value } || string.IsNullOrEmpty(value)) return;
        var catalog = NativeCore.ModelCatalog();
        var entry = catalog.FirstOrDefault(model => model.Name == value || model.Path == value);
        var target = entry?.Path ?? value;
        var label = entry?.Name ?? System.IO.Path.GetFileName(value);

        var confirm = System.Windows.MessageBox.Show(
            $"删除模型 {label}？\n文件会从磁盘删除，需要时可以重新下载。",
            "VibeBoard Plus", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (confirm != MessageBoxResult.Yes) return;

        var error = NativeCore.RemoveModel(target);
        if (error is not null)
        {
            ModelStatusText.Text = $"删除失败：{error}";
            return;
        }
        if (_settings.WhisperModel == value || _settings.WhisperModel == label)
        {
            _settings.WhisperModel = "";
            _settings.Save();
            (System.Windows.Application.Current as App)?.ReloadConfiguration();
        }
        ModelStatusText.Text = $"已删除 {label}";
        RefreshModels();
    }

    private void OnImportModel(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "导入 Whisper 模型文件",
            Filter = "Whisper 模型 (*.bin)|*.bin|所有文件 (*.*)|*.*",
            CheckFileExists = true,
        };
        if (dialog.ShowDialog() != true) return;

        try
        {
            var directory = NativeCore.ModelDirectory();
            System.IO.Directory.CreateDirectory(directory);
            var destination = System.IO.Path.Combine(directory, System.IO.Path.GetFileName(dialog.FileName));
            if (!string.Equals(destination, dialog.FileName, StringComparison.OrdinalIgnoreCase))
            {
                System.IO.File.Copy(dialog.FileName, destination, overwrite: true);
            }
            _settings.WhisperModel = destination;
            _settings.Save();
            ModelStatusText.Text = $"已导入 {System.IO.Path.GetFileName(destination)}";
            (System.Windows.Application.Current as App)?.ReloadConfiguration();
            RefreshModels();
        }
        catch (Exception ex)
        {
            ModelStatusText.Text = $"导入失败：{ex.Message}";
        }
    }

    private void OnOpenModelDir(object sender, RoutedEventArgs e)
    {
        var path = NativeCore.ModelDirectory();
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            System.IO.Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"打开模型目录失败：{ex.Message}");
        }
    }

    private void OnRescanModels(object sender, RoutedEventArgs e)
    {
        ModelStatusText.Text = "已重新扫描";
        RefreshModels();
    }

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
