cask "winmouse" do
  version "0.3.1"
  sha256 "ee009693fb47b6e3d083e72ac04f4e1d5c22fa010a7ef451a1eacfb6da213268"

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
