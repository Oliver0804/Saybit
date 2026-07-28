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

/// 語意化版本比較。回傳 >0 表示 a 比 b 新。
export function compareVersions(a: string, b: string): number {
  const normalize = (v: string) =>
    v
      .replace(/^v/i, '')
      .split(/[.\-+]/)
      .map((part) => parseInt(part, 10))
      .filter((n) => !Number.isNaN(n));

  const left = normalize(a);
  const right = normalize(b);
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
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
