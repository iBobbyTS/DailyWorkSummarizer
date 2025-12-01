//
//  Item.swift
//  DailyWorkSummarizer
//
//  Created by iBobby on 2025-12-01.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
