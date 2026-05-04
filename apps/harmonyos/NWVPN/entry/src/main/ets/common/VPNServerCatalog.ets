/**
 * 与 iOS `VPNServerCatalog.swift` 对齐：解析 rawfile/servers（格式同仓库 configs/servers）。
 */
export interface VPNServerEntry {
  displayName: string;
  host: string;
}

const DEFAULT_PORT = 8443;

export function serverAddressOf(entry: VPNServerEntry): string {
  return `${entry.host}:${DEFAULT_PORT}`;
}

function normalizeConfigToken(raw: string): string {
  let s = raw.trim();
  s = s.replace(/\r/g, '');
  if (s.startsWith('\uFEFF')) {
    s = s.substring(1);
  }
  return s;
}

function normalizeHostLookup(raw: string): string {
  const t = normalizeConfigToken(raw);
  const idx = t.indexOf(':');
  if (idx < 0) {
    return t;
  }
  const hostPart = t.substring(0, idx);
  const portPart = t.substring(idx + 1);
  if (!hostPart.includes(':') && !hostPart.includes('[') && /^\d+$/.test(portPart)) {
    return hostPart;
  }
  return t;
}

function fallbackEntries(): VPNServerEntry[] {
  return [{ displayName: '韩国', host: 'new-world-kr-01.2fish.com.cn' }];
}

export function parseServersText(text: string): VPNServerEntry[] {
  const out: VPNServerEntry[] = [];
  let body = text;
  if (body.startsWith('\uFEFF')) {
    body = body.substring(1);
  }
  const lines = body.split('\n');
  for (const rawLine of lines) {
    const line = normalizeConfigToken(rawLine);
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    const parts = line.split(/\s+/).filter((p) => p.length > 0);
    if (parts.length < 2) {
      continue;
    }
    const displayName = normalizeConfigToken(parts[0]);
    const host = normalizeHostLookup(parts[1]);
    if (host.length === 0) {
      continue;
    }
    out.push({ displayName: displayName, host: host });
  }
  return out.length > 0 ? out : fallbackEntries();
}

export function entryMatchingHost(raw: string, entries: VPNServerEntry[]): VPNServerEntry | undefined {
  const key = normalizeHostLookup(raw);
  for (let i = 0; i < entries.length; i++) {
    if (normalizeHostLookup(entries[i].host) === key) {
      return entries[i];
    }
  }
  return undefined;
}

export function resolveServerAddress(selectedHost: string, entries: VPNServerEntry[]): string {
  const e = entryMatchingHost(selectedHost, entries);
  if (e !== undefined) {
    return serverAddressOf(e);
  }
  if (entries.length > 0) {
    return serverAddressOf(entries[0]);
  }
  return '';
}

export function normalizeSelectedHost(selectedHost: string, entries: VPNServerEntry[]): string {
  const key = normalizeHostLookup(selectedHost);
  const match = entries.find((e) => normalizeHostLookup(e.host) === key);
  if (match !== undefined) {
    return match.host;
  }
  return entries.length > 0 ? entries[0].host : '';
}
