//
//  AboutView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import SwiftUI

struct AboutView: View {
    @State private var tapCount = 0
    @State private var showEasterEgg = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var easterEggImage: NSImage? {
        let path = Bundle.main.path(forResource: "easter_egg", ofType: "jpg")
            ?? Bundle.main.path(forResource: "easter_egg", ofType: "JPG")
        if let path = path {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 24) {
            // App Icon (tap 8 times for easter egg)
            Group {
                if showEasterEgg, let egg = easterEggImage {
                    Image(nsImage: egg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                } else if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .cornerRadius(24)
                } else {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .cornerRadius(24)
                }
            }
            .onTapGesture {
                tapCount += 1
                if tapCount >= 8 {
                    showEasterEgg = true
                }
            }

            // App Name & Version
            VStack(spacing: 6) {
                Text("Saybit")
                    .font(.system(size: 28, weight: .bold))

                Text("v\(appVersion) (\(buildNumber))")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            // Description
            Text(L10n.About.description)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            // Price info card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.About.priceTitle)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 14))

                Text(L10n.About.priceDesc)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.08))
            )
            .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 40)

            // Developer & Website
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.Common.developer)
                        .foregroundColor(.secondary)
                    Text("bashcat")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 15))

                Link(L10n.Common.visitWebsite, destination: URL(string: "https://bashcat.net")!)
                    .font(.system(size: 14))
            }

            // Copyright
            Text("© 2026 bashcat. All rights reserved.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
        .frame(width: 420, height: 560)
    }
}
