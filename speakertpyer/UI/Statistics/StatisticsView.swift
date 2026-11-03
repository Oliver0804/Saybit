//
//  StatisticsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import Charts
import CoreData
import SwiftUI

struct StatisticsView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \TranscriptionRecord.timestamp, ascending: true)],
        animation: .default
    )
    private var allRecords: FetchedResults<TranscriptionRecord>

    @State private var timeRange: TimeRange = .week

    enum TimeRange: String, CaseIterable {
        case week
        case month
        case all

        var displayName: String {
            switch self {
            case .week: return L10n.Stats.week
            case .month: return L10n.Stats.month
            case .all: return L10n.Stats.all
            }
        }
    }

    // 快取過濾結果：原本 filteredRecords 是 computed property，單次 body 重算會被
    // summaryCards / costSummary / dailyUsageData… 各自呼叫，對全部記錄重複做 7+ 次 O(n) filter。
    // 改為僅在 timeRange 或記錄數變動時重算一次。
    @State private var cachedRecords: [TranscriptionRecord] = []

    private func recomputeFilteredRecords() {
        let cutoff: Date? = {
            switch timeRange {
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }()
        // 沒有時間戳的紀錄放不進任何一天，各範圍一律排除，彙總數字才會和圖表一致
        if let cutoff {
            cachedRecords = allRecords.filter { $0.timestamp.map { $0 >= cutoff } ?? false }
        } else {
            cachedRecords = allRecords.filter { $0.timestamp != nil }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Time range picker
                Picker(L10n.Stats.timeRange, selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                // MARK: - Summary Cards
                summaryCards

                // MARK: - Cost Estimate
                costEstimateCard

                // MARK: - Daily Usage Chart
                dailyUsageChart

                // MARK: - Top Apps
                topAppsCard

                // MARK: - Token Trend
                tokenTrendChart

                // MARK: - Mode Distribution
                modeDistributionCard
            }
            .padding(20)
        }
        .onAppear { recomputeFilteredRecords() }
        .onChange(of: timeRange) { _, _ in recomputeFilteredRecords() }
        .onChange(of: allRecords.count) { _, _ in recomputeFilteredRecords() }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: L10n.Stats.totalCount,
                value: "\(cachedRecords.count)",
                icon: "number",
                color: .blue
            )
            StatCard(
                title: L10n.Stats.totalTokens,
                value: formatNumber(cachedRecords.reduce(0) { $0 + Int($1.totalTokens) }),
                icon: "bitcoinsign.circle",
                color: .orange
            )
            StatCard(
                title: L10n.Stats.avgDuration,
                value: String(format: "%.1fs", averageDuration),
                icon: "timer",
                color: .green
            )
            StatCard(
                title: L10n.Stats.todayCount,
                value: "\(todayCount)",
                icon: "calendar",
                color: .purple
            )
        }
    }

    // MARK: - Cost Estimate

    /// 一次掃過 cachedRecords 算總成本和未知模型數，避免兩次 reduce
    /// 加上對 ModelPricingTable.price 的線性掃描（每 record 需比對 ~20 個 pattern）。
    private var costSummary: (total: Double, unknown: Int) {
        var total = 0.0
        var unknown = 0
        for r in cachedRecords {
            let model = r.modelName ?? ""
            let cost = ModelPricingTable.cost(
                model: model,
                promptTokens: Int(r.promptTokens),
                completionTokens: Int(r.completionTokens)
            )
            if let cost {
                total += cost
            } else if r.totalTokens > 0,
                      !model.lowercased().hasPrefix("local/"),
                      !model.lowercased().hasPrefix("ollama/") {
                unknown += 1
            }
        }
        return (total, unknown)
    }

    private var costEstimateCard: some View {
        let summary = costSummary
        return GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Cost.totalEstimate)
                        .font(.headline)
                    Text("\(ModelPricingTable.formatUSD(summary.total)) USD")
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                }
                Spacer()
                if summary.unknown > 0 {
                    Text(L10n.Cost.unknownIgnored(summary.unknown))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Daily Usage Chart

    private var dailyUsageChart: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                GlassSectionHeader(title: L10n.Stats.dailyUsage, icon: "chart.bar.fill")

                Chart(dailyUsageData, id: \.date) { item in
                    BarMark(
                        x: .value(L10n.Stats.chartDate,item.date, unit: .day),
                        y: .value(L10n.Stats.chartCount,item.count)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: axisStride)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .frame(height: 160)
            }
        }
    }

    // MARK: - Top Apps

    private var topAppsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                GlassSectionHeader(title: L10n.Stats.topApps, icon: "app.badge.fill")

                if topApps.isEmpty {
                    Text(L10n.Stats.noData)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topApps.prefix(5), id: \.app) { item in
                        HStack {
                            Text(item.app)
                                .font(.body)
                            Spacer()
                            Text("\(item.count) \(L10n.Stats.times)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.blue.opacity(0.3))
                                    .frame(width: geo.size.width * item.ratio)
                            }
                            .frame(width: 60, height: 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Token Trend Chart

    private var tokenTrendChart: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                GlassSectionHeader(title: L10n.Stats.tokenTrend, icon: "chart.line.uptrend.xyaxis")

                Chart(dailyTokenData, id: \.date) { item in
                    LineMark(
                        x: .value(L10n.Stats.chartDate,item.date, unit: .day),
                        y: .value("Tokens", item.tokens)
                    )
                    .foregroundStyle(.orange.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value(L10n.Stats.chartDate,item.date, unit: .day),
                        y: .value("Tokens", item.tokens)
                    )
                    .foregroundStyle(.orange.opacity(0.1))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: axisStride)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .frame(height: 140)
            }
        }
    }

    // MARK: - Mode Distribution

    private var modeDistributionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                GlassSectionHeader(title: L10n.Stats.modeDistribution, icon: "chart.pie.fill")

                if modeDistribution.isEmpty {
                    Text(L10n.Stats.noData)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        Chart(modeDistribution, id: \.mode) { item in
                            SectorMark(
                                angle: .value(L10n.Stats.chartCount,item.count),
                                innerRadius: .ratio(0.5),
                                angularInset: 1.5
                            )
                            .foregroundStyle(by: .value(L10n.Stats.chartMode,item.displayName))
                            .cornerRadius(4)
                        }
                        .frame(width: 120, height: 120)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(modeDistribution, id: \.mode) { item in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 8, height: 8)
                                    Text(item.displayName)
                                        .font(.caption)
                                    Spacer()
                                    Text("\(item.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Computed Data

    private var averageDuration: Double {
        guard !cachedRecords.isEmpty else { return 0 }
        return cachedRecords.reduce(0.0) { $0 + $1.duration } / Double(cachedRecords.count)
    }

    private var todayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return cachedRecords.filter { ($0.timestamp ?? .distantPast) >= startOfDay }.count
    }

    /// 時間範圍內的每一天（沒用的日子也要有，圖表才看得出空白日；只有一天資料時長條也不會撐滿整張圖）
    private var chartDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start: Date
        switch timeRange {
        case .week: start = cal.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: start = cal.date(byAdding: .day, value: -29, to: today) ?? today
        case .all:
            // 不再截在 365 天：圖表範圍要涵蓋彙總卡片算進去的所有紀錄
            start = cachedRecords.compactMap(\.timestamp).min().map { cal.startOfDay(for: $0) } ?? today
        }
        var days: [Date] = []
        var d = start
        while d <= today {
            days.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return days
    }

    private var recordsByDay: [Date: [TranscriptionRecord]] {
        Dictionary(grouping: cachedRecords) { Calendar.current.startOfDay(for: $0.timestamp ?? .distantPast) }
    }

    private var dailyUsageData: [DailyCount] {
        let grouped = recordsByDay
        return chartDays.map { DailyCount(date: $0, count: grouped[$0]?.count ?? 0) }
    }

    private var dailyTokenData: [DailyTokens] {
        let grouped = recordsByDay
        return chartDays.map { day in
            DailyTokens(date: day, tokens: grouped[day]?.reduce(0) { $0 + Int($1.totalTokens) } ?? 0)
        }
    }

    /// X 軸標籤間隔：7 天每天標、30 天每週標、全部每月標
    private var axisStride: Calendar.Component { timeRange == .week ? .day : (timeRange == .month ? .weekOfYear : .month) }

    private var topApps: [AppUsage] {
        let grouped = Dictionary(grouping: cachedRecords) { $0.appContext ?? "Unknown" }
        let sorted = grouped.map { AppUsage(app: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        let maxCount = sorted.first?.count ?? 1
        return sorted.map { AppUsage(app: $0.app, count: $0.count, ratio: CGFloat($0.count) / CGFloat(maxCount)) }
    }

    private var modeDistribution: [ModeUsage] {
        let grouped = Dictionary(grouping: cachedRecords) { $0.mode ?? "dictation" }
        return grouped.map { mode, records in
            ModeUsage(mode: mode, count: records.count)
        }
        .sorted { $0.count > $1.count }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Data Models

private struct DailyCount {
    let date: Date
    let count: Int
}

private struct DailyTokens {
    let date: Date
    let tokens: Int
}

private struct AppUsage {
    let app: String
    let count: Int
    var ratio: CGFloat = 1.0
}

private struct ModeUsage {
    let mode: String
    let count: Int

    var displayName: String {
        L10n.modeUsageDisplayName(mode)
    }

    var color: Color {
        switch mode {
        case "dictation": return .blue
        case "command": return .orange
        case "edit": return .green
        default: return .gray
        }
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color.opacity(0.7))
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
        )
    }
}
