//! Button semantics shared by both shells.
//!
//! The firmware emits `button_down`, `button_up` and often a trailing `button_click` for the
//! same press. The router debounces that pair so a single press cannot start and stop a
//! session, and maps each press to a command based on the configured per-button action.

use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonAction {
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

impl ButtonAction {
    pub const ALL: [ButtonAction; 10] = [
        ButtonAction::Voice,
        ButtonAction::ToggleVoice,
        ButtonAction::CopyResult,
        ButtonAction::ShowResult,
        ButtonAction::Cancel,
        ButtonAction::Paste,
        ButtonAction::Undo,
        ButtonAction::Enter,
        ButtonAction::Escape,
        ButtonAction::None,
    ];

    /// Stable identifier used in settings and across the FFI boundary.
    pub fn as_str(self) -> &'static str {
        match self {
            ButtonAction::Voice => "voice",
            ButtonAction::ToggleVoice => "toggleVoice",
            ButtonAction::CopyResult => "copyResult",
            ButtonAction::ShowResult => "showResult",
            ButtonAction::Cancel => "cancel",
            ButtonAction::Paste => "paste",
            ButtonAction::Undo => "undo",
            ButtonAction::Enter => "enter",
            ButtonAction::Escape => "escape",
            ButtonAction::None => "none",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|action| action.as_str().eq_ignore_ascii_case(value))
    }

    /// Localised menu label (the shells show these verbatim).
    pub fn label(self) -> &'static str {
        match self {
            ButtonAction::Voice => "按住说话",
            ButtonAction::ToggleVoice => "切换录音",
            ButtonAction::CopyResult => "复制识别结果",
            ButtonAction::ShowResult => "显示最近结果",
            ButtonAction::Cancel => "取消识别",
            ButtonAction::Paste => "粘贴",
            ButtonAction::Undo => "撤销",
            ButtonAction::Enter => "回车",
            ButtonAction::Escape => "Escape",
            ButtonAction::None => "不执行动作",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Start,
    Finish,
    Toggle,
    Action(ButtonAction),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Routed {
    pub command: Command,
    pub session_id: u64,
}

#[derive(Debug, Default)]
pub struct ButtonRouter {
    pressed: HashMap<String, ButtonAction>,
    released: HashMap<String, Instant>,
    click_guard: Duration,
}

impl ButtonRouter {
    pub fn new() -> Self {
        Self {
            pressed: HashMap::new(),
            released: HashMap::new(),
            click_guard: Duration::from_millis(500),
        }
    }

    pub fn reset(&mut self) {
        self.pressed.clear();
        self.released.clear();
    }

    pub fn down(&mut self, button: &str, session_id: u64, action: ButtonAction) -> Option<Routed> {
        if self.pressed.contains_key(button) {
            return None;
        }
        self.pressed.insert(button.to_string(), action);
        let command = match action {
            ButtonAction::Voice => Command::Start,
            ButtonAction::ToggleVoice => Command::Toggle,
            ButtonAction::None => return None,
            other => Command::Action(other),
        };
        Some(Routed {
            command,
            session_id,
        })
    }

    pub fn up(&mut self, button: &str) -> Option<Routed> {
        let action = self.pressed.remove(button)?;
        self.released.insert(button.to_string(), Instant::now());
        (action == ButtonAction::Voice).then_some(Routed {
            command: Command::Finish,
            session_id: 0,
        })
    }

    pub fn click(&mut self, button: &str, action: ButtonAction) -> Option<Routed> {
        if self.pressed.contains_key(button) {
            return None;
        }
        if let Some(released) = self.released.get(button) {
            if released.elapsed() <= self.click_guard {
                return None;
            }
        }
        let command = match action {
            ButtonAction::Voice | ButtonAction::ToggleVoice => Command::Toggle,
            ButtonAction::None => return None,
            other => Command::Action(other),
        };
        Some(Routed {
            command,
            session_id: 0,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voice_press_starts_and_release_finishes() {
        let mut router = ButtonRouter::new();
        assert_eq!(
            router.down("k4", 7, ButtonAction::Voice),
            Some(Routed {
                command: Command::Start,
                session_id: 7
            })
        );
        assert_eq!(
            router.down("k4", 7, ButtonAction::Voice),
            None,
            "duplicate down is ignored"
        );
        assert_eq!(
            router.up("k4"),
            Some(Routed {
                command: Command::Finish,
                session_id: 0
            })
        );
        assert_eq!(router.up("k4"), None);
    }

    #[test]
    fn trailing_click_after_release_is_swallowed() {
        let mut router = ButtonRouter::new();
        router.down("k4", 1, ButtonAction::Voice);
        router.up("k4");
        assert_eq!(router.click("k4", ButtonAction::Voice), None);
    }

    #[test]
    fn standalone_click_toggles() {
        let mut router = ButtonRouter::new();
        assert_eq!(
            router.click("k2", ButtonAction::Voice),
            Some(Routed {
                command: Command::Toggle,
                session_id: 0
            })
        );
        assert_eq!(
            router.click("k2", ButtonAction::ToggleVoice),
            Some(Routed {
                command: Command::Toggle,
                session_id: 0
            })
        );
    }

    #[test]
    fn click_is_allowed_after_the_guard_window() {
        let mut router = ButtonRouter::new();
        router.down("k1", 1, ButtonAction::Voice);
        router.up("k1");
        router
            .released
            .insert("k1".into(), Instant::now() - Duration::from_millis(800));
        assert_eq!(
            router.click("k1", ButtonAction::Voice),
            Some(Routed {
                command: Command::Toggle,
                session_id: 0
            })
        );
    }

    #[test]
    fn action_buttons_are_routed_directly() {
        let mut router = ButtonRouter::new();
        assert_eq!(
            router.down("k1", 0, ButtonAction::CopyResult),
            Some(Routed {
                command: Command::Action(ButtonAction::CopyResult),
                session_id: 0
            })
        );
        assert_eq!(
            router.click("k3", ButtonAction::Paste),
            Some(Routed {
                command: Command::Action(ButtonAction::Paste),
                session_id: 0
            })
        );
        assert_eq!(router.down("k2", 0, ButtonAction::None), None);
    }

    #[test]
    fn action_ids_round_trip() {
        for action in ButtonAction::ALL {
            assert_eq!(ButtonAction::parse(action.as_str()), Some(action));
        }
        assert!(ButtonAction::parse("nonsense").is_none());
    }
}
