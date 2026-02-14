//
//  InjectionMode.swift
//  speakertpyer
//
//  Created by Claude on 2026/2/14.
//

import Foundation

enum InjectionMode: String, CaseIterable {
    case paste = "paste"
    case keypress = "keypress"
    case replaceSelection = "replace_selection"

    var displayName: String { L10n.injectionMode(self) }
}
