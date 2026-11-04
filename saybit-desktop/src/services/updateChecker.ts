// 輕量更新檢查：呼叫 GitHub Releases API 取最新版號比對目前版本。
// 移植自原生版 Core/Update/UpdateChecker.swift。

import { fetch } from '@tauri-apps/plugin-http';
import { getVersion } from '@tauri-apps/api/app';

const REPO = 'Oliver0804/Saybit';

export interface ReleaseInfo {
  tagName: string;
  name: string | null;
  htmlUrl: string;
  body: string | null;
  prerelease: boolean;
}

export type CheckResult =
  | { kind: 'upToDate'; current: string }
  | { kind: 'newer'; current: string; latest: ReleaseInfo }
  | { kind: 'ahead'; current: string; latest: string };

export async function fetchLatestRelease(): Promise<ReleaseInfo> {
  const response = await fetch(
    `https://api.github.com/repos/${REPO}/releases/latest`,
    {
      method: 'GET',
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'Saybit-UpdateChecker',
      },
    }
  );
  if (response.status === 404) throw new Error('GitHub 上尚無 release');
  if (!response.ok) throw new Error(`更新檢查 HTTP ${response.status}`);

  const data = await response.json();
  return {
    tagName: data.tag_name ?? '',
    name: data.name ?? null,
    htmlUrl: data.html_url ?? '',
    body: data.body ?? null,
    prerelease: Boolean(data.prerelease),
  };
}

/// Semver 2.0 precedence：先比 major.minor.patch（缺項補 0），相同時有 pre-release 的較舊
/// （`1.5.0-beta.1 < 1.5.0`），兩者都有則逐段比較識別字；`+build` 忽略（審查 L2）。
/// 回傳 >0 表示 a 比 b 新。
export function compareVersions(a: string, b: string): number {
  const split = (raw: string): { core: number[]; pre: string[] | null } => {
    const s = raw.trim().replace(/^v/i, '');
    const noBuild = s.split('+')[0] ?? '';
    const dash = noBuild.indexOf('-');
    const coreStr = dash >= 0 ? noBuild.slice(0, dash) : noBuild;
    const preStr = dash >= 0 ? noBuild.slice(dash + 1) : '';
    const core = coreStr
      .split('.')
      .map((p) => (/^\d+$/.test(p) ? parseInt(p, 10) : NaN))
      .filter((n) => !Number.isNaN(n));
    return { core, pre: preStr ? preStr.split('.') : null };
  };

  const l = split(a);
  const r = split(b);
  const length = Math.max(l.core.length, r.core.length);
  for (let i = 0; i < length; i++) {
    const diff = (l.core[i] ?? 0) - (r.core[i] ?? 0);
    if (diff !== 0) return diff;
  }
  if (!l.pre && !r.pre) return 0;
  if (!l.pre) return 1;
  if (!r.pre) return -1;

  const isNum = (x: string) => /^\d+$/.test(x);
  const n = Math.min(l.pre.length, r.pre.length);
  for (let i = 0; i < n; i++) {
    const x = l.pre[i];
    const y = r.pre[i];
    if (isNum(x) && isNum(y)) {
      const d = parseInt(x, 10) - parseInt(y, 10);
      if (d !== 0) return d;
    } else if (isNum(x)) {
      return -1; // 數字識別字 < 文字識別字
    } else if (isNum(y)) {
      return 1;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return l.pre.length - r.pre.length;
}

export async function checkForUpdate(): Promise<CheckResult> {
  const current = await getVersion();
  const latest = await fetchLatestRelease();
  const diff = compareVersions(latest.tagName, current);
  if (diff > 0) return { kind: 'newer', current, latest };
  if (diff < 0) return { kind: 'ahead', current, latest: latest.tagName };
  return { kind: 'upToDate', current };
}

/// 每日最多檢查一次。回傳 null 表示這輪被節流掉或檢查失敗。
export async function checkForUpdateThrottled(
  lastCheckAt: number
): Promise<CheckResult | null> {
  const oneDay = 24 * 60 * 60 * 1000;
  if (Date.now() - lastCheckAt < oneDay) return null;
  try {
    return await checkForUpdate();
  } catch {
    return null;
  }
}
