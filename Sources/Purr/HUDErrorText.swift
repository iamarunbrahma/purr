import AVFoundation

// Turns a thrown error into a short, user-facing HUD message. Two rules the HUD
// depends on: no raw error codes (those stay in the log via the caller's
// log.error), and no em dashes. Messages that name an action come first;
// anything without specific guidance returns nil so callers fall back to the
// generic "Try again" pill.
enum HUDErrorText {
    static func message(for error: Error) -> String? {
        // A revoked microphone permission can mask itself as a generic capture
        // failure, so check it first - "try again" cannot succeed until the
        // user flips the System Settings toggle.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return
                "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        default:
            break
        }

        if let audio = error as? AudioError {
            switch audio {
            case .auhalSetup:
                return
                    "Could not start the microphone. Check it is connected and selected in System Settings → Sound."
            case .invalidInputFormat:
                return
                    "The microphone returned an unsupported format. Pick a different input in System Settings → Sound."
            case .cannotBuildConverter:
                return "Could not set up audio for this microphone. Try a different input device."
            }
        }

        // EngineError's descriptions are already written for users and carry
        // the right action, so surface them verbatim.
        if let engine = error as? EngineError {
            return engine.errorDescription
        }

        return nil
    }
}
