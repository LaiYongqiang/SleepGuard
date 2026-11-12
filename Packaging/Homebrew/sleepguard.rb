cask "sleepguard" do
  version "1.1.0"
  sha256 :no_check

  url "https://github.com/LaiYongqiang/SleepGuard/releases/download/v#{version}/SleepGuard-#{version}-macOS-universal.dmg"
  name "SleepGuard"
  desc "Ultra-lightweight macOS menu bar & CLI keep-awake utility for Vibe Coding and AI Agents"
  homepage "https://github.com/LaiYongqiang/SleepGuard"

  depends_on macos: ">= :ventura"

  app "SleepGuard.app"
  binary "#{appdir}/SleepGuard.app/Contents/MacOS/SleepGuard", target: "sleepguard"

  zap trash: [
    "~/Library/Preferences/io.github.laiyongqiang.SleepGuard.plist",
  ]
end
