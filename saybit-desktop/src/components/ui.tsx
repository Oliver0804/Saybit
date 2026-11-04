// 設定畫面共用的視覺元件。對應原生版的 GlassCard / GlassSectionHeader 一組。
import React from 'react';

export function GlassCard({
  title,
  icon: Icon,
  children,
  footer,
}: {
  title?: string;
  icon?: React.ComponentType<{ className?: string }>;
  children: React.ReactNode;
  footer?: React.ReactNode;
}) {
  return (
    <div className="bg-slate-900/60 border border-white/5 rounded-2xl p-6 space-y-4 backdrop-blur-md">
      {title && (
        <div className="flex items-center space-x-2 border-b border-white/5 pb-3">
          {Icon && <Icon className="w-4 h-4 text-emerald-400" />}
          <h3 className="text-sm font-bold">{title}</h3>
        </div>
      )}
      {children}
      {footer && <div className="pt-2 border-t border-white/5">{footer}</div>}
    </div>
  );
}

export function Row({
  label,
  description,
  children,
}: {
  label: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-start justify-between gap-6">
      <div className="min-w-0">
        <label className="text-sm font-semibold text-white/90">{label}</label>
        {description && <p className="text-[11px] text-white/30 mt-0.5 leading-relaxed">{description}</p>}
      </div>
      <div className="flex-shrink-0">{children}</div>
    </div>
  );
}

export function Toggle({
  checked,
  onChange,
  disabled,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`relative w-11 h-6 rounded-full transition-colors flex-shrink-0 ${
        disabled
          ? 'bg-slate-800 cursor-not-allowed opacity-40'
          : checked
            ? 'bg-emerald-500 cursor-pointer'
            : 'bg-slate-700 cursor-pointer'
      }`}
    >
      <span
        className={`absolute top-0.5 left-0.5 w-5 h-5 rounded-full bg-white transition-transform ${
          checked ? 'translate-x-5' : 'translate-x-0'
        }`}
      />
    </button>
  );
}

export function TextField({
  value,
  onChange,
  placeholder,
  type = 'text',
  mono,
  className = '',
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  type?: string;
  mono?: boolean;
  className?: string;
}) {
  return (
    <input
      type={type}
      value={value}
      placeholder={placeholder}
      onChange={(e) => onChange(e.target.value)}
      className={`bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm focus:outline-none focus:border-emerald-500/50 ${
        mono ? 'font-mono text-emerald-400' : ''
      } ${className}`}
    />
  );
}

export function NumberField({
  value,
  onChange,
  min,
  max,
  step = 1,
  className = 'w-28',
}: {
  value: number;
  onChange: (value: number) => void;
  min?: number;
  max?: number;
  step?: number;
  className?: string;
}) {
  return (
    <input
      type="number"
      value={value}
      min={min}
      max={max}
      step={step}
      onChange={(e) => {
        const parsed = parseFloat(e.target.value);
        if (!Number.isNaN(parsed)) onChange(parsed);
      }}
      className={`bg-slate-950/80 border border-white/10 rounded-xl px-3 py-2 text-sm focus:outline-none focus:border-emerald-500/50 ${className}`}
    />
  );
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: Array<{ value: T; label: string; disabled?: boolean }>;
  onChange: (value: T) => void;
}) {
  return (
    <div className="flex flex-wrap gap-2">
      {options.map((option) => {
        const active = option.value === value;
        return (
          <button
            key={option.value}
            type="button"
            disabled={option.disabled}
            onClick={() => onChange(option.value)}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium border transition-all ${
              option.disabled
                ? 'bg-slate-950/40 border-white/5 text-white/20 cursor-not-allowed'
                : active
                  ? 'bg-emerald-500/15 border-emerald-500/40 text-emerald-300 cursor-pointer'
                  : 'bg-slate-950/60 border-white/10 text-white/50 hover:text-white cursor-pointer'
            }`}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

export function Select<T extends string>({
  value,
  options,
  onChange,
  className = '',
}: {
  value: T;
  options: Array<{ value: T; label: string }>;
  onChange: (value: T) => void;
  className?: string;
}) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value as T)}
      className={`bg-slate-950/80 border border-white/10 rounded-xl px-3 py-2 text-sm focus:outline-none focus:border-emerald-500/50 cursor-pointer ${className}`}
    >
      {options.map((option) => (
        <option key={option.value} value={option.value} className="bg-slate-900">
          {option.label}
        </option>
      ))}
    </select>
  );
}

export function Slider({
  value,
  onChange,
  min,
  max,
  step,
  suffix,
}: {
  value: number;
  onChange: (value: number) => void;
  min: number;
  max: number;
  step: number;
  suffix?: string;
}) {
  return (
    <div className="flex items-center gap-3">
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        className="w-40 accent-emerald-500 cursor-pointer"
      />
      <span className="text-xs font-mono text-white/60 w-14 text-right">
        {value}
        {suffix ?? ''}
      </span>
    </div>
  );
}

export function Button({
  children,
  onClick,
  variant = 'secondary',
  disabled,
  className = '',
}: {
  children: React.ReactNode;
  onClick?: () => void;
  variant?: 'primary' | 'secondary' | 'danger';
  disabled?: boolean;
  className?: string;
}) {
  const styles =
    variant === 'primary'
      ? 'bg-emerald-500 hover:bg-emerald-600 text-slate-950'
      : variant === 'danger'
        ? 'bg-red-500/10 border border-red-500/30 text-red-300 hover:bg-red-500/20'
        : 'bg-slate-950/60 border border-white/10 text-white/70 hover:text-white hover:border-white/20';
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`px-4 py-2 rounded-lg text-xs font-bold transition-all ${
        disabled ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer'
      } ${styles} ${className}`}
    >
      {children}
    </button>
  );
}

export function Hint({ children }: { children: React.ReactNode }) {
  return <p className="text-[11px] text-white/30 leading-relaxed">{children}</p>;
}

// ---------------------------------------------------------------- 設定列（對應原生 SettingsView.swift 的 SettingRow 系列）
// 規則同原生：左邊標題＋說明，右邊控制項；開關一律靠右、說明統一字級。

export function SettingDescription({ children }: { children: React.ReactNode }) {
  return <p className="text-xs text-white/45 leading-relaxed">{children}</p>;
}

export function SettingRow({
  title,
  description,
  children,
}: {
  title: React.ReactNode;
  description?: React.ReactNode;
  children?: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-4 py-0.5">
      <div className="min-w-0 flex-1 space-y-0.5">
        <div className="text-sm text-white/90">{title}</div>
        {description && <SettingDescription>{description}</SettingDescription>}
      </div>
      {children !== undefined && <div className="flex-shrink-0">{children}</div>}
    </div>
  );
}

export function SettingToggle({
  title,
  description,
  checked,
  onChange,
  disabled,
}: {
  title: React.ReactNode;
  description?: React.ReactNode;
  checked: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <SettingRow title={title} description={description}>
      <Toggle checked={checked} onChange={onChange} disabled={disabled} />
    </SettingRow>
  );
}

/// 滑桿列：標題＋目前數值在上，滑桿在下（與原生 SettingSlider 相同排版）
export function SettingSlider({
  title,
  valueText,
  value,
  onChange,
  min,
  max,
  step,
  description,
}: {
  title: React.ReactNode;
  valueText: string;
  value: number;
  onChange: (value: number) => void;
  min: number;
  max: number;
  step: number;
  description?: React.ReactNode;
}) {
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between gap-4">
        <span className="text-sm text-white/90">{title}</span>
        <span className="text-xs font-mono tabular-nums text-white/50">{valueText}</span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        className="w-full accent-emerald-500 cursor-pointer"
      />
      {description && <SettingDescription>{description}</SettingDescription>}
    </div>
  );
}

/// 子設定（開關打開後才出現的細項）往內縮，左側一條細線
export function SettingIndent({ children }: { children: React.ReactNode }) {
  return <div className="pl-3.5 border-l-2 border-white/10 space-y-2">{children}</div>;
}

export function SettingDivider() {
  return <div className="h-px bg-white/5" />;
}

export function Badge({
  children,
  tone = 'neutral',
}: {
  children: React.ReactNode;
  tone?: 'neutral' | 'ok' | 'warn' | 'error' | 'mode';
}) {
  const styles = {
    neutral: 'bg-white/5 text-white/60 border-white/10',
    ok: 'bg-emerald-500/10 text-emerald-300 border-emerald-500/25',
    warn: 'bg-amber-500/15 text-amber-300 border-amber-500/25',
    error: 'bg-red-500/10 text-red-300 border-red-500/25',
    mode: 'bg-purple-500/75 text-white border-purple-400/40',
  }[tone];
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-full border text-[11px] font-medium ${styles}`}>
      {children}
    </span>
  );
}

/// 確認對話框（取代 window.confirm：WKWebView 的 confirm 在部分環境會被吞掉，且無法在地化按鈕）
export function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel,
  cancelLabel,
  destructive,
  onConfirm,
  onCancel,
  children,
}: {
  open: boolean;
  title: string;
  message?: React.ReactNode;
  confirmLabel: string;
  cancelLabel: string;
  destructive?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
  children?: React.ReactNode;
}) {
  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onCancel();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onCancel]);

  if (!open) return null;
  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      onClick={onCancel}
    >
      <div
        role="dialog"
        aria-modal="true"
        className="w-[420px] max-w-[90vw] bg-slate-900 border border-white/10 rounded-2xl p-6 space-y-4 shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className="text-sm font-bold text-white">{title}</h3>
        {message && <div className="text-xs text-white/60 leading-relaxed whitespace-pre-line">{message}</div>}
        {children}
        <div className="flex justify-end gap-2 pt-2">
          <Button onClick={onCancel}>{cancelLabel}</Button>
          <Button variant={destructive ? 'danger' : 'primary'} onClick={onConfirm}>
            {confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}

/// 右鍵選單：在游標位置顯示，點外面或按 Esc 關閉
export function ContextMenu({
  position,
  items,
  onClose,
}: {
  position: { x: number; y: number } | null;
  items: Array<{ label: string; onSelect: () => void; destructive?: boolean } | 'separator'>;
  onClose: () => void;
}) {
  React.useEffect(() => {
    if (!position) return;
    const close = () => onClose();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('click', close);
    window.addEventListener('blur', close);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('blur', close);
      window.removeEventListener('keydown', onKey);
    };
  }, [position, onClose]);

  if (!position) return null;
  // 靠近視窗右下緣時往內縮，避免選單被切掉
  const x = Math.min(position.x, window.innerWidth - 200);
  const y = Math.min(position.y, window.innerHeight - items.length * 32 - 16);
  return (
    <div
      className="fixed z-50 min-w-[180px] py-1 bg-slate-900 border border-white/10 rounded-xl shadow-2xl"
      style={{ left: x, top: y }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      {items.map((item, index) =>
        item === 'separator' ? (
          <div key={`sep-${index}`} className="h-px my-1 bg-white/5" />
        ) : (
          <button
            key={item.label}
            type="button"
            onClick={() => {
              onClose();
              item.onSelect();
            }}
            className={`w-full text-left px-3 py-1.5 text-xs cursor-pointer hover:bg-white/5 ${
              item.destructive ? 'text-red-300' : 'text-white/80'
            }`}
          >
            {item.label}
          </button>
        )
      )}
    </div>
  );
}
