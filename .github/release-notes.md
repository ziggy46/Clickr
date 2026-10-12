### Installing

1. Download **Clickr-{{VERSION}}-arm64.dmg** for a Mac with Apple silicon, or **Clickr-{{VERSION}}-universal.dmg** for an Intel Mac (it runs on both).
2. Open the disk image and drag **Clickr** onto **Applications**.
3. Clickr isn't signed with an Apple Developer ID, so macOS blocks it the first time you open it. Either open it once, then go to **System Settings > Privacy & Security** and click **Open Anyway**, or run this in Terminal:

   ```
   xattr -cr /Applications/Clickr.app
   ```

Already have Clickr 0.2.0 or later? It can install this update itself: right-click the menu bar icon and choose **Update Available**, or turn on **Install updates automatically** in Settings.

