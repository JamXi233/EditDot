// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import Foundation

enum TextConversionError: LocalizedError {
    case base64, utf8, url, jsonString
    var errorDescription: String? {
        switch self {
        case .base64: return tr("conversion.invalid_base64_text_check_the_characters_and_padding")
        case .utf8: return tr("conversion.the_decoded_data_is_not_valid_utf_8_text")
        case .url: return tr("conversion.the_url_component_contains_invalid_percent_encoding_or_utf_8_text")
        case .jsonString: return tr("conversion.enter_a_json_string_enclosed_in_double_quotes")
        }
    }
}

enum TextConversions {
    static func apply(_ tool: TextTool, to text: String) throws -> String {
        switch tool {
        case .encodeBase64: return Data(text.utf8).base64EncodedString()
        case .decodeBase64:
            let compact = text.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: compact), data.base64EncodedString() == compact else { throw TextConversionError.base64 }
            guard let result = String(data: data, encoding: .utf8) else { throw TextConversionError.utf8 }
            return result
        case .encodeURL:
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let result = text.addingPercentEncoding(withAllowedCharacters: allowed) else { throw TextConversionError.url }
            return result
        case .decodeURL:
            guard let result = text.removingPercentEncoding else { throw TextConversionError.url }
            return result
        case .quoteJSON:
            let data = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .unquoteJSON:
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]), let result = value as? String else { throw TextConversionError.jsonString }
            return result
        default: return text
        }
    }
}

enum TextInsertion: Int, CaseIterable {
    case date, time, timestamp, identifier
    var title: String {
        switch self {
        case .date: return tr("conversion.current_date")
        case .time: return tr("conversion.current_time")
        case .timestamp: return tr("conversion.date_with_time_zone")
        case .identifier: return tr("conversion.new_uuid")
        }
    }
    func value(at date: Date = Date(), timeZone: TimeZone = .current, identifier: UUID = UUID()) -> String {
        if self == .identifier { return identifier.uuidString.lowercased() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        switch self {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .time: formatter.dateFormat = "HH:mm:ss"
        default: formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        }
        return formatter.string(from: date)
    }
}
