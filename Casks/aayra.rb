cask "aayra" do
  # `version` and `sha256` are filled in by scripts/update-cask.sh after each GitHub release.
  version "1.7"
  sha256 "ae1a1205a2f481b47e3011ef94e2abbe21ac1db39187c33330078e503f47f1bd"

  url "https://github.com/nullifye/AAYRA-System-Monitor/releases/download/v#{version}/AAYRA-#{version}.zip"
  name "AAYRA"
  desc "Menu bar system monitor with a turbine that spins faster as the CPU works harder"
  homepage "https://github.com/nullifye/AAYRA-System-Monitor"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "AAYRA.app"

  # AAYRA is ad-hoc signed rather than notarized by Apple, so Gatekeeper blocks the downloaded copy.
  # Clear the "downloaded from the internet" flag on install, as the README tells manual installers to do.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/AAYRA.app"]
  end

  uninstall quit: "com.raf.aayra"

  zap trash: [
    "~/Library/Caches/com.raf.aayra",
    "~/Library/HTTPStorages/com.raf.aayra",
    "~/Library/Preferences/com.raf.aayra.plist",
  ]

  caveats <<~EOS
    AAYRA is not notarized by Apple. This cask removes the quarantine flag on install
    so macOS lets it open. Build it yourself from source if you prefer not to.
  EOS
end
