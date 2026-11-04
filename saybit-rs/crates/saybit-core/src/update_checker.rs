//! GitHub Releases 版本檢查（移植 UpdateChecker.swift；semver 2.0 含 pre-release；只開瀏覽器不自動下載）
use std::cmp::Ordering;
use std::time::Duration;

pub const REPO: &str = "Oliver0804/Saybit";
pub fn current_version() -> &'static str { env!("CARGO_PKG_VERSION") }

/// 有比目前新的版本 → Some((tag, html_url))；已是最新 / 沒有 release → None
pub fn check_latest() -> anyhow::Result<Option<(String, String)>> {
    let agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .new_agent();
    let resp = agent
        .get(&format!("https://api.github.com/repos/{REPO}/releases/latest"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "Saybit-UpdateChecker")
        .call()
        .map_err(|e| anyhow::anyhow!("更新檢查網路錯誤：{e}"))?;
    let status = resp.status().as_u16();
    if status == 404 {
        return Ok(None);
    }
    if !(200..300).contains(&status) {
        anyhow::bail!("更新檢查 HTTP {status}");
    }
    let body = resp
        .into_body()
        .read_to_string()
        .map_err(|e| anyhow::anyhow!("更新資訊讀取失敗：{e}"))?;
    let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| anyhow::anyhow!("更新資訊解析失敗：{e}"))?;
    let tag = v["tag_name"].as_str().unwrap_or_default().to_string();
    let url = v["html_url"].as_str().unwrap_or_default().to_string();
    if tag.is_empty() {
        return Ok(None);
    }
    Ok(is_newer(current_version(), &tag).then_some((tag, url)))
}

/// `latest` 是否比 `current` 新
pub fn is_newer(current: &str, latest: &str) -> bool {
    compare_semver(current, latest) == Ordering::Less
}

/// "v1.5.0" → "1.5.0"
pub fn normalize(tag: &str) -> &str {
    let s = tag.trim();
    s.strip_prefix(['v', 'V']).unwrap_or(s)
}

fn split(raw: &str) -> (Vec<u64>, Option<Vec<&str>>) {
    let no_build = normalize(raw).split('+').next().unwrap_or("");
    let (core, pre) = match no_build.split_once('-') {
        Some((c, p)) => (c, Some(p)),
        None => (no_build, None),
    };
    let core = core.split('.').filter_map(|p| p.parse::<u64>().ok()).collect();
    let pre = pre.filter(|p| !p.is_empty()).map(|p| p.split('.').collect());
    (core, pre)
}

/// semver 2.0 precedence：先比 major.minor.patch（缺項補 0）；相同時有 pre-release 的較舊
/// （`1.5.0-beta.1 < 1.5.0`），都有就逐段比（數字 < 文字）；`+build` 忽略
pub fn compare_semver(a: &str, b: &str) -> Ordering {
    let (ac, ap) = split(a);
    let (bc, bp) = split(b);
    for i in 0..ac.len().max(bc.len()) {
        let x = ac.get(i).copied().unwrap_or(0);
        let y = bc.get(i).copied().unwrap_or(0);
        if x != y {
            return x.cmp(&y);
        }
    }
    match (ap, bp) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(l), Some(r)) => {
            for (x, y) in l.iter().zip(r.iter()) {
                let o = match (x.parse::<u64>(), y.parse::<u64>()) {
                    (Ok(p), Ok(q)) => p.cmp(&q),
                    (Ok(_), Err(_)) => Ordering::Less,
                    (Err(_), Ok(_)) => Ordering::Greater,
                    (Err(_), Err(_)) => x.cmp(y),
                };
                if o != Ordering::Equal {
                    return o;
                }
            }
            l.len().cmp(&r.len())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_checker_semver() {
        use Ordering::*;
        assert_eq!(compare_semver("1.5.0", "v1.5.0"), Equal);
        assert_eq!(compare_semver("1.5", "1.5.0"), Equal);
        assert_eq!(compare_semver("1.4.9", "1.5.0"), Less);
        assert_eq!(compare_semver("1.10.0", "1.9.0"), Greater);
        assert_eq!(compare_semver("1.5.0-beta.1", "1.5.0"), Less);
        assert_eq!(compare_semver("1.5.0", "1.5.0-rc.1"), Greater);
        assert_eq!(compare_semver("1.5.0-alpha", "1.5.0-alpha.1"), Less);
        assert_eq!(compare_semver("1.5.0-alpha.1", "1.5.0-alpha.beta"), Less);
        assert_eq!(compare_semver("1.5.0-beta.2", "1.5.0-beta.11"), Less);
        assert_eq!(compare_semver("1.5.0-rc.1", "1.5.0-beta.11"), Greater);
        assert_eq!(compare_semver("1.5.0+build.7", "1.5.0"), Equal);
        assert!(is_newer("0.1.0", "v0.2.0-beta.1"));
        assert!(!is_newer("0.2.0", "v0.2.0-beta.1"));
    }
}
