using System.Windows;

namespace VibeBoardPlus.Core;

/// <summary>
/// Decides where the transcript goes: live typing into the focused control, a paste on
/// completion, or the floating window. Mirrors the macOS RecognitionOutput policy.
/// </summary>
public sealed class Coordinator : IDisposable
{
    private readonly AppSettings _settings;
    private readonly NativeCore _core;
    private readonly UI.OverlayWindow _overlay;
    private readonly WindowsSpeechRecognizer _speech = new();

    private LiveTextSession? _live;
    private IntPtr _target;
    private bool _active;

    public event Action<string>? StatusChanged;
    public string Latest { get; private set; } = "";

    public Coordinator(AppSettings settings, NativeCore core, UI.OverlayWindow overlay)
    {
        _settings = settings;
        _core = core;
        _overlay = overlay;

        _core.StatusChanged += status =>
        {
            StatusChanged?.Invoke(status);
            _overlay.SetStatus(status);
        };
        _core.SessionStarted += OnSessionStarted;
        _core.PartialText += OnPartial;
        _core.FinalText += OnFinal;
        _core.Cancelled += OnCancelled;
        _core.ButtonAction += OnAction;
        _core.Error += message =>
        {
            Log.Warn(message);
            StatusChanged?.Invoke(message);
        };
        _core.Pcm += pcm => _speech.Append(pcm);
        _core.PcmEnd += () => _speech.Finish();
        _speech.Text += (text, final) => _core.SendExternalText(text, final);
        _speech.Error += message =>
        {
            Log.Warn(message);
            StatusChanged?.Invoke(message);
            _core.SendExternalText("", true);
        };
    }

    private void OnSessionStarted()
    {
        _active = true;
        _live = null;
        var mode = _settings.OutputMode;

        if (mode == OutputMode.LiveInput)
        {
            _target = TextInjector.ForegroundWindow();
            if (_target != IntPtr.Zero && TextInjector.CanTypeIntoForeground())
            {
                _live = new LiveTextSession(_target);
            }
        }
        else if (mode == OutputMode.PasteOnCompletion)
        {
            _target = TextInjector.ForegroundWindow();
        }

        if (_settings.AsrProvider == "external") _speech.Start();
        if (_live is null) _overlay.ShowTranscript("", false);
    }

    private void OnPartial(string text)
    {
        if (!_active) return;
        if (_live is not null && _live.Update(text)) return;
        _live = null;
        _overlay.ShowTranscript(text, false);
    }

    private void OnFinal(string text)
    {
        _active = false;
        var live = _live;
        _live = null;

        if (string.IsNullOrEmpty(text))
        {
            _overlay.ShowTranscript("", true, "未识别到文字");
            return;
        }

        Latest = text;
        if (_settings.AutoCopy)
        {
            try { System.Windows.Clipboard.SetText(text); }
            catch (Exception ex) { Log.Warn($"自动复制失败：{ex.Message}"); }
        }

        if (live is not null && live.Update(text))
        {
            _overlay.Dismiss();
            return;
        }

        if (_settings.OutputMode == OutputMode.PasteOnCompletion
            && _target != IntPtr.Zero
            && TextInjector.ForegroundWindow() == _target)
        {
            if (TextInjector.PasteText(text, _settings.AutoCopy))
            {
                _overlay.Dismiss();
                return;
            }
        }

        _overlay.ShowTranscript(text, true);
    }

    private void OnCancelled()
    {
        _active = false;
        _live = null;
        _overlay.Dismiss();
    }

    private void OnAction(string action)
    {
        switch (action)
        {
            case "copyResult":
                if (string.IsNullOrEmpty(Latest))
                {
                    StatusChanged?.Invoke("暂无识别结果");
                    return;
                }
                try
                {
                    System.Windows.Clipboard.SetText(Latest);
                    StatusChanged?.Invoke("已复制识别结果");
                }
                catch (Exception ex)
                {
                    Log.Warn($"复制失败：{ex.Message}");
                }
                break;
            case "showResult":
                if (string.IsNullOrEmpty(Latest)) StatusChanged?.Invoke("暂无识别结果");
                else _overlay.SetLatest(Latest);
                break;
            case "paste": TextInjector.PasteShortcut(); break;
            case "undo": TextInjector.UndoShortcut(); break;
            case "enter": TextInjector.PressEnter(); break;
            case "escape": TextInjector.PressEscape(); break;
            case "cancel": _core.Cancel(); break;
            default: Log.Info($"未处理的按键动作：{action}"); break;
        }
    }

    public void Cancel() => _core.Cancel();

    public void ShowLatest()
    {
        if (string.IsNullOrEmpty(Latest)) StatusChanged?.Invoke("暂无识别结果");
        else _overlay.SetLatest(Latest);
    }

    public void CopyLatest()
    {
        if (string.IsNullOrEmpty(Latest))
        {
            StatusChanged?.Invoke("暂无识别结果");
            return;
        }
        try
        {
            System.Windows.Clipboard.SetText(Latest);
            StatusChanged?.Invoke("已复制识别结果");
        }
        catch (Exception ex)
        {
            Log.Warn($"复制失败：{ex.Message}");
        }
    }

    public void Dispose()
    {
        _speech.Dispose();
    }
}
