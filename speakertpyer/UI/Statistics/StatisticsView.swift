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
        case week = "7 天"
        case month = "30 天"
        case all = "全部"
    }

    private var filteredRecords: [TranscriptionRecord] {
        let cutoff: Date? = {
            switch timeRange {
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }()
        guard let cutoff else { return Array(allRecords) }
        return allRecords.filter { ($0.timestamp ?? .distantPast) >= cutoff }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Time range picker
                Picker("時間範圍", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                // MARK: - Summary Cards
                summaryCards

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
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "總次數",
                value: "\(filteredRecords.count)",
                icon: "number",
                color: .blue
            )
            StatCard(
                title: "總 Token",
                value: formatNumber(filteredRecords.reduce(0) { $0 + Int($1.totalTokens) }),
                icon: "bitcoinsign.circle",
                color: .orange
            )
            StatCard(
                title: "平均時長",
                value: String(format: "%.1fs", averageDuration),
                icon: "timer",
                color: .green
            )
            StatCard(
                title: "今日次數",
                value: "\(todayCount)",
                icon: "calendar",
                color: .purple
            )
        }
    }

    // MARK: - Daily Usage Chart

    private var dailyUsageChart: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                GlassSectionHeader(title: "每日使用次數", icon: "chart.bar.fill")

                Chart(dailyUsageData, id: \.date) { item in
                    BarMark(
                        x: .value("日期", item.date, unit: .day),
                        y: .value("次數", item.count)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
                GlassSectionHeader(title: "常用 App", icon: "app.badge.fill")

                if topApps.isEmpty {
                    Text("尚無資料")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topApps.prefix(5), id: \.app) { item in
                        HStack {
                            Text(item.app)
                                .font(.body)
                            Spacer()
                            Text("\(item.count) 次")
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
                GlassSectionHeader(title: "Token 消耗趨勢", icon: "chart.line.uptrend.xyaxis")

                Chart(dailyTokenData, id: \.date) { item in
                    LineMark(
                        x: .value("日期", item.date, unit: .day),
                        y: .value("Tokens", item.tokens)
                    )
                    .foregroundStyle(.orange.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("日期", item.date, unit: .day),
                        y: .value("Tokens", item.tokens)
                    )
                    .foregroundStyle(.orange.opacity(0.1))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
                GlassSectionHeader(title: "模式分佈", icon: "chart.pie.fill")

                if modeDistribution.isEmpty {
                    Text("尚無資料")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        Chart(modeDistribution, id: \.mode) { item in
                            SectorMark(
                                angle: .value("次數", item.count),
                                innerRadius: .ratio(0.5),
                                angularInset: 1.5
                            )
                            .foregroundStyle(by: .value("模式", item.displayName))
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
        guard !filteredRecords.isEmpty else { return 0 }
        return filteredRecords.reduce(0.0) { $0 + $1.duration } / Double(filteredRecords.count)
    }

    private var todayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return filteredRecords.filter { ($0.timestamp ?? .distantPast) >= startOfDay }.count
    }

    private var dailyUsageData: [DailyCount] {
        let grouped = Dictionary(grouping: filteredRecords) { record -> Date in
            Calendar.current.startOfDay(for: record.timestamp ?? Date())
        }
        return grouped.map { DailyCount(date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    private var dailyTokenData: [DailyTokens] {
        let grouped = Dictionary(grouping: filteredRecords) { record -> Date in
            Calendar.current.startOfDay(for: record.timestamp ?? Date())
        }
        return grouped.map { date, records in
            DailyTokens(date: date, tokens: records.reduce(0) { $0 + Int($1.totalTokens) })
        }
        .sorted { $0.date < $1.date }
    }

    private var topApps: [AppUsage] {
        let grouped = Dictionary(grouping: filteredRecords) { $0.appContext ?? "Unknown" }
        let sorted = grouped.map { AppUsage(app: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        let maxCount = sorted.first?.count ?? 1
        return sorted.map { AppUsage(app: $0.app, count: $0.count, ratio: CGFloat($0.count) / CGFloat(maxCount)) }
    }

    private var modeDistribution: [ModeUsage] {
        let grouped = Dictionary(grouping: filteredRecords) { $0.mode ?? "dictation" }
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
        switch mode {
        case "dictation": return "聽寫"
        case "command": return "指令"
        case "edit": return "編輯"
        default: return mode
        }
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
