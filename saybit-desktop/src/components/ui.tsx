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
