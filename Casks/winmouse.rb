cask "winmouse" do
  version "0.2.0"
  sha256 "3764d8e7bb77cca32b06b1b5dc7be59427a332f85d7a1e9fd37c106251c8310d"

  url "https://github.com/anilmetin0/winmouse/releases/download/v#{version}/WinMouse-#{version}.dmg"
  name "WinMouse"
  desc "Windows pointer acceleration and wheel scrolling for external mice"
  homepage "https://anilmetin0.github.io/winmouse/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "WinMouse.app"

  uninstall quit: "io.github.anilmetin0.winmouse"

  caveats <<~EOS
    WinMouse is not notarized. After the first launch is blocked, allow it in
    System Settings > Privacy & Security > Open Anyway.
    Allow Accessibility access for wheel scrolling and side buttons.
    If those stop working after an update, remove WinMouse from the Accessibility
    list and add /Applications/WinMouse.app again.
  EOS
end
