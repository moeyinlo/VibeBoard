using System.Runtime.InteropServices;
using System.Text;
using System.Windows;

namespace VibeBoardPlus.Core;

/// <summary>
/// Text delivery into the focused control, using SendInput (the Windows analogue of the
/// macOS Accessibility API).
///
/// Live mode tracks what this session inserted so a revised partial transcript only replaces
/// its own range; if focus moves, callers fall back to the floating window.
/// </summary>
public static class TextInjector
{
    private const int InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const uint KeyEventUnicode = 0x0004;
    private const ushort VkBack = 0x08;
    private const ushort VkReturn = 0x0D;
    private const ushort VkEscape = 0x1B;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;
    private const ushort VkZ = 0x5A;

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public int Size;
        public uint Flags;
        public IntPtr ActiveWindow;
        public IntPtr FocusWindow;
        public IntPtr CaptionWindow;
        public IntPtr MenuOwnerWindow;
        public IntPtr MoveSizeWindow;
        public IntPtr CaretWindow;
        public RECT CaretRect;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern IntPtr GetFocus();

    public static IntPtr ForegroundWindow() => GetForegroundWindow();

    /// <summary>
    /// True when the focused control in the foreground window has a caret, which is the
    /// practical signal that typed text will land somewhere useful.
    /// </summary>
    public static bool CanTypeIntoForeground()
    {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero) return false;
        var thread = GetWindowThreadProcessId(window, out _);
        var info = new GuiThreadInfo { Size = Marshal.SizeOf<GuiThreadInfo>() };
        if (!GetGUIThreadInfo(thread, ref info)) return false;
        return info.CaretWindow != IntPtr.Zero || info.FocusWindow != IntPtr.Zero;
    }

    public static void TypeUnicode(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        var inputs = new List<Input>(text.Length * 2);
        foreach (var character in text)
        {
            inputs.Add(Unicode(character, false));
            inputs.Add(Unicode(character, true));
        }
        Send(inputs);
    }

    public static void Backspace(int count)
    {
        if (count <= 0) return;
        var inputs = new List<Input>(count * 2);
        for (var index = 0; index < count; index++)
        {
            inputs.Add(VirtualKey(VkBack, false, false));
            inputs.Add(VirtualKey(VkBack, false, true));
        }
        Send(inputs);
    }

    public static void PasteShortcut() => Send(new List<Input>
    {
        VirtualKey(VkControl, false, false),
        VirtualKey(VkV, false, false),
        VirtualKey(VkV, false, true),
        VirtualKey(VkControl, false, true),
    });

    public static void UndoShortcut() => Send(new List<Input>
    {
        VirtualKey(VkControl, false, false),
        VirtualKey(VkZ, false, false),
        VirtualKey(VkZ, false, true),
        VirtualKey(VkControl, false, true),
    });

    public static void PressEnter() => Send(new List<Input>
    {
        VirtualKey(VkReturn, false, false),
        VirtualKey(VkReturn, false, true),
    });

    public static void PressEscape() => Send(new List<Input>
    {
        VirtualKey(VkEscape, false, false),
        VirtualKey(VkEscape, false, true),
    });

    /// <summary>Pastes through the clipboard and restores the previous contents afterwards.</summary>
    public static bool PasteText(string text, bool keepClipboard)
    {
        string? previous = null;
        try
        {
            if (!keepClipboard) previous = TryGetClipboard();
            System.Windows.Clipboard.SetText(text);
            PasteShortcut();
            if (!keepClipboard)
            {
                // Give the target app time to read the clipboard before restoring.
                var restore = previous;
                Task.Delay(700).ContinueWith(_ =>
                {
                    try
                    {
                        if (restore is null) System.Windows.Clipboard.Clear();
                        else System.Windows.Clipboard.SetText(restore);
                    }
                    catch
                    {
                        // Another app may hold the clipboard; leaving our text is harmless.
                    }
                }, TaskScheduler.FromCurrentSynchronizationContext());
            }
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"剪贴板粘贴失败：{ex.Message}");
            return false;
        }
    }

    private static string? TryGetClipboard()
    {
        try
        {
            return System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null;
        }
        catch
        {
            return null;
        }
    }

    private static Input Unicode(char character, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = 0,
                ScanCode = character,
                Flags = KeyEventUnicode | (keyUp ? KeyEventKeyUp : 0),
                Time = 0,
                ExtraInfo = IntPtr.Zero,
            },
        },
    };

    private static Input VirtualKey(ushort key, bool extended, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = key,
                ScanCode = 0,
                Flags = (extended ? 0x0001u : 0u) | (keyUp ? KeyEventKeyUp : 0),
                Time = 0,
                ExtraInfo = IntPtr.Zero,
            },
        },
    };

    private static void Send(List<Input> inputs)
    {
        if (inputs.Count == 0) return;
        var array = inputs.ToArray();
        var sent = SendInput((uint)array.Length, array, Marshal.SizeOf<Input>());
        if (sent != array.Length) Log.Warn($"SendInput 只发送了 {sent}/{array.Length} 个事件");
    }
}

/// <summary>
/// Tracks the text this session inserted into the focused control so partial transcripts can
/// be replaced in place without touching the user's other text.
/// </summary>
public sealed class LiveTextSession
{
    private readonly IntPtr _window;
    private string _inserted = "";
    private bool _started;

    public LiveTextSession(IntPtr window) => _window = window;

    public bool TargetStillFocused => TextInjector.ForegroundWindow() == _window;

    public bool Update(string text)
    {
        if (!TargetStillFocused) return false;
        if (_started)
        {
            if (text == _inserted) return true;
            TextInjector.Backspace(_inserted.Length);
        }
        TextInjector.TypeUnicode(text);
        _inserted = text;
        _started = true;
        return true;
    }
}
