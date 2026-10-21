namespace VibeBoardPlus.Core;

public enum ButtonAction
{
    Voice,
    ToggleVoice,
    CopyResult,
    ShowResult,
    Cancel,
    Paste,
    Undo,
    Enter,
    Escape,
    None,
}

public static class ButtonActionInfo
{
    public static readonly ButtonAction[] All =
    {
        ButtonAction.Voice, ButtonAction.ToggleVoice, ButtonAction.CopyResult, ButtonAction.ShowResult,
        ButtonAction.Cancel, ButtonAction.Paste, ButtonAction.Undo, ButtonAction.Enter, ButtonAction.Escape,
        ButtonAction.None,
    };

    public static string Label(this ButtonAction action) => action switch
    {
        ButtonAction.Voice => "按住说话",
        ButtonAction.ToggleVoice => "切换录音",
        ButtonAction.CopyResult => "复制识别结果",
        ButtonAction.ShowResult => "显示最近结果",
        ButtonAction.Cancel => "取消识别",
        ButtonAction.Paste => "粘贴 (Ctrl+V)",
        ButtonAction.Undo => "撤销 (Ctrl+Z)",
        ButtonAction.Enter => "回车",
        ButtonAction.Escape => "Escape",
        _ => "不执行动作",
    };

    /// <summary>Stable id understood by the Rust core (`button_actions` values).</summary>
    public static string Id(this ButtonAction action) => action switch
    {
        ButtonAction.Voice => "voice",
        ButtonAction.ToggleVoice => "toggleVoice",
        ButtonAction.CopyResult => "copyResult",
        ButtonAction.ShowResult => "showResult",
        ButtonAction.Cancel => "cancel",
        ButtonAction.Paste => "paste",
        ButtonAction.Undo => "undo",
        ButtonAction.Enter => "enter",
        ButtonAction.Escape => "escape",
        _ => "none",
    };
}
