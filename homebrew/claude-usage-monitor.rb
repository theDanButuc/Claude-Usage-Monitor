cask "claude-usage-monitor" do
  version "1.1.0"
  sha256 "bffb3acc49e06706a162c2cf84bc9f11cf0ed4f09c2826d0b4997c67861ead3c"

  url "https://github.com/theDanButuc/Claude-Usage-Monitor/releases/download/v#{version}/ClaudeUsageMonitor-v#{version}.dmg"
  name "Claude Usage Monitor"
  desc "macOS menu-bar app that tracks your Claude.ai usage in real time"
  homepage "https://github.com/theDanButuc/Claude-Usage-Monitor"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "ClaudeUsageMonitor.app"

  zap trash: [
    "~/Library/Preferences/com.yourname.ClaudeUsageMonitor.plist",
    "~/Library/WebKit/com.yourname.ClaudeUsageMonitor",
  ]
end
