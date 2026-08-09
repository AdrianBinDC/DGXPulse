import Charts
import SwiftUI

struct SemiCircleGauge: View {
    var value: Double
    var maxValue: Double
    var primaryText: String
    var secondaryText: String

    private var progress: Double {
        guard maxValue > 0 else { return 0 }
        return min(max(value / maxValue, 0), 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                GaugeTrack()
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 14, lineCap: .round))

                GaugeTrack()
                    .trim(from: 0, to: progress)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))

                VStack(spacing: 2) {
                    Text(primaryText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .offset(y: 12)
            }
            .frame(height: 120)
        }
    }

    private var gaugeColor: Color {
        if progress >= 0.9 { return .red }
        if progress >= 0.7 { return .yellow }
        return Color(red: 0.45, green: 0.85, blue: 0.2)
    }
}

private struct GaugeTrack: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY - 8),
            radius: min(rect.width, rect.height * 2) / 2 - 8,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}

struct MetricHistoryChart: View {
    var title: String
    var samples: [MetricsSample]
    var value: KeyPath<MetricsSample, Double>
    var yMax: Double
    var yLabel: String

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value(title, sample[keyPath: value])
                )
                .foregroundStyle(Color.blue.opacity(0.35))

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value(title, sample[keyPath: value])
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Time", sample.timestamp),
                    y: .value(title, sample[keyPath: value])
                )
                .foregroundStyle(.white)
                .symbolSize(24)
            }
        }
        .chartYScale(domain: 0...max(yMax, 1))
        .chartYAxis {
            AxisMarks(values: [yMax]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.2))
                AxisValueLabel {
                    Text(yLabel)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .chartXAxis(.hidden)
        .frame(minHeight: 120)
    }
}

struct MetricPanel: View {
    var title: String
    var gaugeValue: Double
    var gaugeMax: Double
    var primaryText: String
    var secondaryText: String
    var samples: [MetricsSample]
    var chartValue: KeyPath<MetricsSample, Double>
    var yLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            HStack(alignment: .center, spacing: 24) {
                SemiCircleGauge(
                    value: gaugeValue,
                    maxValue: gaugeMax,
                    primaryText: primaryText,
                    secondaryText: secondaryText
                )
                .frame(maxWidth: 220)

                MetricHistoryChart(
                    title: title,
                    samples: samples,
                    value: chartValue,
                    yMax: gaugeMax,
                    yLabel: yLabel
                )
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
