//
//  VideoTrimSelection.swift
//  Screendrop
//

import Foundation

/// Raised when a requested cut is shorter than anything that can be encoded.
/// Studio's video and audio exporters guard their ranges with it.
enum VideoTrimExportError: LocalizedError {
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "Choose a longer trim range."
        }
    }
}
