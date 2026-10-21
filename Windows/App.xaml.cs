using System.Threading;
using System.Windows;
using VibeBoardPlus.Core;
using VibeBoardPlus.UI;

namespace VibeBoardPlus;

public partial class App : System.Windows.Application
{
    private Mutex? _singleInstance;
    private NativeCore? _core;
    private Coordinator? _coordinator;
    private TrayController? _tray;

    public static AppSettings Settings { get; private set; } = new();

    /// <summary>Pushes the current settings into the running core.</summary>
    public void ReloadConfiguration()
    {
        try
        {
            _core?.UpdateConfiguration();
        }
        catch (Exception ex)
        {
            Log.Error($"重新加载配置失败：{ex.Message}");
        }
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstance = new Mutex(true, @"Local\VibeBoardPlus.Windows", out var createdNew);
        if (!createdNew)
        {
            System.Windows.MessageBox.Show("VibeBoard Plus 已在运行（请查看任务栏通知区域）。", "VibeBoard Plus",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            Log.Error($"未处理异常：{args.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Error($"任务异常：{args.Exception}");
            args.SetObserved();
        };

        Settings = AppSettings.Load();
        Log.Info($"started — v{typeof(App).Assembly.GetName().Version}, log={Log.FilePath}");
        Log.Info($"settings: provider={Settings.AsrProvider} whisper={Settings.WhisperModel} output={Settings.OutputMode}");

        var overlay = new OverlayWindow();
        _core = new NativeCore(Settings);
        _coordinator = new Coordinator(Settings, _core, overlay);
        _tray = new TrayController(_coordinator, Settings);
        _coordinator.StatusChanged += status => _tray?.SetStatus(status);

        if (Settings.AsrProvider == "whisper" && !NativeCore.ModelInstalled(Settings.WhisperModel))
        {
            _tray.SetStatus("请先在设置中下载本地模型");
        }
        else
        {
            _tray.SetStatus("等待设备");
        }

        try
        {
            _core.Start();
        }
        catch (Exception ex)
        {
            Log.Error($"内核启动失败：{ex.Message}");
            System.Windows.MessageBox.Show(
                $"内核启动失败：{ex.Message}\n\n请确认 vibeboard_core.dll 与程序在同一目录。",
                "VibeBoard Plus", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _coordinator?.Dispose();
        _core?.Dispose();
        _tray?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
