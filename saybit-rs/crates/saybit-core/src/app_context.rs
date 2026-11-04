//! 前景 App 分類（移植 Models/AppContext.swift；先比對 bundle id 精確表，再比對名稱；Xcode 要排在 code 之前）
use crate::types::*;

/// Windows / Linux 常見的終端機執行檔（精確比對檔名主幹）
const EXTRA_TERMINALS: &[&str] = &[
    "cmd", "powershell", "pwsh", "conhost", "windowsterminal", "wt", "mintty", "konsole", "alacritty", "kitty",
    "wezterm", "wezterm-gui", "xterm", "urxvt", "rxvt", "tilix", "terminator", "foot", "ghostty", "hyper", "tabby",
    "st", "yakuake", "guake", "xfce4-terminal", "gnome-terminal", "gnome-terminal-server", "kgx", "ptyxis",
];

fn stem(s: &str) -> &str {
    s.strip_suffix(".exe").unwrap_or(s)
}

/// 給 LLM 的 context id（"cursor"、"slack"、"gmail"…），未知就回小寫 App 名稱。
/// macOS 規則照 Swift；額外認 Windows exe / Linux WM_CLASS 的終端機與 VS Code。
pub fn context_identifier(ctx: &AppContext) -> String {
    let name = ctx.app_name.trim().to_lowercase();
    let bid = ctx.bundle_id.trim().to_lowercase();
    let n = name.as_str();
    let b = bid.as_str();
    let n_stem = stem(n);
    let b_stem = stem(b);

    // Code Editors & IDEs —— Xcode 要先比對，否則 "code" 會把 Xcode 判成 vscode
    if n == "xcode" || b == "com.apple.dt.xcode" {
        return "xcode".into();
    }
    if n.contains("cursor") || b.contains("cursor") {
        return "cursor".into();
    }
    if n_stem == "code" || n.starts_with("visual studio code") || b.contains("vscode") || b_stem == "code" {
        return "vscode".into();
    }
    if n.contains("windsurf") || b.contains("windsurf") {
        return "windsurf".into();
    }
    if n.contains("intellij") || b.contains("intellij") {
        return "intellij".into();
    }
    if n.contains("pycharm") || b.contains("pycharm") {
        return "pycharm".into();
    }
    if n.contains("android studio") || b.contains("android-studio") {
        return "android-studio".into();
    }
    if n.contains("sublime") || b.contains("sublimetext") {
        return "sublime".into();
    }
    if n.contains("fleet") || b.contains("fleet") {
        return "fleet".into();
    }
    if n.contains("zed") || b.contains("zed") {
        return "zed".into();
    }
    if n.contains("vim") || n.contains("neovim") {
        return "vim".into();
    }
    if n.contains("terminal") || b.contains("terminal") || n.contains("iterm") || b.contains("iterm") || n.contains("warp") || b.contains("warp") {
        return "terminal".into();
    }
    if EXTRA_TERMINALS.contains(&n_stem) || EXTRA_TERMINALS.contains(&b_stem) {
        return "terminal".into();
    }

    // Chat & Messaging
    if n.contains("slack") || b.contains("slack") {
        return "slack".into();
    }
    if n.contains("discord") || b.contains("discord") {
        return "discord".into();
    }
    // bundle id 或精確名稱，避免 Timeline / Streamline / Baseline 被判成 LINE
    if b.contains("naver.line") || b.ends_with(".line") || n == "line" || b_stem == "line" {
        return "line".into();
    }
    if n.contains("messages") || b.contains("imessage") {
        return "imessage".into();
    }
    if n.contains("telegram") || b.contains("telegram") {
        return "telegram".into();
    }
    if n.contains("wechat") || b.contains("wechat") {
        return "wechat".into();
    }
    if n.contains("teams") || b.contains("teams") {
        return "teams".into();
    }
    if n.contains("messenger") || b.contains("messenger") {
        return "messenger".into();
    }
    if n.contains("zoom") || b.contains("zoom") {
        return "zoom-chat".into();
    }

    // Email & Documents —— 精確比對，Mailchimp / Mailtrap 不是寫信情境
    if matches!(n, "mail" | "gmail" | "mimestream" | "spark" | "thunderbird")
        || b == "com.apple.mail"
        || b.contains("mimestream")
        || b.contains("readdle.smartemail")
        || b_stem == "thunderbird"
    {
        return "gmail".into();
    }
    if n.contains("outlook") || b.contains("outlook") {
        return "outlook".into();
    }
    if n.contains("docs") || b.contains("docs") {
        return "google-docs".into();
    }
    if n.contains("sheets") || b.contains("sheets") {
        return "google-sheets".into();
    }
    if n.contains("word") || b.contains("msword") || b_stem == "winword" {
        return "word".into();
    }

    // Note-taking
    if n.contains("obsidian") || b.contains("obsidian") {
        return "obsidian".into();
    }
    if n == "notes" || n == "備忘錄" || b == "com.apple.notes" {
        return "notes".into();
    }
    if n.contains("notion") || b.contains("notion") {
        return "notion".into();
    }

    // Design
    if n.contains("figma") || b.contains("figma") {
        return "figma".into();
    }
    if n.contains("sketch") || b.contains("sketch") {
        return "sketch".into();
    }

    // Project Management
    for pm in ["linear", "jira", "clickup", "asana"] {
        if n.contains(pm) || b.contains(pm) {
            return pm.into();
        }
    }

    // Browsers —— "arc" 子字串太常見，只認 Arc 本身
    if n.contains("safari") || b.contains("safari") {
        return "safari".into();
    }
    if n.contains("chrome") || b.contains("chrome") {
        return "chrome".into();
    }
    if n.contains("firefox") || b.contains("firefox") {
        return "firefox".into();
    }
    if n == "arc" || b == "company.thebrowser.browser" {
        return "arc".into();
    }

    // AI Tools
    if n.contains("chatgpt") || b.contains("chatgpt") {
        return "chatgpt".into();
    }
    if n.contains("claude") || b.contains("claude") {
        return "claude".into();
    }

    name
}

pub fn category(ctx: &AppContext) -> ContextCategory {
    match context_identifier(ctx).as_str() {
        "terminal" => ContextCategory::Terminal,
        "cursor" | "vscode" | "windsurf" | "xcode" | "intellij" | "pycharm" | "android-studio" | "sublime" | "fleet"
        | "zed" | "vim" => ContextCategory::CodeEditor,
        "slack" | "discord" | "line" | "imessage" | "telegram" | "wechat" | "teams" | "messenger" | "zoom-chat" => {
            ContextCategory::ChatMessaging
        }
        "gmail" | "outlook" => ContextCategory::Email,
        "word" | "google-docs" | "google-sheets" => ContextCategory::Office,
        "obsidian" | "notes" | "notion" => ContextCategory::Notes,
        "safari" | "chrome" | "firefox" | "arc" => ContextCategory::Browser,
        _ => ContextCategory::Other,
    }
}

/// 終端機：貼上換行 = 執行指令，pipeline 強制預覽、不 Smart Send
pub fn is_terminal(ctx: &AppContext) -> bool {
    context_identifier(ctx) == "terminal"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(name: &str, bid: &str) -> AppContext {
        AppContext { app_name: name.into(), bundle_id: bid.into(), ..Default::default() }
    }

    #[test]
    fn app_context_identifiers() {
        assert_eq!(context_identifier(&ctx("Xcode", "com.apple.dt.Xcode")), "xcode");
        assert_eq!(context_identifier(&ctx("Code", "com.microsoft.VSCode")), "vscode");
        assert_eq!(context_identifier(&ctx("Visual Studio Code", "Code.exe")), "vscode");
        assert_eq!(context_identifier(&ctx("Timeline", "com.x.timeline")), "timeline");
        assert_eq!(context_identifier(&ctx("LINE", "jp.naver.line.mac")), "line");
        assert_eq!(context_identifier(&ctx("Mailchimp", "")), "mailchimp");
        assert_eq!(context_identifier(&ctx("Mail", "com.apple.mail")), "gmail");
        assert_eq!(context_identifier(&ctx("Archive Utility", "")), "archive utility");
        assert_eq!(context_identifier(&ctx("Arc", "company.thebrowser.Browser")), "arc");
        assert_eq!(context_identifier(&ctx("", "")), "");
    }

    #[test]
    fn app_context_terminal_and_category() {
        assert!(is_terminal(&ctx("Terminal", "com.apple.Terminal")));
        assert!(is_terminal(&ctx("iTerm2", "com.googlecode.iterm2")));
        assert!(is_terminal(&ctx("Windows PowerShell", "powershell.exe")));
        assert!(is_terminal(&ctx("WindowsTerminal", "WindowsTerminal.exe")));
        assert!(is_terminal(&ctx("kitty", "kitty")));
        assert!(!is_terminal(&ctx("Slack", "com.tinyspeck.slackmacgap")));
        assert_eq!(category(&ctx("Slack", "")), ContextCategory::ChatMessaging);
        assert_eq!(category(&ctx("Terminal", "")), ContextCategory::Terminal);
        assert_eq!(category(&ctx("Cursor", "")), ContextCategory::CodeEditor);
        assert_eq!(category(&ctx("Outlook", "")), ContextCategory::Email);
        assert_eq!(category(&ctx("Microsoft Word", "")), ContextCategory::Office);
        assert_eq!(category(&ctx("Notion", "")), ContextCategory::Notes);
        assert_eq!(category(&ctx("Google Chrome", "")), ContextCategory::Browser);
        assert_eq!(category(&ctx("Finder", "")), ContextCategory::Other);
    }
}
