import CoreVideo
import Foundation
import Vision

/// Recognition is advisory: neither the presence nor absence of text proves
/// the device's security lock state. Never use it to block input or pairing.
enum DeviceLockState: String {
    case unknown, notDetected, suspected, paused

    var showsNotice: Bool { self == .suspected || self == .paused }

    var title: String {
        self == .paused ? StringsUI.current.screenPausedTitle : StringsUI.current.overlayLockedTitle
    }

    var message: String {
        self == .paused ? StringsUI.current.screenPausedMessage : StringsUI.current.overlayLockedMessage
    }
}

struct LockScreenText {
    let text: String
    /// Normalized image coordinates, with the origin at the top left.
    let bounds: CGRect
}

enum LockScreenRecognition {
    static func resemblesLockScreen(_ texts: [LockScreenText]) -> Bool {
        let clocks = texts.filter { item in
            let box = item.bounds
            return item.text.range(of: #"^\s*\d{1,2}[:：]\d{2}\s*$"#, options: .regularExpression) != nil
                && (0.07...0.30).contains(box.minY) && (0.045...0.17).contains(box.height)
                && (0.18...0.65).contains(box.width) && (0.32...0.68).contains(box.midX)
        }
        return clocks.contains { clock in
            texts.contains { item in
                let text = item.text.lowercased()
                let belowClock =
                    item.bounds.minY > clock.bounds.maxY
                    && item.bounds.minY < clock.bounds.maxY + 0.18
                // Newer iOS layouts place the date above the clock.
                let aboveClock =
                    item.bounds.maxY < clock.bounds.minY
                    && item.bounds.maxY > clock.bounds.minY - 0.12
                    && (0.25...0.75).contains(item.bounds.midX)
                let battery =
                    text.contains("电量") || text.contains("charged") || text.contains("charging")
                    || text.range(of: #"\d+\s*%\s*battery"#, options: .regularExpression) != nil
                let date =
                    text.range(
                        of: #"(\d+月\d+[日号].*(星期|周)|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday).+\d)"#,
                        options: .regularExpression) != nil
                let unlock =
                    text.contains("解锁") || text.contains("to unlock") || text.contains("press home to open")
                    || text.contains("swipe up to open") || text.contains("按下主屏幕按钮以打开")
                    || text.contains("向上轻扫以打开")
                return (belowClock && battery) || ((belowClock || aboveClock) && date)
                    || (item.bounds.minY > 0.65 && unlock)
            }
        }
    }

    static func read(_ buffer: CVPixelBuffer) -> DeviceLockState {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
            let texts = (request.results ?? []).compactMap { observation -> LockScreenText? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else {
                    return nil
                }
                let box = observation.boundingBox
                return LockScreenText(
                    text: candidate.string,
                    bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
            return resemblesLockScreen(texts) ? .suspected : .notDetected
        } catch {
            return .unknown
        }
    }
}
