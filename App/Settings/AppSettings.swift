/// UserDefaults keys for the simple on/off settings (read with @AppStorage).
enum AppSettings {
    static let showKeyboardHint = "ShowKeyboardHint"
    static let hideIconWithoutAppleTV = "HideIconWithoutAppleTV"
    /// Play/pause, skip and scrubbing on the now playing card. On by default.
    static let playbackControls = "ShowPlaybackControls"
    /// Two-finger trackpad swipes on the clickpad. On by default.
    static let trackpadSwipes = "TrackpadSwipes"
}
