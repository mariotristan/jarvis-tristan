// The version `tristan --version` prints. Development builds say 0.0.0-dev; scripts/package-windows.ps1 rewrites this
// file with the release version (from the tag, v1.2.3 gives 1.2.3) before it builds, and restores it afterwards.
package enum BuildVersion {
    package static let value = "0.0.0-dev"
}
